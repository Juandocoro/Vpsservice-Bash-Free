# ===================================================================
# VPSService Web Panel - Django Main Configuration
# Backend API para gestionar VPS desde interfaz web
# ===================================================================

# Configuración de Django, Base de Datos, Autenticación, CORS, etc.

import os
from pathlib import Path
from decouple import config
from datetime import timedelta

# ===================================================================
# 1. PATH BASE Y DIRECTORIO DEL PROYECTO
# ===================================================================
BASE_DIR = Path(__file__).resolve().parent.parent

# ===================================================================
# 2. SEGURIDAD - SECRET KEY Y DEBUG
# ===================================================================
# ⚠️ IMPORTANTE: En producción, usar variables de entorno
SECRET_KEY = config('DJANGO_SECRET_KEY', default='dev-secret-key-change-in-production')
DEBUG = config('DEBUG', default=True, cast=bool)
ALLOWED_HOSTS = config('ALLOWED_HOSTS', default='*').split(',')

# ===================================================================
# 3. APLICACIONES INSTALADAS
# ===================================================================
INSTALLED_APPS = [
    # Django defaults
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',

    # Third-party apps
    'rest_framework',                    # API REST
    'corsheaders',                       # CORS para frontend
    'rest_framework_simplejwt',          # Autenticación JWT

    # Aplicaciones propias
    'apps.users',                        # Gestión de usuarios SSH
    'apps.protocols',                    # Gestión de protocolos (Stunnel, OpenVPN, etc)
    'apps.servers',                      # Información del servidor
    'apps.dashboard',                    # Dashboard y estadísticas
]

# ===================================================================
# 4. MIDDLEWARE (Procesadores de peticiones HTTP)
# ===================================================================
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'corsheaders.middleware.CorsMiddleware',              # CORS debe ir primero
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

# ===================================================================
# 5. CONFIGURACIÓN RAÍZ URL
# ===================================================================
ROOT_URLCONF = 'config.urls'

# ===================================================================
# 6. TEMPLATES - Renderizado de HTML (si se usa)
# ===================================================================
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

# ===================================================================
# 7. DATABASE WSGI
# ===================================================================
WSGI_APPLICATION = 'config.wsgi.application'

# ===================================================================
# 8. BASE DE DATOS
# ===================================================================
# OPCIÓN 1: SQLite (desarrollo)
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
    }
}

# OPCIÓN 2: PostgreSQL (producción)
# DATABASES = {
#     'default': {
#         'ENGINE': 'django.db.backends.postgresql',
#         'NAME': config('DB_NAME', default='vpsservice'),
#         'USER': config('DB_USER', default='postgres'),
#         'PASSWORD': config('DB_PASSWORD'),
#         'HOST': config('DB_HOST', default='localhost'),
#         'PORT': config('DB_PORT', default='5432'),
#     }
# }

# ===================================================================
# 9. AUTENTICACIÓN Y CONTRASEÑAS
# ===================================================================
AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# ===================================================================
# 10. CONFIGURACIÓN DE IDIOMA Y ZONA HORARIA
# ===================================================================
LANGUAGE_CODE = 'es-es'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

# ===================================================================
# 11. ARCHIVOS ESTÁTICOS Y MEDIA
# ===================================================================
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

# ===================================================================
# 12. CONFIGURACIÓN DEFAULT AUTO FIELD
# ===================================================================
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# ===================================================================
# 13. REST FRAMEWORK - CONFIGURACIÓN API
# ===================================================================
REST_FRAMEWORK = {
    # Autenticación por defecto
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'rest_framework_simplejwt.authentication.JWTAuthentication',
    ),

    # Permisos por defecto (requiere estar autenticado)
    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticated',
    ),

    # Paginación
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 25,

    # Filtrado y búsqueda
    'DEFAULT_FILTER_BACKENDS': [
        'rest_framework.filters.SearchFilter',
        'rest_framework.filters.OrderingFilter',
        'django_filters.rest_framework.DjangoFilterBackend',
    ],

    # Formato de salida JSON bonito
    'DEFAULT_RENDERER_CLASSES': [
        'rest_framework.renderers.JSONRenderer',
    ],
}

# ===================================================================
# 14. JWT - CONFIGURACIÓN DE TOKENS
# ===================================================================
SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(hours=1),        # Token vence en 1 hora
    'REFRESH_TOKEN_LIFETIME': timedelta(days=7),        # Refresh token válido 7 días
    'ROTATE_REFRESH_TOKENS': True,                      # Rotar token al refrescar
    'ALGORITHM': 'HS256',                               # Algoritmo de codificación
}

# ===================================================================
# 15. CORS - PERMITIR PETICIONES DESDE FRONTEND
# ===================================================================
CORS_ALLOWED_ORIGINS = config(
    'CORS_ALLOWED_ORIGINS',
    default='http://localhost:3000,http://localhost:5173'
).split(',')

CORS_ALLOW_CREDENTIALS = True

# ===================================================================
# 16. LOGGING - REGISTROS DE EVENTOS
# ===================================================================
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
        },
        'file': {
            'class': 'logging.FileHandler',
            'filename': BASE_DIR / 'logs/django.log',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'INFO',
    },
}

# ===================================================================
# 17. SSH CONFIGURATION - CONEXIÓN A VPS
# ===================================================================
# Configuración para conectar al servidor VPS por SSH (ejecutar comandos)
SSH_CONFIG = {
    'HOST': config('VPS_HOST', default='localhost'),
    'PORT': config('VPS_SSH_PORT', default=22, cast=int),
    'USERNAME': config('VPS_SSH_USER', default='root'),
    'PASSWORD': config('VPS_SSH_PASSWORD', default=''),
    'KEY_FILE': config('VPS_SSH_KEY_FILE', default=None),
}

# ===================================================================
# 18. TIMEOUT Y SEGURIDAD
# ===================================================================
DATA_UPLOAD_MAX_MEMORY_SIZE = 10485760  # 10MB
FILE_UPLOAD_MAX_MEMORY_SIZE = 10485760  # 10MB

# HTTPS (en producción)
# SECURE_SSL_REDIRECT = True
# SESSION_COOKIE_SECURE = True
# CSRF_COOKIE_SECURE = True
