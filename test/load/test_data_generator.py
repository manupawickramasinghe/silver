import sys
import os
import pytest

# Add current dir to path to import sibling modules
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from data_generator import TestDataGenerator

# Set __test__ = False to avoid PytestCollectionWarning on the class itself
TestDataGenerator.__test__ = False

class TestTestDataGenerator:
    def test_generate_email_content_unknown_type(self):
        generator = TestDataGenerator()
        with pytest.raises(KeyError):
            generator.generate_email_content("invalid_type")

    def test_generate_email_content_random(self):
        generator = TestDataGenerator()
        content = generator.generate_email_content("random")
        assert "subject" in content
        assert "body" in content
        assert "type" in content
        assert content["type"] in generator.email_templates

    def test_generate_email_content_specific(self):
        generator = TestDataGenerator()
        content = generator.generate_email_content("marketing")
        assert content["type"] == "marketing"
        assert "Special Offer" in content["body"]
