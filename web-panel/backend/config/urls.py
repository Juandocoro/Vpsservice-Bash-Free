# ===================================================================
# VPSService Web Panel - URL Routing (Principal)
# Enruta todas las peticiones HTTP a las vistas correctas
# ===================================================================

from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework_simplejwt.views import (
    TokenObtainPairView,      # Obtener token JWT (login)
    TokenRefreshView,         # Refrescar token JWT
)

# ===================================================================
# URL PATTERNS - RUTAS PRINCIPALES
# ===================================================================
urlpatterns = [
    # ===== ADMINISTRACIÓN =====
    # Panel administrativo de Django (solo para desarrolladores)
    path('admin/', admin.site.urls),

    # ===== AUTENTICACIÓN =====
    # Endpoints para obtener y refrescar tokens JWT
    path('api/auth/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),      # POST: obtener token
    path('api/auth/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),    # POST: refrescar token

    # ===== API REST =====
    # Usuarios SSH
    path('api/users/', include('apps.users.urls')),              # Gestión de usuarios

    # Protocolos (Stunnel, OpenVPN, V2Ray, etc)
    path('api/protocols/', include('apps.protocols.urls')),      # Gestión de protocolos

    # Información del servidor
    path('api/servers/', include('apps.servers.urls')),          # Estado del VPS

    # Dashboard y estadísticas
    path('api/dashboard/', include('apps.dashboard.urls')),      # Información general
]

# ===================================================================
# ARCHIVOS ESTÁTICOS Y MEDIA (en desarrollo)
# ===================================================================
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
