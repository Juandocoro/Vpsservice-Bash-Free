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
class SSHUserCreateSerializer(serializers.ModelSerializer):
    """Serializer para crear usuarios SSH (requiere contraseña)."""

    password = serializers.CharField(write_only=True, min_length=8)
    confirm_password = serializers.CharField(write_only=True)

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
        if data['password'] != data['confirm_password']:
            raise serializers.ValidationError("Las contraseñas no coinciden")

        username = data.get('username', '')
        if not username.replace('_', '').isalnum():
            raise serializers.ValidationError(
                "El nombre de usuario solo puede contener letras, números y guiones"
            )
        return data

    def create(self, validated_data):
        password = validated_data.pop('password')
        validated_data.pop('confirm_password', None)
        user = SSHUser.objects.create(**validated_data)

        # TODO: Conectar por SSH y crear el usuario real en el VPS.
        # Ej: useradd -m {user.username} ; echo '{user.username}:{password}' | chpasswd

        _ = password
        return user


class SSHUserUpdateSerializer(serializers.ModelSerializer):
    """Serializer para actualizar campos NO sensibles del usuario."""

    class Meta:
        model = SSHUser
        fields = [
            'max_connections',
            'expiry_date',
            'notes',
            'is_active',
        ]


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
