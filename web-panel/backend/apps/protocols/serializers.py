# ===================================================================
# VPSService Web Panel - Serializers de Protocolos
# Convierte modelos Django a JSON para la API REST
# ===================================================================

from rest_framework import serializers

from .models import Protocol, ProtocolConfig, ProtocolInstallation


class ProtocolSerializer(serializers.ModelSerializer):
    class Meta:
        model = Protocol
        fields = [
            'id',
            'name',
            'port',
            'protocol_type',
            'is_installed',
            'is_active',
            'configuration',
            'description',
            'created_date',
            'installed_date',
            'last_updated',
        ]
        read_only_fields = ['id', 'created_date', 'installed_date', 'last_updated']


class ProtocolConfigSerializer(serializers.ModelSerializer):
    class Meta:
        model = ProtocolConfig
        fields = [
            'id',
            'protocol',
            'config_name',
            'settings',
            'is_active',
            'created_date',
            'created_by',
        ]
        read_only_fields = ['id', 'created_date']


class ProtocolInstallationSerializer(serializers.ModelSerializer):
    class Meta:
        model = ProtocolInstallation
        fields = [
            'id',
            'protocol',
            'status',
            'started_at',
            'completed_at',
            'output',
            'error_message',
            'installed_by',
        ]
        read_only_fields = ['id', 'started_at', 'completed_at']
