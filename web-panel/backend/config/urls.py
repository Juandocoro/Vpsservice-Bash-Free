from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from django.http import JsonResponse
from rest_framework_simplejwt.views import TokenRefreshView
from rest_framework.routers import DefaultRouter
from apps.users.views import SSHUserViewSet, system_login
from apps.protocols.views import ProtocolViewSet

router = DefaultRouter()
router.register(r'users', SSHUserViewSet, basename='users')
router.register(r'protocols', ProtocolViewSet, basename='protocols')

urlpatterns = [
    path('admin/', admin.site.urls),

    # Auth: login con password root del sistema
    path('api/auth/login/', system_login, name='system_login'),
    path('api/auth/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),

    # Healthcheck
    path('api/health/', lambda request: JsonResponse({'status': 'ok'})),

    # API REST (usuarios + protocolos)
    path('api/', include(router.urls)),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)

