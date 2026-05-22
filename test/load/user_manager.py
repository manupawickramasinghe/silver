"""
user_manager.py - Test user account management
Provides the TestUserManager class to handle loading, creating,
and retrieving test users for load testing.
"""
import os
import csv
import random
from faker import Faker
from config import MAIL_DOMAIN


class TestUserManager:
    """Manage test user accounts"""
    __test__ = False

    def __init__(self, users_file="test_data/users.csv"):
        """
        Initialize TestUserManager.

        Args:
            users_file (str): Path to the CSV file containing user data.
        """
        self.users_file = users_file
        self.users = self._load_users()

    def _load_users(self):
        """Load test users from CSV file"""
        users = []
        if os.path.exists(self.users_file):
            with open(self.users_file, 'r', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                users = list(reader)
        else:
            # Create sample users if file doesn't exist
            users = self._create_sample_users()
            self._save_users(users)

        return users

    def _create_sample_users(self):
        """Create sample test users"""
        fake = Faker()
        users = []
        for i in range(100):
            users.append({
                'username': f'testuser{i:03d}',
                'email': f'testuser{i:03d}@{MAIL_DOMAIN}',
                'password': 'TestPassword123!',
                'full_name': fake.name()
            })
        return users

    def _save_users(self, users):
        """Save users to CSV file"""
        os.makedirs(os.path.dirname(self.users_file), exist_ok=True)
        with open(self.users_file, 'w', newline='', encoding='utf-8') as f:
            if users:
                writer = csv.DictWriter(f, fieldnames=users[0].keys())
                writer.writeheader()
                writer.writerows(users)

    def get_random_user(self):
        """Get a random test user"""
        return random.choice(self.users)
