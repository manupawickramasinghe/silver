import sys
import os
import unittest
from unittest.mock import MagicMock, patch

# Need to make sure test/load is in path
sys.path.insert(0, os.path.abspath('test/load'))

from smtp_tester import SMTPLoadTester

class MockEnv:
    def __init__(self):
        self.events = MagicMock()

class TestSMTPTester(unittest.TestCase):
    def setUp(self):
        self.env = MockEnv()

        # Patch config and others so they don't break
        with patch('smtp_tester.EmailServerConfig'), \
             patch('smtp_tester.TestDataGenerator'), \
             patch('smtp_tester.TestUserManager'):
            self.tester = SMTPLoadTester(self.env)
            self.tester.on_start() # initializes config
            self.tester.user_account = {'email': 'test@example.com', 'username': 'user', 'password': 'pw'}
            self.tester.config.USE_TLS = False

    def test_record_telemetry_success(self):
        with self.tester._record_telemetry("test_event") as ctx:
            ctx.response_length = 42

        self.tester.environment.events.request.fire.assert_called_once()
        args, kwargs = self.tester.environment.events.request.fire.call_args
        self.assertEqual(kwargs['name'], "test_event")
        self.assertEqual(kwargs['response_length'], 42)
        self.assertIsNone(kwargs['exception'])

    def test_record_telemetry_rate_limit(self):
        import smtplib
        mock_server = MagicMock()

        with patch.object(self.tester, '_is_rate_limit_error', return_value=True):
            try:
                with self.tester._record_telemetry("test_event") as ctx:
                    ctx.server = mock_server
                    raise Exception("test rate limit")
            except:
                pass

        self.tester.environment.events.request.fire.assert_called_once()
        args, kwargs = self.tester.environment.events.request.fire.call_args
        self.assertEqual(kwargs['name'], "test_event_rate_limited")
        self.assertIsNone(kwargs['exception'])
        mock_server.quit.assert_called_once()

    def test_record_telemetry_error(self):
        mock_server = MagicMock()
        test_exc = Exception("test error")

        with patch.object(self.tester, '_is_rate_limit_error', return_value=False):
            try:
                with self.tester._record_telemetry("test_event") as ctx:
                    ctx.server = mock_server
                    raise test_exc
            except:
                pass

        self.tester.environment.events.request.fire.assert_called_once()
        args, kwargs = self.tester.environment.events.request.fire.call_args
        self.assertEqual(kwargs['name'], "test_event")
        self.assertEqual(kwargs['exception'], test_exc)
        mock_server.quit.assert_called_once()

if __name__ == '__main__':
    unittest.main()
