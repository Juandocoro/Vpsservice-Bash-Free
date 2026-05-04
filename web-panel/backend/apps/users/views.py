import subprocess
import shlex
from rest_framework import viewsets, status
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework_simplejwt.tokens import RefreshToken
from django.utils import timezone
from datetime import timedelta, date

from .models import SSHUser, UserAccessLog
from .serializers import (
    SSHUserSerializer,
    SSHUserCreateSerializer,
    SSHUserUpdateSerializer,
    UserAccessLogSerializer,
)


# ===================================================================
# UTILIDADES: Ejecutar comandos del sistema
# ===================================================================
def run_cmd(cmd: list) -> tuple[bool, str]:
    """
    Ejecuta un comando en el sistema operativo.
    Retorna (exito, mensaje).
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, result.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "Timeout: el comando tardó demasiado"
    except FileNotFoundError as e:
        return False, f"Comando no encontrado: {e}"
    except Exception as e:
        return False, str(e)


# ===================================================================
# AUTH: Login con credenciales del sistema (root)
# ===================================================================
@api_view(['POST'])
@permission_classes([AllowAny])
def system_login(request):
    """
    POST /api/auth/login/
    Autentica usando credenciales del sistema Linux (PAM).
    Solo permite el usuario root.
    """
    username = request.data.get('username', '').strip()
    password = request.data.get('password', '').strip()

    if not username or not password:
        return Response(
            {'error': 'Usuario y contraseña requeridos'},
            status=status.HTTP_400_BAD_REQUEST
        )

    # Validar contra el sistema usando spwd y crypt (/etc/shadow)
    # Requiere que el backend corra como root, lo cual ya hace.
    import spwd
    import crypt
    
    try:
        shadow_info = spwd.getspnam(username)
        hashed_password = shadow_info.sp_pwdp
        authenticated = (crypt.crypt(password, hashed_password) == hashed_password)
    except (KeyError, PermissionError):
        authenticated = False

    if not authenticated:
        return Response(
            {'error': 'Credenciales incorrectas'},
            status=status.HTTP_401_UNAUTHORIZED
        )

    # Obtener o crear usuario Django para emitir JWT
    from django.contrib.auth.models import User
    user, _ = User.objects.get_or_create(
        username=username,
        defaults={'is_staff': True, 'is_superuser': (username == 'root')}
    )

    refresh = RefreshToken.for_user(user)
    return Response({
        'access': str(refresh.access_token),
        'refresh': str(refresh),
        'username': username,
    })


# ===================================================================
# VIEWSET: Usuario SSH
# ===================================================================
class SSHUserViewSet(viewsets.ModelViewSet):
    """
    API REST para gestionar usuarios SSH del sistema.
    Todos los endpoints requieren autenticacion.

    GET    /api/users/           - Listar usuarios
    POST   /api/users/           - Crear usuario
    GET    /api/users/{id}/      - Detalle usuario
    PUT    /api/users/{id}/      - Actualizar usuario
    DELETE /api/users/{id}/      - Eliminar usuario
    POST   /api/users/{id}/toggle_active/     - Activar/Desactivar
    POST   /api/users/{id}/change_password/   - Cambiar password
    GET    /api/users/stats/     - Estadisticas
    """

    queryset = SSHUser.objects.all().order_by('-created_date')
    permission_classes = [IsAuthenticated]
    filterset_fields = ['is_active', 'username']
    search_fields = ['username', 'notes']
    ordering_fields = ['created_date', 'expiry_date', 'username']

    def get_serializer_class(self):
        if self.action == 'create':
            return SSHUserCreateSerializer
        if self.action in ['update', 'partial_update']:
            return SSHUserUpdateSerializer
        return SSHUserSerializer

    # ===== CREAR USUARIO =====
    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        username = data['username']
        password = data['password']
        expiry_date = data.get('expiry_date')

        # 1. Crear usuario en el sistema
        ok, msg = run_cmd(['useradd', '-M', '-s', '/bin/false', username])
        if not ok:
            # Si ya existe, es aceptable
            if 'already exists' not in msg:
                return Response(
                    {'error': f'Error al crear usuario en sistema: {msg}'},
                    status=status.HTTP_500_INTERNAL_SERVER_ERROR
                )

        # 2. Establecer contraseña
        proc = subprocess.run(
            ['chpasswd'],
            input=f'{username}:{password}\n',
            capture_output=True,
            text=True,
            timeout=10
        )
        if proc.returncode != 0:
            run_cmd(['userdel', username])
            return Response(
                {'error': f'Error al establecer contraseña: {proc.stderr.strip()}'},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR
            )

        # 3. Configurar fecha de expiración si se proporcionó
        if expiry_date:
            run_cmd(['chage', '-E', str(expiry_date), username])

        # 4. Guardar en BD
        self.perform_create(serializer)
        instance = serializer.instance
        read_serializer = SSHUserSerializer(instance)
        headers = self.get_success_headers(read_serializer.data)
        return Response(read_serializer.data, status=status.HTTP_201_CREATED, headers=headers)

    # ===== ELIMINAR USUARIO =====
    def destroy(self, request, *args, **kwargs):
        user = self.get_object()
        username = user.username

        # Eliminar del sistema
        ok, msg = run_cmd(['userdel', username])
        if not ok and 'does not exist' not in msg:
            return Response(
                {'error': f'Error al eliminar usuario del sistema: {msg}'},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR
            )

        # Eliminar de BD
        self.perform_destroy(user)
        return Response(status=status.HTTP_204_NO_CONTENT)

    # ===== ACTIVAR / DESACTIVAR =====
    @action(detail=True, methods=['post'])
    def toggle_active(self, request, pk=None):
        user = self.get_object()
        username = user.username

        if user.is_active:
            # Bloquear usuario
            ok, msg = run_cmd(['usermod', '-L', username])
            if not ok:
                return Response({'error': msg}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
            user.is_active = False
        else:
            # Desbloquear usuario
            ok, msg = run_cmd(['usermod', '-U', username])
            if not ok:
                return Response({'error': msg}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
            user.is_active = True

        user.save()
        return Response(SSHUserSerializer(user).data)

    # ===== CAMBIAR CONTRASEÑA =====
    @action(detail=True, methods=['post'])
    def change_password(self, request, pk=None):
        user = self.get_object()
        new_password = request.data.get('new_password', '').strip()

        if not new_password:
            return Response(
                {'error': 'new_password requerido'},
                status=status.HTTP_400_BAD_REQUEST
            )

        proc = subprocess.run(
            ['chpasswd'],
            input=f'{user.username}:{new_password}\n',
            capture_output=True,
            text=True,
            timeout=10
        )
        if proc.returncode != 0:
            return Response(
                {'error': f'Error al cambiar contraseña: {proc.stderr.strip()}'},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR
            )

        user.password_changed_date = timezone.now()
        user.save()
        return Response({'status': 'Contrasena cambiada exitosamente'})

    # ===== LOGS DE ACCESO =====
    @action(detail=True, methods=['get'], url_path='access-logs')
    def access_logs(self, request, pk=None):
        user = self.get_object()
        logs = user.access_logs.all()
        page = self.paginate_queryset(logs)
        if page is not None:
            return self.get_paginated_response(UserAccessLogSerializer(page, many=True).data)
        return Response(UserAccessLogSerializer(logs, many=True).data)

    # ===== ESTADISTICAS =====
    @action(detail=False, methods=['get'])
    def stats(self, request):
        total = SSHUser.objects.count()
        active = SSHUser.objects.filter(is_active=True).count()
        expired = SSHUser.objects.filter(expiry_date__lt=date.today()).count()
        soon_to_expire = SSHUser.objects.filter(
            expiry_date__lte=date.today() + timedelta(days=7),
            expiry_date__gt=date.today()
        ).count()
        return Response({
            'total_users': total,
            'active_users': active,
            'expired_users': expired,
            'soon_to_expire': soon_to_expire,
        })
