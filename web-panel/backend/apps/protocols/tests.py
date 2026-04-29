from django.test import TestCase
from .models import Protocol


class ProtocolModelTests(TestCase):
    """Test cases para el modelo Protocol"""

    def setUp(self):
        """Configurar datos de prueba"""
        self.protocol = Protocol.objects.create(
            name='stunnel',
            port=8080,
            protocol_type='tcp',
            is_installed=True,
            is_active=True,
        )

    def test_protocol_creation(self):
        """Test que se crea un protocolo correctamente"""
        self.assertEqual(self.protocol.name, 'stunnel')
        self.assertEqual(self.protocol.port, 8080)
        self.assertTrue(self.protocol.is_installed)
        self.assertTrue(self.protocol.is_active)

    def test_protocol_string_representation(self):
        """Test la representación en string del protocolo"""
        self.assertIn('Stunnel', str(self.protocol))
