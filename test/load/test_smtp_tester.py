import pytest
import smtplib
import sys
import os

# Ensure the module can be imported
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from smtp_tester import SMTPLoadTester

class TestSMTPLoadTesterRateLimitError:

    def test_smtpconnecterror_421(self):
        """Test with SMTPConnectError and error code 421."""
        exception = smtplib.SMTPConnectError(421, "Too many connections")
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is True

    def test_smtpconnecterror_non_421(self):
        """Test with SMTPConnectError and an error code other than 421."""
        exception = smtplib.SMTPConnectError(500, "Internal Server Error")
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is False

    def test_smtpconnecterror_no_args(self):
        """Test with SMTPConnectError when no arguments are provided.
        SMTPConnectError requires code and msg, so we test by manually setting args to empty tuple
        to test the len(exception.args) >= 1 branch."""
        exception = smtplib.SMTPConnectError(500, "Error")
        exception.args = ()
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is False

    def test_generic_exception_with_421(self):
        """Test with generic exception string containing '421'."""
        exception = Exception("Server returned error 421 temporarily unavailable")
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is True

    def test_generic_exception_with_too_many_connections(self):
        """Test with generic exception string containing 'too many connections' (case insensitive)."""
        exception = Exception("Error: TOO MANY CONNECTIONS")
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is True

        exception2 = Exception("too many connections to this host")
        assert SMTPLoadTester._is_rate_limit_error(None, exception2) is True

    def test_generic_exception_unrelated(self):
        """Test with generic exception string unrelated to rate limits."""
        exception = Exception("Connection refused by host")
        assert SMTPLoadTester._is_rate_limit_error(None, exception) is False
