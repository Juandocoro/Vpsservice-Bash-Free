# ===================================================================
# VPSService Web Panel - Views de Protocolos
# API REST para listar/crear/editar protocolos
# ===================================================================

from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from .models import Protocol
from .serializers import ProtocolSerializer


class ProtocolViewSet(viewsets.ModelViewSet):
    queryset = Protocol.objects.all()
    serializer_class = ProtocolSerializer
    permission_classes = [IsAuthenticated]

    filterset_fields = ['name', 'is_installed', 'is_active', 'protocol_type']
    search_fields = ['name', 'description']
    ordering_fields = ['name', 'port', 'created_date', 'installed_date']
    ordering = ['name']
