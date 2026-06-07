import os
import sys
import csv
import pytest
from unittest.mock import patch

# Add the current directory to sys.path to import user_manager reliably
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
from user_manager import TestUserManager

# Prevent pytest from trying to collect this class as a test suite
TestUserManager.__test__ = False

@pytest.fixture
def temp_users_file(tmp_path):
    """Fixture providing a temporary file path for testing."""
    # Using just a file name in tmp_path avoids needing to create subdirectories manually
    return str(tmp_path / "users.csv")

def test_init_creates_file_if_not_exists(temp_users_file):
    """Test that initializing TestUserManager creates a users file if it doesn't exist."""
    assert not os.path.exists(temp_users_file)
    manager = TestUserManager(users_file=temp_users_file)

    assert os.path.exists(temp_users_file)
    assert len(manager.users) == 100

    # Check that users have expected keys
    first_user = manager.users[0]
    assert 'username' in first_user
    assert 'email' in first_user
    assert 'password' in first_user
    assert 'full_name' in first_user

def test_load_existing_users_file(temp_users_file):
    """Test that TestUserManager loads existing users from CSV."""
    # Setup: Create a file with known data
    sample_users = [
        {"username": "user1", "email": "user1@example.com", "password": "pw1", "full_name": "User One"},
        {"username": "user2", "email": "user2@example.com", "password": "pw2", "full_name": "User Two"}
    ]
    with open(temp_users_file, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=["username", "email", "password", "full_name"])
        writer.writeheader()
        writer.writerows(sample_users)

    manager = TestUserManager(users_file=temp_users_file)

    assert len(manager.users) == 2
    assert manager.users[0]['username'] == 'user1'
    assert manager.users[1]['username'] == 'user2'

def test_save_empty_users_list(temp_users_file):
    """Test saving an empty list of users."""
    manager = TestUserManager(users_file=temp_users_file)

    # Manually overwrite the file to verify it doesn't fail on empty users list
    # _save_users writes nothing if the users list is empty
    manager._save_users([])

    # Check that the file exists but is strictly empty
    with open(temp_users_file, 'r') as f:
        content = f.read()
    assert content == ""

@patch('random.choice')
def test_get_random_user(mock_choice, temp_users_file):
    """Test getting a random user."""
    # Setup known user list
    mock_user = {"username": "chosen_user"}
    mock_choice.return_value = mock_user

    manager = TestUserManager(users_file=temp_users_file)

    # Test random selection
    chosen = manager.get_random_user()

    assert chosen == mock_user
    mock_choice.assert_called_once_with(manager.users)

def test_create_sample_users(temp_users_file):
    """Test the structure of sample users created."""
    # Initialize without creating files by patching _load_users
    with patch.object(TestUserManager, '_load_users', return_value=[]):
        manager = TestUserManager(users_file=temp_users_file)

    users = manager._create_sample_users()

    assert len(users) == 100
    assert users[0]['username'] == 'testuser000'
    assert users[99]['username'] == 'testuser099'

    for user in users:
        assert 'username' in user
        assert 'email' in user
        assert 'password' in user
        assert 'full_name' in user
        assert user['password'] == 'TestPassword123!'
