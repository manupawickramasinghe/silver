import sys
import os
import smtplib
from unittest.mock import MagicMock

sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from smtp_tester import SMTPLoadTester  # noqa: E402


def test_is_rate_limit_error_smtp_connect_error_421():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = smtplib.SMTPConnectError(421, b"Service not available")
    assert tester._is_rate_limit_error(exc) is True


def test_is_rate_limit_error_smtp_connect_error_other():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = smtplib.SMTPConnectError(500, b"Syntax error")
    assert tester._is_rate_limit_error(exc) is False


def test_is_rate_limit_error_string_421():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = Exception("Server returned 421 error code")
    assert tester._is_rate_limit_error(exc) is True


def test_is_rate_limit_error_string_too_many_connections():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = Exception("Error: too many connections to server")
    assert tester._is_rate_limit_error(exc) is True


def test_is_rate_limit_error_string_case_insensitive():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = Exception("Error: TOO MANY CONNECTIONS")
    assert tester._is_rate_limit_error(exc) is True


def test_is_rate_limit_error_other_exception():
    tester = SMTPLoadTester(environment=MagicMock())
    exc = Exception("Connection refused")
    assert tester._is_rate_limit_error(exc) is False
