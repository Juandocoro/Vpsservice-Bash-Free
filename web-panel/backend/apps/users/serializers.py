# ===================================================================
# VPSService Web Panel - Serializers de Usuarios
# Convierte modelos Django a JSON/diccionarios para la API
# ===================================================================

from rest_framework import serializers
from .models import SSHUser, UserAccessLog

# ===================================================================
# SERIALIZER: Usuario SSH
# ===================================================================
class SSHUserSerializer(serializers.ModelSerializer):
    """
    Serializa el modelo SSHUser para API REST.
    Convierte objetos Django a JSON y viceversa.
    """

    # ===== PROPIEDADES CALCULADAS =====
    days_until_expiry = serializers.SerializerMethodField()
    is_expired = serializers.SerializerMethodField()

    class Meta:
        model = SSHUser
        fields = [
            'id',
            'username',
            'max_connections',
            'created_date',
            'expiry_date',
            'is_active',
            'is_expired',
            'days_until_expiry',
            'created_by',
            'notes',
        ]
        read_only_fields = ['id', 'created_date', 'last_updated']

    def get_days_until_expiry(self, obj):
        """Calcula días faltantes para vencimiento"""
        return obj.days_until_expiry

    def get_is_expired(self, obj):
        """Indica si el usuario ya expiró"""
        return obj.is_expired


# ===================================================================
# SERIALIZER: Crear/Actualizar Usuario SSH
# ===================================================================
class SSHUserCreateUpdateSerializer(serializers.ModelSerializer):
    """
    Serializer para crear y actualizar usuarios.
    Incluye validaciones de datos.
    """

    password = serializers.CharField(
        write_only=True,  # Solo se escribe, no se lee
        min_length=8,
        help_text="Contraseña para el usuario (mínimo 8 caracteres)"
    )

    confirm_password = serializers.CharField(
        write_only=True,
        help_text="Confirmar contraseña"
    )

    class Meta:
        model = SSHUser
        fields = [
            'username',
            'password',
            'confirm_password',
            'max_connections',
            'expiry_date',
            'notes',
        ]

    def validate(self, data):
        """
        Validaciones personalizadas:
        - Las contraseñas coinciden
        - El nombre de usuario es válido
        """

        # Verificar que las contraseñas coincidan
        if data['password'] != data.pop('confirm_password'):
            raise serializers.ValidationError("Las contraseñas no coinciden")

        # Validar nombre de usuario (solo letras, números, guiones)
        username = data.get('username', '')
        if not username.replace('_', '').isalnum():
            raise serializers.ValidationError("El nombre de usuario solo puede contener letras, números y guiones")

        return data

    def create(self, validated_data):
        """
        Crear nuevo usuario:
        1. Validar datos
        2. Crear usuario en BD
        3. Ejecutar comando SSH para crear en servidor
        """

        password = validated_data.pop('password')
        user = SSHUser.objects.create(**validated_data)

        # TODO: Aquí irá el código para conectar por SSH y crear el usuario
        # Ejemplo: SSHClient().execute(f"useradd -m {user.username}")
        # Y luego: SSHClient().execute(f"echo '{user.username}:{password}' | chpasswd")

        return user


# ===================================================================
# SERIALIZER: Log de Acceso
# ===================================================================
class UserAccessLogSerializer(serializers.ModelSerializer):
    """
    Serializa logs de acceso de usuarios.
    """

    username = serializers.CharField(
        source='user.username',
        read_only=True,
        help_text="Nombre del usuario que accedió"
    )

    class Meta:
        model = UserAccessLog
        fields = [
            'id',
            'username',
            'timestamp',
            'ip_address',
            'success',
            'status',
        ]
        read_only_fields = fields
