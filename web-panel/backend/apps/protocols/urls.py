# ===================================================================
# VPSService Web Panel - URL Routing de Protocolos
# ===================================================================

from django.urls import include, path
from rest_framework.routers import DefaultRouter

from .views import ProtocolViewSet

router = DefaultRouter()
router.register(r'', ProtocolViewSet)

urlpatterns = [
    path('', include(router.urls)),
]
