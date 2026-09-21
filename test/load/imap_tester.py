# imap_tester.py - IMAP load testing tasks
import time
import ssl
import imaplib
import logging
from locust import User, task, between

from config import EmailServerConfig, create_ssl_context
from user_manager import TestUserManager

logger = logging.getLogger(__name__)


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
    
    @staticmethod
    def _safe_logout(mail):
        """Close a connection, recording rather than hiding teardown errors"""
        if mail is None:
            return
        try:
            mail.logout()
        except Exception:
            logger.debug("IMAP logout failed during cleanup", exc_info=True)

    def _try_imap_connection(self, config):
        """Open and authenticate one IMAP transport.

        Returns the logged-in connection, or None when the transport itself is
        unavailable and the caller should try the next one. Certificate and
        authentication failures propagate instead: retrying either against
        another transport would downgrade the connection or hammer the account
        with failed logins.
        """
        mail = None
        try:
            logger.info(f"Attempting IMAP connection: {config['name']} on port {config['port']} to {self.config.IMAP_SERVER}")

            if config.get("ssl", False):
                # Direct SSL connection (port 993)
                mail = imaplib.IMAP4_SSL(
                    self.config.IMAP_SERVER,
                    config["port"],
                    ssl_context=create_ssl_context(),
                    timeout=self.config.TIMEOUT
                )
                logger.debug(f"SSL connection established on port {config['port']}")
            else:
                # Plain connection (port 143) upgraded with STARTTLS
                mail = imaplib.IMAP4(
                    self.config.IMAP_SERVER,
                    config["port"],
                    timeout=self.config.TIMEOUT
                )
                mail.starttls(ssl_context=create_ssl_context())
                logger.debug(f"STARTTLS upgrade successful on port {config['port']}")
        except ssl.SSLCertVerificationError:
            logger.error(f"❌ Untrusted TLS certificate from {self.config.IMAP_SERVER}:{config['port']}; refusing to send credentials")
            self._safe_logout(mail)
            raise
        except Exception as e:
            logger.warning(f"❌ IMAP connection failed for {config['name']} (port {config['port']}): {type(e).__name__}: {e}")
            self._safe_logout(mail)
            return None

        try:
            mail.login(self.user_account['username'], self.user_account['password'])
        except imaplib.IMAP4.error as login_error:
            logger.error(f"❌ IMAP login failed on port {config['port']}: {login_error}")
            self._safe_logout(mail)
            raise

        logger.info(f"✅ IMAP login successful using {config['name']} on port {config['port']} for user {self.user_account['username']}")
        return mail

    def _connect_imap(self):
        """Connect to IMAP with fallback configurations"""
        start_time = time.time()

        # Prefer the config that worked last time, then the remaining ones
        configs = self.config.IMAP_CONFIGS
        if self.working_config in configs:
            configs = [self.working_config] + [c for c in configs if c != self.working_config]

        try:
            for config in configs:
                mail = self._try_imap_connection(config)
                if mail:
                    self.working_config = config  # Cache for future use
                    self.environment.events.request.fire(
                        request_type="IMAP",
                        name="connect",
                        response_time=(time.time() - start_time) * 1000,
                        response_length=0,
                        exception=None
                    )
                    return mail
            error = Exception(f"All IMAP connection methods failed for {self.config.IMAP_SERVER}")
        except (ssl.SSLCertVerificationError, imaplib.IMAP4.error) as e:
            # Aborted deliberately: neither an untrusted certificate nor a
            # rejected password is worth retrying on the next transport.
            error = e

        logger.error(f"IMAP connect failed: {error}")
        self.environment.events.request.fire(
            request_type="IMAP",
            name="connect",
            response_time=(time.time() - start_time) * 1000,
            response_length=0,
            exception=error
        )
        return None

    @task(5)
    def check_inbox(self):
        """Check inbox for new messages"""
        mail = self._connect_imap()
        if not mail: 
            return
            
        start_time = time.time()
        try:
            mail.select('INBOX')
            status, messages = mail.search(None, 'ALL')
            message_count = len(messages[0].split()) if messages[0] else 0
            mail.logout()
            
            self.environment.events.request.fire(
                request_type="IMAP",
                name="check_inbox",
                response_time=(time.time() - start_time) * 1000,
                response_length=message_count,
                exception=None
            )
            logger.info(f"Inbox check successful: {message_count} messages")
            
        except Exception as e:
            self.environment.events.request.fire(
                request_type="IMAP",
                name="check_inbox",
                response_time=(time.time() - start_time) * 1000,
                response_length=0,
                exception=e
            )
            self._safe_logout(mail)
            logger.error(f"Inbox check failed: {e}")

    @task(3)
    def list_folders(self):
        """List available folders"""
        mail = self._connect_imap()
        if not mail: 
            return
            
        start_time = time.time()
        try:
            status, folders = mail.list()
            folder_count = len(folders) if folders else 0
            mail.logout()
            
            self.environment.events.request.fire(
                request_type="IMAP",
                name="list_folders",
                response_time=(time.time() - start_time) * 1000,
                response_length=folder_count,
                exception=None
            )
            logger.info(f"Folder listing successful: {folder_count} folders")
            
        except Exception as e:
            self.environment.events.request.fire(
                request_type="IMAP",
                name="list_folders",
                response_time=(time.time() - start_time) * 1000,
                response_length=0,
                exception=e
            )
            self._safe_logout(mail)
            logger.error(f"Folder listing failed: {e}")

    @task(2)
    def fetch_recent_messages(self):
        """Fetch recent messages"""
        mail = self._connect_imap()
        if not mail: 
            return
            
        start_time = time.time()
        try:
            mail.select('INBOX')
            # Get recent messages (last 5)
            status, messages = mail.search(None, 'ALL')
            if messages[0]:
                message_ids = messages[0].split()
                recent_ids = message_ids[-5:] if len(message_ids) >= 5 else message_ids
                
                fetched_count = 0
                for msg_id in recent_ids:
                    status, msg_data = mail.fetch(msg_id, '(RFC822)')
                    if status == 'OK':
                        fetched_count += 1
                
                mail.logout()
                
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name="fetch_messages",
                    response_time=(time.time() - start_time) * 1000,
                    response_length=fetched_count,
                    exception=None
                )
                logger.info(f"Message fetch successful: {fetched_count} messages")
            else:
                mail.logout()
                self.environment.events.request.fire(
                    request_type="IMAP",
                    name="fetch_messages",
                    response_time=(time.time() - start_time) * 1000,
                    response_length=0,
                    exception=None
                )
                
        except Exception as e:
            self.environment.events.request.fire(
                request_type="IMAP",
                name="fetch_messages",
                response_time=(time.time() - start_time) * 1000,
                response_length=0,
                exception=e
            )
            self._safe_logout(mail)
            logger.error(f"Message fetch failed: {e}")