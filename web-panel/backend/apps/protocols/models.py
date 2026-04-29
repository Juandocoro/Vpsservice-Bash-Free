# ===================================================================
# VPSService Web Panel - Models de Protocolos
# Define la estructura de datos para los protocolos/servicios VPS
# ===================================================================

from django.db import models
from django.utils import timezone

# ===================================================================
# MODELO: Protocolo
# ===================================================================
class Protocol(models.Model):
    """
    Representa un protocolo/servicio instalado en el VPS.
    (Stunnel, OpenVPN, V2Ray, WireGuard, Squid, etc)
    """

    # ===== NOMBRE Y TIPO =====
    PROTOCOL_TYPES = [
        ('ssh', 'SSH Tunnel'),
        ('stunnel', 'Stunnel SSL'),
        ('websocket', 'WebSocket'),
        ('udp', 'UDP Custom'),
        ('badvpn', 'BadVPN'),
        ('v2ray', 'V2Ray'),
        ('shadowsocks', 'Shadowsocks'),
        ('openvpn', 'OpenVPN'),
        ('wireguard', 'WireGuard'),
        ('slowdns', 'SlowDNS'),
        ('squid', 'Squid Proxy'),
        ('dropbear', 'Dropbear'),
    ]

    name = models.CharField(
        max_length=100,
        choices=PROTOCOL_TYPES,
        unique=True,
        help_text="Tipo de protocolo/servicio"
    )

    # ===== PUERTO =====
    port = models.IntegerField(
        help_text="Puerto en el que escucha el servicio"
    )

    protocol_type = models.CharField(
        max_length=10,
        choices=[('tcp', 'TCP'), ('udp', 'UDP')],
        default='tcp',
        help_text="TCP o UDP"
    )

    # ===== ESTADO =====
    is_installed = models.BooleanField(
        default=False,
        help_text="¿Está instalado en el servidor?"
    )

    is_active = models.BooleanField(
        default=False,
        help_text="¿Está corriendo actualmente?"
    )

    # ===== CONFIGURACIÓN =====
    configuration = models.JSONField(
        default=dict,
        blank=True,
        help_text="Configuración específica del protocolo (formato JSON)"
    )

    # Ejemplos:
    # Stunnel: {"cert_path": "/etc/stunnel/stunnel.pem", "target_port": 22}
    # OpenVPN: {"protocol": "udp", "cipher": "AES-256-CBC", "vpn_subnet": "10.8.0.0/24"}
    # Squid: {"max_connections": 1000}

    # ===== DESCRIPCIÓN =====
    description = models.TextField(
        blank=True,
        help_text="Descripción de qué hace este protocolo"
    )

    # ===== AUDITORÍA =====
    created_date = models.DateTimeField(
        auto_now_add=True,
        help_text="Cuándo se registró en la BD"
    )

    installed_date = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Cuándo se instaló en el servidor"
    )

    last_updated = models.DateTimeField(
        auto_now=True,
        help_text="Última actualización del registro"
    )

    class Meta:
        ordering = ['name']
        verbose_name = "Protocolo"
        verbose_name_plural = "Protocolos"

    def __str__(self):
        status = "✓" if self.is_active else "✗"
        return f"{status} {self.get_name_display()} (:{self.port})"


# ===================================================================
# MODELO: Configuración de Protocolo
# ===================================================================
class ProtocolConfig(models.Model):
    """
    Almacena configuraciones específicas y personalizadas por protocolo.
    Permite múltiples instancias del mismo protocolo con diferentes configs.
    """

    protocol = models.ForeignKey(
        Protocol,
        on_delete=models.CASCADE,
        related_name='configs',
        help_text="Protocolo al que pertenece esta configuración"
    )

    # ===== IDENTIFICACIÓN =====
    config_name = models.CharField(
        max_length=255,
        help_text="Nombre descriptivo de esta configuración"
    )

    # Ejemplo: "Stunnel con cert personalizado", "OpenVPN para juegos"

    # ===== CONFIGURACIÓN ESPECÍFICA =====
    settings = models.JSONField(
        default=dict,
        help_text="Parámetros específicos de configuración"
    )

    # ===== ESTADO =====
    is_active = models.BooleanField(
        default=True,
        help_text="Si esta configuración está activa"
    )

    # ===== AUDITORÍA =====
    created_date = models.DateTimeField(
        auto_now_add=True
    )

    created_by = models.CharField(
        max_length=255,
        default="admin"
    )

    class Meta:
        ordering = ['-created_date']
        unique_together = ('protocol', 'config_name')

    def __str__(self):
        return f"{self.protocol.get_name_display()} - {self.config_name}"


# ===================================================================
# MODELO: Instalación de Protocolo
# ===================================================================
class ProtocolInstallation(models.Model):
    """
    Registra el historial de instalación/desinstalación de protocolos.
    """

    INSTALLATION_STATUS = [
        ('pending', 'Pendiente'),
        ('installing', 'Instalando'),
        ('success', 'Exitosa'),
        ('failed', 'Falló'),
        ('uninstalling', 'Desinstalando'),
    ]

    protocol = models.ForeignKey(
        Protocol,
        on_delete=models.CASCADE,
        related_name='installations',
        help_text="Protocolo que se está instalando"
    )

    status = models.CharField(
        max_length=20,
        choices=INSTALLATION_STATUS,
        default='pending',
        help_text="Estado de la instalación"
    )

    started_at = models.DateTimeField(
        auto_now_add=True,
        help_text="Cuándo comenzó la instalación"
    )

    completed_at = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Cuándo terminó"
    )

    # ===== SALIDA DEL INSTALADOR =====
    output = models.TextField(
        blank=True,
        help_text="Logs de salida del instalador"
    )

    error_message = models.TextField(
        blank=True,
        help_text="Mensaje de error si falló"
    )

    # ===== AUDITORÍA =====
    installed_by = models.CharField(
        max_length=255,
        default="system"
    )

    class Meta:
        ordering = ['-started_at']

    def __str__(self):
        return f"{self.protocol.get_name_display()} - {self.get_status_display()}"
