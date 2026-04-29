# ===================================================================
# VPSService Web Panel - Views de Usuarios
# Vistas REST API para gestionar usuarios SSH
# ===================================================================

from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.db.models import Q
from django.utils import timezone
from datetime import timedelta

from .models import SSHUser, UserAccessLog
from .serializers import (
    SSHUserSerializer,
    SSHUserCreateUpdateSerializer,
    UserAccessLogSerializer,
)

# ===================================================================
# VIEWSET: Usuario SSH
# ===================================================================
class SSHUserViewSet(viewsets.ModelViewSet):
    """
    API REST completa para gestionar usuarios SSH.

    Endpoints:
    - GET /api/users/                    → Listar todos los usuarios
    - GET /api/users/{id}/               → Obtener detalles de usuario
    - POST /api/users/                   → Crear nuevo usuario
    - PUT /api/users/{id}/               → Actualizar usuario
    - DELETE /api/users/{id}/            → Eliminar usuario
    - PATCH /api/users/{id}/toggle/      → Activar/Desactivar usuario
    - GET /api/users/{id}/access-logs/   → Ver logs de acceso
    """

    queryset = SSHUser.objects.all()
    permission_classes = [IsAuthenticated]  # Requiere estar autenticado

    # ===== CONFIGURACIÓN DE FILTRADO =====
    filterset_fields = ['is_active', 'username']
    search_fields = ['username', 'notes']
    ordering_fields = ['created_date', 'expiry_date', 'username']
    ordering = ['-created_date']

    def get_serializer_class(self):
        """
        Usa diferentes serializers según la acción:
        - create/update: serializer con validaciones
        - list/retrieve: serializer de lectura
        """
        if self.action in ['create', 'update', 'partial_update']:
            return SSHUserCreateUpdateSerializer
        return SSHUserSerializer

    # ===== LISTAR USUARIOS =====
    def list(self, request, *args, **kwargs):
        """
        GET /api/users/
        Retorna lista de usuarios con opciones de filtrado y búsqueda.
        """
        return super().list(request, *args, **kwargs)

    # ===== CREAR USUARIO =====
    def create(self, request, *args, **kwargs):
        """
        POST /api/users/
        Crear nuevo usuario SSH:
        1. Validar datos
        2. Guardar en BD
        3. Ejecutar comando SSH para crear en servidor
        4. Retornar datos del nuevo usuario
        """

        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        # TODO: Aquí iría la lógica para conectar por SSH
        # ssh_client = SSHConnection()
        # ssh_client.create_user(serializer.validated_data['username'], password)

        self.perform_create(serializer)
        headers = self.get_success_headers(serializer.data)

        return Response(
            serializer.data,
            status=status.HTTP_201_CREATED,
            headers=headers
        )

    # ===== ACTUALIZAR USUARIO =====
    def update(self, request, *args, **kwargs):
        """
        PUT /api/users/{id}/
        Actualizar datos del usuario (excepto nombre, que es única).
        """
        return super().update(request, *args, **kwargs)

    # ===== ELIMINAR USUARIO =====
    def destroy(self, request, *args, **kwargs):
        """
        DELETE /api/users/{id}/
        Eliminar usuario:
        1. Ejecutar comando SSH para borrar del servidor
        2. Eliminar del BD
        3. Retornar confirmación
        """

        user = self.get_object()

        # TODO: Ejecutar SSH para eliminar usuario
        # ssh_client = SSHConnection()
        # ssh_client.delete_user(user.username)

        self.perform_destroy(user)
        return Response(status=status.HTTP_204_NO_CONTENT)

    # ===== ACCIÓN PERSONALIZADA: Activar/Desactivar =====
    @action(detail=True, methods=['post'])
    def toggle_active(self, request, pk=None):
        """
        POST /api/users/{id}/toggle/
        Activar o desactivar un usuario (sin eliminarlo).
        """

        user = self.get_object()
        user.is_active = not user.is_active
        user.save()

        serializer = self.get_serializer(user)
        return Response(serializer.data)

    # ===== ACCIÓN PERSONALIZADA: Ver Logs de Acceso =====
    @action(detail=True, methods=['get'])
    def access_logs(self, request, pk=None):
        """
        GET /api/users/{id}/access-logs/
        Retorna historial de intentos de acceso del usuario.
        """

        user = self.get_object()
        logs = user.access_logs.all()

        # Paginar si hay muchos logs
        page = self.paginate_queryset(logs)
        if page is not None:
            serializer = UserAccessLogSerializer(page, many=True)
            return self.get_paginated_response(serializer.data)

        serializer = UserAccessLogSerializer(logs, many=True)
        return Response(serializer.data)

    # ===== ACCIÓN PERSONALIZADA: Cambiar Contraseña =====
    @action(detail=True, methods=['post'])
    def change_password(self, request, pk=None):
        """
        POST /api/users/{id}/change-password/
        Cambiar la contraseña de un usuario.
        """

        user = self.get_object()
        new_password = request.data.get('new_password')

        if not new_password:
            return Response(
                {'error': 'new_password requerido'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # TODO: Ejecutar SSH para cambiar contraseña
        # ssh_client = SSHConnection()
        # ssh_client.change_password(user.username, new_password)

        user.password_changed_date = timezone.now()
        user.save()

        return Response({'status': 'Contraseña cambiada exitosamente'})

    # ===== ACCIÓN PERSONALIZADA: Estadísticas =====
    @action(detail=False, methods=['get'])
    def stats(self, request):
        """
        GET /api/users/stats/
        Retorna estadísticas de usuarios.
        """

        total = SSHUser.objects.count()
        active = SSHUser.objects.filter(is_active=True).count()
        expired = SSHUser.objects.filter(
            expiry_date__lt=timezone.now().date()
        ).count()

        # Próximos a expirar (en 7 días)
        soon_to_expire = SSHUser.objects.filter(
            expiry_date__lte=timezone.now().date() + timedelta(days=7),
            expiry_date__gt=timezone.now().date()
        ).count()

        return Response({
            'total_users': total,
            'active_users': active,
            'expired_users': expired,
            'soon_to_expire': soon_to_expire,
        })
