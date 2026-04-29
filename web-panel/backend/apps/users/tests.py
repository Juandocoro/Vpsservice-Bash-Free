from datetime import date, timedelta

from django.test import TestCase

from .models import SSHUser


class SSHUserModelTests(TestCase):
    def setUp(self):
        self.user = SSHUser.objects.create(
            username='testuser',
            max_connections=2,
            expiry_date=date.today() + timedelta(days=30),
            created_by='tests',
        )

    def test_user_creation(self):
        self.assertEqual(self.user.username, 'testuser')
        self.assertEqual(self.user.max_connections, 2)
        self.assertTrue(self.user.is_active)

    def test_user_string_representation(self):
        self.assertIn('testuser', str(self.user))
