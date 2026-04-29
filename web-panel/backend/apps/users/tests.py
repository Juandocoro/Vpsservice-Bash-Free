from django.test import TestCase
from .models import User


class UserModelTests(TestCase):
    """Test cases para el modelo User"""

    def setUp(self):
        """Configurar datos de prueba"""
        self.user = User.objects.create_user(
            username='testuser',
            password='testpass123',
            max_connections=2
        )

    def test_user_creation(self):
        """Test que se crea un usuario correctamente"""
        self.assertEqual(self.user.username, 'testuser')
        self.assertEqual(self.user.connection_limit, 2)
        self.assertIsNotNone(self.user.password_hash)

    def test_user_string_representation(self):
        """Test la representación en string del usuario"""
        self.assertEqual(str(self.user), 'testuser')
