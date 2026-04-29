from django.apps import AppConfig


class UsersConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.users'
    verbose_name = 'Usuarios SSH'

    def ready(self):
        """Importar signals cuando la app esté lista"""
        # from . import signals  # Descomenta si añades signals
        pass
