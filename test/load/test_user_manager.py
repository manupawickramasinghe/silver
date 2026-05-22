import pytest
import os
import tempfile
import sys
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from user_manager import TestUserManager

def test_load_users_empty_file():
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
        temp_file = f.name

    try:
        manager = TestUserManager(users_file=temp_file)
        assert manager.users == []
    finally:
        os.remove(temp_file)
