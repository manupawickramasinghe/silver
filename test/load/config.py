# config.py - Email server configuration
import logging
import os
import ssl
from dotenv import load_dotenv
# Load environment variables from .env file
load_dotenv()

logger = logging.getLogger(__name__)

MAIL_DOMAIN = os.getenv("MAIL_DOMAIN", "localhost")

# Opt-in escape hatch for development servers using a self-signed certificate.
# It disables certificate and hostname verification for every mail connection,
# which makes the test credentials interceptable, so it is never the default.
TLS_INSECURE = os.getenv("MAIL_TLS_INSECURE", "0").strip().lower() in ("1", "true", "yes")

if TLS_INSECURE:
    logger.warning(
        "MAIL_TLS_INSECURE is set: TLS certificates and hostnames will NOT be verified. "
        "Test account passwords are sent to whatever answers on %s and can be intercepted. "
        "Use this only against a development server with a self-signed certificate.",
        MAIL_DOMAIN,
    )


def create_ssl_context():
    """Build the TLS context shared by the SMTP and IMAP testers.

    Certificates and hostnames are verified unless MAIL_TLS_INSECURE is set.
    """
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if TLS_INSECURE:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    return context


class EmailServerConfig:
    """Email server configuration with multiple fallback options"""
    SMTP_SERVER = MAIL_DOMAIN
    SMTP_PORT = 587
    IMAP_SERVER = MAIL_DOMAIN

    # Try these configurations in order. Both are encrypted: there is no
    # plaintext fallback, because falling back to one would send the test
    # account's password over the wire in the clear.
    IMAP_CONFIGS = [
        {"port": 993, "ssl": True, "starttls": False, "name": "IMAP SSL (Port 993)"},
        {"port": 143, "ssl": False, "starttls": True, "name": "IMAP with STARTTLS (Port 143)"},
    ]

    TIMEOUT = 30
    USE_TLS = True

    # Attachment size limit (10MB - industry standard for email attachments)
    # Setting to 6MB to ensure encoded size stays under 10MB (base64 adds ~33% overhead)
    MAX_ATTACHMENT_SIZE_MB = 6
    MAX_ATTACHMENT_SIZE_BYTES = MAX_ATTACHMENT_SIZE_MB * 1024 * 1024
