# smtp_tester.py - SMTP load testing tasks
#
# This module implements SMTP load testing for the email server.
#
# Rate Limit Handling:
# The server implements connection rate limiting via
# smtpd_client_connection_rate_limit.
# When this limit is hit, the server returns a 421 error
# ("too many connections").
# This is expected behavior during load testing and is
# treated as a successful test scenario rather than a
# failure. Rate-limited requests are logged and counted
# separately (with "_rate_limited" suffix) but do not cause the test to fail.
#
import time
import random
import smtplib
import logging
import os
from contextlib import contextmanager
from locust import User, task, between
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email import encoders

from config import EmailServerConfig
from data_generator import TestDataGenerator
from user_manager import TestUserManager

logger = logging.getLogger(__name__)


class SMTPLoadTester(User):
    """SMTP Load Testing User"""
    wait_time = between(1, 5)
    weight = 3

    def on_start(self):
        """Initialize user session"""
        self.config = EmailServerConfig()
        self.data_generator = TestDataGenerator()
        self.user_manager = TestUserManager()
        self.user_account = self.user_manager.get_random_user()
        logger.info(
            f"Starting SMTP tests for user: {self.user_account['email']}"
        )

    @contextmanager
    def _record_telemetry(self, name):
        """Context manager to handle telemetry, rate limits, and errors."""
        class TelemetryContext:
            def __init__(self):
                self.response_length = 0
                self.server = None

        ctx = TelemetryContext()
        start_time = time.time()

        try:
            yield ctx

            response_time = (time.time() - start_time) * 1000
            self.environment.events.request.fire(
                request_type="SMTP",
                name=name,
                response_time=response_time,
                response_length=ctx.response_length,
                exception=None
            )

        except Exception as e:
            response_time = (time.time() - start_time) * 1000

            if self._is_rate_limit_error(e):
                logger.info(f"SMTP rate limit hit during {name}: {e}")
                self.environment.events.request.fire(
                    request_type="SMTP",
                    name=f"{name}_rate_limited",
                    response_time=response_time,
                    response_length=0,
                    exception=None
                )
            else:
                self.environment.events.request.fire(
                    request_type="SMTP",
                    name=name,
                    response_time=response_time,
                    response_length=0,
                    exception=e
                )

            if ctx.server:
                try:
                    ctx.server.quit()
                except Exception:
                    pass

    def _is_rate_limit_error(self, exception):
        """Check if exception is a rate limit error (421)"""
        if isinstance(exception, smtplib.SMTPConnectError):
            if len(exception.args) >= 1:
                code = exception.args[0]
                return code == 421
        error_str = str(exception).lower()
        return '421' in error_str or 'too many connections' in error_str

    def _connect_smtp(self):
        """Establish SMTP connection"""
        with self._record_telemetry("connect") as ctx:
            if self.config.USE_TLS:
                server = smtplib.SMTP(
                    self.config.SMTP_SERVER, self.config.SMTP_PORT
                )
                server.starttls()
            else:
                server = smtplib.SMTP(
                    self.config.SMTP_SERVER, self.config.SMTP_PORT
                )

            # Save server in context so it can be cleaned up on failure
            ctx.server = server

            server.login(
                self.user_account['username'], self.user_account['password']
            )

            # Important: return the server without clearing it from context,
            # but since we succeeded, the context manager won't call quit().
            return server

        return None

    @task(5)
    def send_plain_text_email(self):
        """Send plain text email"""
        server = self._connect_smtp()
        if not server:
            return

        with self._record_telemetry("send_text") as ctx:
            ctx.server = server

            content = self.data_generator.generate_email_content("plain_text")
            recipient = self.user_manager.get_random_user()['email']

            msg = MIMEText(content['body'], 'plain')
            msg['Subject'] = content['subject']
            msg['From'] = self.user_account['email']
            msg['To'] = recipient

            server.send_message(msg)
            server.quit()

            # Don't try to quit again if it fails after this point
            ctx.server = None
            ctx.response_length = len(content['body'])

    @task(3)
    def send_html_email(self):
        """Send HTML email"""
        server = self._connect_smtp()
        if not server:
            return

        with self._record_telemetry("send_html") as ctx:
            ctx.server = server

            content = self.data_generator.generate_email_content("marketing")
            recipient = self.user_manager.get_random_user()['email']

            msg = MIMEMultipart('alternative')
            msg['Subject'] = content['subject']
            msg['From'] = self.user_account['email']
            msg['To'] = recipient

            html_part = MIMEText(content['body'], 'html')
            msg.attach(html_part)

            server.send_message(msg)
            server.quit()

            ctx.server = None
            ctx.response_length = len(content['body'])

    @task(1)
    def send_email_with_attachment(self):
        """Send email with attachment (max 10MB)"""
        server = self._connect_smtp()
        if not server:
            return

        with self._record_telemetry("send_attachment") as ctx:
            ctx.server = server

            content = self.data_generator.generate_email_content(
                "transactional"
            )
            recipient = self.user_manager.get_random_user()['email']
            attachment = self.data_generator.get_random_attachment()

            msg = MIMEMultipart()
            msg['Subject'] = content['subject']
            msg['From'] = self.user_account['email']
            msg['To'] = recipient

            msg.attach(MIMEText(content['body'], 'html'))

            if os.path.exists(attachment['path']):
                file_size = os.path.getsize(attachment['path'])

                if file_size > self.config.MAX_ATTACHMENT_SIZE_BYTES:
                    logger.warning(
                        f"Skipping attachment {attachment['path']}: "
                        f"size {file_size//(1024*1024)}MB exceeds "
                        f"{self.config.MAX_ATTACHMENT_SIZE_MB}MB limit"
                    )
                else:
                    with open(attachment['path'], "rb") as attachment_file:
                        part = MIMEBase('application', 'octet-stream')
                        part.set_payload(attachment_file.read())

                    encoders.encode_base64(part)
                    part.add_header(
                        'Content-Disposition',
                        'attachment; filename= '
                        f'{os.path.basename(attachment["path"])}'
                    )
                    msg.attach(part)

            server.send_message(msg)
            server.quit()

            ctx.server = None
            ctx.response_length = len(content['body'])

    @task(2)
    def send_bulk_emails(self):
        """Send multiple emails in one session"""
        server = self._connect_smtp()
        if not server:
            return

        with self._record_telemetry("send_bulk") as ctx:
            ctx.server = server

            num_emails = random.randint(5, 10)

            for i in range(num_emails):
                content = self.data_generator.generate_email_content()
                recipient = self.user_manager.get_random_user()['email']

                # flake8 requires short lines
                mime_type = \
                    'plain' if content['type'] == 'plain_text' else 'html'
                msg = MIMEText(content['body'], mime_type)
                msg['Subject'] = f"Bulk Test {i+1}: {content['subject']}"
                msg['From'] = self.user_account['email']
                msg['To'] = recipient

                server.send_message(msg)

            server.quit()

            ctx.server = None
            ctx.response_length = num_emails
