# imap_tester.py - IMAP load testing tasks
import time
import ssl
import imaplib
import logging
import functools
from locust import User, task, between

from config import EmailServerConfig
from user_manager import TestUserManager

logger = logging.getLogger(__name__)

def record_imap_telemetry(name):
    """Decorator to handle IMAP connection, timing, logging, and error handling."""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):
            mail = self._connect_imap()
            if not mail:
                return

            start_time = time.time()
            try:
                response_length = func(self, mail, *args, **kwargs)
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name=name,
                    response_time=(time.time() - start_time) * 1000,
                    response_length=response_length or 0,
                    exception=None
                )
            except Exception as e:
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name=name,
                    response_time=(time.time() - start_time) * 1000,
                    response_length=0,
                    exception=e
                )
                logger.error(f"{name} failed: {e}")
            finally:
                try:
                    mail.logout()
                except Exception:
                    pass
        return wrapper
    return decorator



class IMAPLoadTester(User):
    """IMAP Load Testing User with robust connection handling"""
    wait_time = between(2, 8)
    weight = 2
    
    def on_start(self):
        self.config = EmailServerConfig()
        self.user_manager = TestUserManager()
        self.user_account = self.user_manager.get_random_user()
        self.working_config = None  # Cache working config
        logger.info(f"Starting IMAP tests for user: {self.user_account['email']}")
    
    def _create_ssl_context(self):
        """Create a more permissive SSL context"""
        try:
            context = ssl.create_default_context()
            # Allow older TLS versions for better compatibility
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            # For testing environments with self-signed certificates
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            return context
        except Exception as e:
            logger.error(f"SSL context creation failed: {e}")
            return None
    
    def _try_imap_connection(self, config):
        """Try a specific IMAP configuration"""
        mail = None
        try:
            logger.info(f"Attempting IMAP connection: {config['name']} on port {config['port']} to {self.config.IMAP_SERVER}")
            
            if config.get("ssl", False):
                # Direct SSL connection (port 993)
                context = self._create_ssl_context()
                if context is None:
                    raise Exception("Failed to create SSL context")
                
                mail = imaplib.IMAP4_SSL(
                    self.config.IMAP_SERVER, 
                    config["port"],
                    ssl_context=context
                )
                logger.debug(f"SSL connection established on port {config['port']}")
            else:
                # Plain connection (port 143), possibly with STARTTLS
                mail = imaplib.IMAP4(self.config.IMAP_SERVER, config["port"])
                logger.debug(f"Plain connection established on port {config['port']}")
                
                if config.get("starttls", False):
                    context = self._create_ssl_context()
                    if context is None:
                        raise Exception("Failed to create SSL context for STARTTLS")
                    mail.starttls(ssl_context=context)
                    logger.debug("STARTTLS upgrade successful")
            
            # Test login
            try:
                mail.login(self.user_account['username'], self.user_account['password'])
                logger.info(f"✅ IMAP login successful using {config['name']} on port {config['port']} for user {self.user_account['username']}")
                return mail, config
            except imaplib.IMAP4.error as login_error:
                logger.error(f"❌ IMAP login failed on port {config['port']}: {login_error}")
                raise
            
        except Exception as e:
            logger.warning(f"❌ IMAP connection failed for {config['name']} (port {config['port']}): {type(e).__name__}: {e}")
            if mail:
                try: 
                    mail.logout()
                except: 
                    pass
            return None, None
    
    def _connect_imap(self):
        """Connect to IMAP with fallback configurations"""
        start_time = time.time()
        
        # If we have a working config, try it first
        if self.working_config:
            mail, config = self._try_imap_connection(self.working_config)
            if mail:
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name="connect",
                    response_time=(time.time() - start_time) * 1000,
                    response_length=0,
                    exception=None
                )
                return mail
        
        # Try all configurations until one works
        for config in self.config.IMAP_CONFIGS:
            mail, working_config = self._try_imap_connection(config)
            if mail:
                self.working_config = working_config  # Cache for future use
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name="connect",
                    response_time=(time.time() - start_time) * 1000,
                    response_length=0,
                    exception=None
                )
                return mail
        
        # All configurations failed
        error_msg = f"All IMAP connection methods failed for {self.config.IMAP_SERVER}"
        logger.error(error_msg)
        self.environment.events.request.fire(
            request_type="IMAP",
            name="connect",
            response_time=(time.time() - start_time) * 1000,
            response_length=0,
            exception=Exception(error_msg)
        )
        return None

    @task(5)
    @record_imap_telemetry("check_inbox")
    def check_inbox(self, mail):
        """Check inbox for new messages"""
        mail.select('INBOX')
        status, messages = mail.search(None, 'ALL')
        message_count = len(messages[0].split()) if messages[0] else 0
        logger.info(f"Inbox check successful: {message_count} messages")
        return message_count

    @task(3)
    @record_imap_telemetry("list_folders")
    def list_folders(self, mail):
        """List available folders"""
        status, folders = mail.list()
        folder_count = len(folders) if folders else 0
        logger.info(f"Folder listing successful: {folder_count} folders")
        return folder_count

    @task(2)
    @record_imap_telemetry("fetch_messages")
    def fetch_recent_messages(self, mail):
        """Fetch recent messages"""
        mail.select('INBOX')
        # Get recent messages (last 5)
        status, messages = mail.search(None, 'ALL')
        fetched_count = 0
        if messages[0]:
            message_ids = messages[0].split()
            recent_ids = message_ids[-5:] if len(message_ids) >= 5 else message_ids
            
            for msg_id in recent_ids:
                status, msg_data = mail.fetch(msg_id, '(RFC822)')
                if status == 'OK':
                    fetched_count += 1

            logger.info(f"Message fetch successful: {fetched_count} messages")
        return fetched_count