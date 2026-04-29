from django.apps import AppConfig


class ProtocolsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.protocols'
    verbose_name = 'Protocolos/Servicios'

    def ready(self):
        """Importar signals cuando la app esté lista"""
        # from . import signals  # Descomenta si añades signals
        pass
