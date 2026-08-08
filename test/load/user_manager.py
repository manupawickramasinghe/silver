# user_manager.py - Test user account management
import csv
import os
import random


class TestUserManager:
    """Manage test user accounts"""

    def __init__(self, users_file="test_data/users.csv"):
        self.users_file = users_file
        self.users = self._load_users()

    def _load_users(self):
        """Load test users from CSV file

        The file is produced by scripts/user/create_test_users.sh, which sets a
        randomly generated password per account. Credentials cannot be invented
        here: fabricated ones would never match the server, so every login in
        the suite would fail and the run would measure nothing but rejections.
        """
        if not os.path.exists(self.users_file):
            raise FileNotFoundError(
                f"Test user file '{self.users_file}' not found. Run "
                "scripts/user/create_test_users.sh on the server, then copy "
                "scripts/user/test_users/test_users_credentials.csv to this path."
            )

        with open(self.users_file, 'r', newline='') as f:
            users = list(csv.DictReader(f))

        if not users:
            raise ValueError(f"Test user file '{self.users_file}' contains no users.")

        return users

    def get_random_user(self):
        """Get a random test user"""
        return random.choice(self.users)
