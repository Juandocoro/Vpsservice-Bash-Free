# VPSService Web Panel - Backend (Django)

Panel web para gestionar VPS desde interfaz visual. Backend API REST con Django.

## 📋 Requisitos

- Python 3.9+
- Django 4.2+
- PostgreSQL o SQLite (por defecto)

## 🚀 Instalación Rápida

### 1. Crear Virtual Environment

```bash
# Windows
python -m venv venv
venv\Scripts\activate

# Linux/Mac
python3 -m venv venv
source venv/bin/activate
```

### 2. Instalar Dependencias

```bash
pip install -r requirements.txt
```

### 3. Configurar Variables de Entorno

Crear archivo `.env` en la carpeta `backend/`:

```env
# Django
DEBUG=True
DJANGO_SECRET_KEY=your-secret-key-here-change-in-production

# Base de Datos (SQLite por defecto en desarrollo)
# DB_ENGINE=django.db.backends.sqlite3
# DB_NAME=db.sqlite3

# Base de Datos (PostgreSQL en producción)
# DB_ENGINE=django.db.backends.postgresql
# DB_NAME=vpsservice
# DB_USER=postgres
# DB_PASSWORD=your_password
# DB_HOST=localhost
# DB_PORT=5432

# SSH al VPS
VPS_HOST=your-vps-ip.com
VPS_SSH_PORT=22
VPS_SSH_USER=root
VPS_SSH_PASSWORD=your-password
# O usar archivo key:
# VPS_SSH_KEY_FILE=/path/to/private/key

# CORS - Permitir frontend
CORS_ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173

# Servidor
ALLOWED_HOSTS=*
```

### 4. Migraciones de Base de Datos

```bash
# Crear migraciones
python manage.py makemigrations

# Aplicar migraciones
python manage.py migrate

# Crear superusuario (admin)
python manage.py createsuperuser
```

### 5. Recopilar Archivos Estáticos

```bash
python manage.py collectstatic --noinput
```

### 6. Ejecutar Servidor de Desarrollo

```bash
python manage.py runserver
```

El servidor estará disponible en: `http://localhost:8000`

Panel admin: `http://localhost:8000/admin`

## 📚 Documentación de API

### Autenticación

Todos los endpoints requieren token JWT.

#### Obtener Token

```bash
POST /api/auth/token/
Content-Type: application/json

{
  "username": "admin",
  "password": "password123"
}
```

Respuesta:

```json
{
  "access": "eyJ0eXAiOiJKV1QiLCJhbGc...",
  "refresh": "eyJ0eXAiOiJKV1QiLCJhbGc..."
}
```

#### Usar Token en Peticiones

```bash
GET /api/users/
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGc...
```

### Endpoints de Usuarios

#### Listar Usuarios

```bash
GET /api/users/

# Filtrado y búsqueda
GET /api/users/?is_active=true&search=john
GET /api/users/?ordering=-created_date
```

Respuesta:

```json
{
  "count": 10,
  "next": "http://localhost:8000/api/users/?page=2",
  "previous": null,
  "results": [
    {
      "id": 1,
      "username": "john",
      "max_connections": 2,
      "created_date": "2026-04-29T10:30:00Z",
      "expiry_date": "2026-05-29",
      "is_active": true,
      "is_expired": false,
      "days_until_expiry": 30,
      "created_by": "admin",
      "notes": ""
    }
  ]
}
```

#### Crear Usuario

```bash
POST /api/users/
Content-Type: application/json

{
  "username": "john",
  "password": "password123",
  "confirm_password": "password123",
  "max_connections": 2,
  "expiry_date": "2026-05-29",
  "notes": "Usuario de prueba"
}
```

#### Obtener Detalles de Usuario

```bash
GET /api/users/1/
```

#### Actualizar Usuario

```bash
PUT /api/users/1/
Content-Type: application/json

{
  "max_connections": 3,
  "expiry_date": "2026-06-29",
  "notes": "Actualizado"
}
```

#### Eliminar Usuario

```bash
DELETE /api/users/1/
```

#### Activar/Desactivar Usuario

```bash
POST /api/users/1/toggle_active/
```

#### Ver Logs de Acceso

```bash
GET /api/users/1/access-logs/
```

#### Cambiar Contraseña

```bash
POST /api/users/1/change-password/
Content-Type: application/json

{
  "new_password": "new-password-123"
}
```

#### Obtener Estadísticas

```bash
GET /api/users/stats/
```

Respuesta:

```json
{
  "total_users": 10,
  "active_users": 8,
  "expired_users": 1,
  "soon_to_expire": 2
}
```

## 🔌 Endpoints de Protocolos

Similar a usuarios, estos endpoints administran protocolos/servicios:

```bash
GET    /api/protocols/                → Listar protocolos
POST   /api/protocols/                → Instalar protocolo
GET    /api/protocols/{id}/           → Obtener detalles
PUT    /api/protocols/{id}/           → Actualizar
DELETE /api/protocols/{id}/           → Desinstalar
```

## 🗄️ Estructura de Carpetas

```
backend/
  ├── config/                  # Configuración Django
  │   ├── settings.py         # Settings principales
  │   ├── urls.py             # URLs raíz
  │   └── wsgi.py             # WSGI para producción
  │
  ├── apps/                    # Aplicaciones Django
  │   ├── users/              # Gestión de usuarios SSH
  │   │   ├── models.py       # Modelos
  │   │   ├── views.py        # Vistas API
  │   │   ├── serializers.py  # Serializers
  │   │   └── urls.py         # URLs
  │   │
  │   ├── protocols/          # Gestión de protocolos
  │   ├── servers/            # Info del servidor
  │   └── dashboard/          # Estadísticas/dashboard
  │
  ├── manage.py               # Management CLI
  ├── requirements.txt        # Dependencias
  └── README.md              # Este archivo
```

## 🐛 Desarrollo

### Ejecutar Tests

```bash
pytest
```

### Activar Django Debug Toolbar

En `config/settings.py`, agregar `'debug_toolbar'` a `INSTALLED_APPS`

### Crear Nueva App

```bash
python manage.py startapp nombre_app apps/nombre_app
```

## 📦 Desplegar en Producción

### Usando Gunicorn + Nginx

```bash
# Instalar Gunicorn
pip install gunicorn

# Ejecutar con Gunicorn
gunicorn config.wsgi:application --bind 0.0.0.0:8000
```

### Variables de Entorno Producción

```env
DEBUG=False
DJANGO_SECRET_KEY=your-production-secret-key
ALLOWED_HOSTS=yourdomain.com,www.yourdomain.com
DB_ENGINE=django.db.backends.postgresql
DB_NAME=vpsservice
DB_USER=postgres
DB_PASSWORD=strong-password
DB_HOST=db.yourdomain.com
DB_PORT=5432
SECURE_SSL_REDIRECT=True
SESSION_COOKIE_SECURE=True
CSRF_COOKIE_SECURE=True
```

## 🔒 Seguridad

- ✅ Autenticación JWT
- ✅ CORS configurado
- ✅ CSRF protection
- ✅ SQL injection protection
- ✅ XSS protection
- ✅ Contraseñas NO se almacenan en BD (se usan comandos SSH)

## 📞 Soporte

Para reportar issues: [GitHub Issues](https://github.com/Juandocoro/Vpsservice-Bash-Free/issues)
