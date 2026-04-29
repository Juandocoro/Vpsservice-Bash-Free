# ===================================================================
# VPSService Web Panel - Models de Usuarios
# Define la estructura de datos para los usuarios SSH del VPS
# ===================================================================

from django.db import models
from django.utils import timezone
from datetime import timedelta

# ===================================================================
# MODELO: Usuario SSH
# ===================================================================
class SSHUser(models.Model):
    """
    Representa un usuario SSH en el servidor VPS.
    Almacena información para auditoría y gestión desde la web.
    """

    # ===== CAMPOS BÁSICOS =====
    username = models.CharField(
        max_length=255,
        unique=True,
        help_text="Nombre de usuario SSH (debe ser único en el servidor)"
    )
    
    # Nota: La contraseña se almacena SOLO en el servidor (usando chpasswd)
    # NO se almacena en la BD por seguridad
    password_changed_date = models.DateTimeField(
        auto_now_add=True,
        help_text="Última vez que se cambió la contraseña"
    )

    # ===== LÍMITES DE CONEXIÓN =====
    max_connections = models.IntegerField(
        default=1,
        help_text="Número máximo de conexiones simultáneas permitidas"
    )

    # ===== DATOS DE VENCIMIENTO =====
    created_date = models.DateTimeField(
        auto_now_add=True,
        help_text="Fecha de creación del usuario"
    )
    
    expiry_date = models.DateField(
        help_text="Fecha de vencimiento del usuario"
    )

    # ===== ESTADO =====
    is_active = models.BooleanField(
        default=True,
        help_text="Si el usuario está activo o desactivado"
    )

    # ===== AUDITORÍA =====
    created_by = models.CharField(
        max_length=255,
        default="admin",
        help_text="Quién creó este usuario"
    )
    
    last_updated = models.DateTimeField(
        auto_now=True,
        help_text="Última actualización del registro"
    )

    # ===== METADATOS =====
    notes = models.TextField(
        blank=True,
        help_text="Notas adicionales sobre el usuario"
    )

    class Meta:
        ordering = ['-created_date']
        verbose_name = "Usuario SSH"
        verbose_name_plural = "Usuarios SSH"

    def __str__(self):
        """Representación en texto del usuario"""
        return f"{self.username} (Vence: {self.expiry_date})"

    @property
    def days_until_expiry(self):
        """Calcula días restantes hasta vencimiento"""
        today = timezone.now().date()
        if self.expiry_date < today:
            return 0  # Ya expiró
        return (self.expiry_date - today).days

    @property
    def is_expired(self):
        """Verifica si el usuario ha expirado"""
        return self.expiry_date < timezone.now().date()


# ===================================================================
# MODELO: Log de Acceso de Usuarios
# ===================================================================
class UserAccessLog(models.Model):
    """
    Registra intentos de acceso SSH para auditoría.
    """

    user = models.ForeignKey(
        SSHUser,
        on_delete=models.CASCADE,
        related_name='access_logs',
        help_text="Usuario que intentó acceder"
    )

    timestamp = models.DateTimeField(
        auto_now_add=True,
        help_text="Cuándo ocurrió el acceso"
    )

    ip_address = models.GenericIPAddressField(
        help_text="IP desde donde se intentó conectar"
    )

    success = models.BooleanField(
        default=False,
        help_text="Si el acceso fue exitoso"
    )

    status = models.CharField(
        max_length=50,
        choices=[
            ('success', 'Conexión exitosa'),
            ('auth_failed', 'Autenticación fallida'),
            ('max_connections', 'Límite de conexiones excedido'),
            ('expired', 'Usuario expirado'),
            ('inactive', 'Usuario inactivo'),
        ],
        default='success'
    )

    class Meta:
        ordering = ['-timestamp']
        verbose_name = "Log de Acceso"
        indexes = [
            models.Index(fields=['user', '-timestamp']),
        ]

    def __str__(self):
        return f"{self.user.username} - {self.timestamp} - {self.get_status_display()}"
