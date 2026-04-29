from django.test import TestCase
from .models import Protocol


class ProtocolModelTests(TestCase):
    """Test cases para el modelo Protocol"""

    def setUp(self):
        """Configurar datos de prueba"""
        self.protocol = Protocol.objects.create(
            name='Test Protocol',
            service_name='test_service',
            port=8080,
            status='running'
        )

    def test_protocol_creation(self):
        """Test que se crea un protocolo correctamente"""
        self.assertEqual(self.protocol.name, 'Test Protocol')
        self.assertEqual(self.protocol.service_name, 'test_service')
        self.assertEqual(self.protocol.port, 8080)
        self.assertEqual(self.protocol.status, 'running')

    def test_protocol_string_representation(self):
        """Test la representación en string del protocolo"""
        self.assertEqual(str(self.protocol), 'Test Protocol (test_service)')
