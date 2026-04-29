# ===================================================================
# VPSService Web Panel - URL Routing de Usuarios
# Define todas las rutas disponibles en la API de usuarios
# ===================================================================

from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import SSHUserViewSet

# ===================================================================
# ROUTER - Registra automáticamente rutas CRUD
# ===================================================================
router = DefaultRouter()

# Registra el viewset para generar automáticamente:
# GET    /api/users/                 → listar
# GET    /api/users/{id}/            → obtener uno
# POST   /api/users/                 → crear
# PUT    /api/users/{id}/            → actualizar completo
# PATCH  /api/users/{id}/            → actualizar parcial
# DELETE /api/users/{id}/            → eliminar
router.register(r'', SSHUserViewSet)

# ===================================================================
# URL PATTERNS
# ===================================================================
urlpatterns = [
    path('', include(router.urls)),
    # Las acciones personalizadas se incluyen automáticamente en el router
    # Ej: /api/users/{id}/toggle/
    #     /api/users/{id}/access-logs/
    #     /api/users/stats/
]
