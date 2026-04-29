# 🚀 Guía de Configuración - VPSService Web Panel

Instrucciones completas para configurar y ejecutar el proyecto web panel.

## 📋 Requisitos Previos

### Opción 1: Instalación Manual
- Python 3.9+
- Node.js 18+
- PostgreSQL 12+
- Redis 6+

### Opción 2: Con Docker (Recomendado)
- Docker
- Docker Compose

---

## 🐳 Opción 1: Instalación con Docker (Más Fácil)

### 1. Iniciar Servicios de Base de Datos

```bash
cd web-panel
docker-compose up -d
```

Esto inicia:
- PostgreSQL (puerto 5432)
- Redis (puerto 6379)

### 2. Configurar Backend

```bash
cd web-panel/backend

# Copiar archivo de configuración
cp .env.example .env

# Crear migraciones de base de datos
python manage.py migrate

# Crear superusuario (admin)
python manage.py createsuperuser

# Ejecutar servidor de desarrollo
python manage.py runserver
```

Backend disponible en: `http://localhost:8000`
Admin Django en: `http://localhost:8000/admin`

### 3. Configurar Frontend

```bash
cd web-panel/frontend

# Copiar archivo de configuración
cp .env.example .env

# Instalar dependencias
npm install

# Ejecutar servidor de desarrollo
npm run dev
```

Frontend disponible en: `http://localhost:5173`

---

## 🔧 Opción 2: Instalación Manual

### Backend - Paso a Paso

#### 2.1 Crear Entorno Virtual

```bash
cd web-panel/backend

# Windows
python -m venv venv
venv\Scripts\activate

# macOS/Linux
python3 -m venv venv
source venv/bin/activate
```

#### 2.2 Instalar Dependencias

```bash
pip install -r requirements.txt
```

#### 2.3 Configurar Variables de Entorno

```bash
cp .env.example .env
```

Editar `.env` y configurar:
- `SECRET_KEY`: Generar uno nuevo (https://djecrety.ir/)
- `DB_PASSWORD`: Tu contraseña de PostgreSQL
- Otros valores según sea necesario

#### 2.4 Crear Base de Datos

```bash
# Asegúrate de que PostgreSQL esté corriendo

# Crear base de datos
createdb vpsservice_db

# Aplicar migraciones
python manage.py migrate

# Crear superusuario
python manage.py createsuperuser
```

#### 2.5 Ejecutar Servidor

```bash
python manage.py runserver
```

### Frontend - Paso a Paso

#### 3.1 Instalar Dependencias

```bash
cd web-panel/frontend
npm install
```

#### 3.2 Configurar Variables de Entorno

```bash
cp .env.example .env
```

Asegúrate de que `VITE_API_URL` apunte a tu backend:
```
VITE_API_URL=http://localhost:8000/api
```

#### 3.3 Ejecutar Servidor de Desarrollo

```bash
npm run dev
```

---

## 🧪 Primeros Pasos

### 1. Acceder al Panel

Ir a `http://localhost:5173` e ingresar con las credenciales del superusuario.

### 2. Crear Primer Usuario

1. Ir a "👥 Usuarios"
2. Click en "➕ Crear Usuario"
3. Llenar formulario
4. Click en "Guardar Usuario"

### 3. Instalar un Protocolo

1. Ir a "🔌 Protocolos"
2. Seleccionar protocolo de la lista
3. Confirmar instalación

---

## 🔗 URLs Importantes

| Servicio | URL | Usuario |
|----------|-----|---------|
| Panel Web | http://localhost:5173 | admin/superuser |
| Backend API | http://localhost:8000/api | - |
| Admin Django | http://localhost:8000/admin | admin/superuser |
| PostgreSQL | localhost:5432 | vpsservice_user |
| Redis | localhost:6379 | (sin auth) |

---

## 🏗️ Estructura de Carpetas

```
web-panel/
├── backend/                    # Django API
│   ├── config/                # Configuración principal
│   ├── apps/
│   │   ├── users/            # App de usuarios
│   │   └── protocols/        # App de protocolos
│   ├── manage.py
│   ├── requirements.txt
│   └── .env
│
├── frontend/                   # React + TypeScript
│   ├── src/
│   │   ├── components/       # Componentes React
│   │   ├── pages/           # Páginas principales
│   │   ├── services/        # Servicios (API)
│   │   ├── store/           # Estado global (Zustand)
│   │   ├── App.tsx
│   │   └── main.tsx
│   ├── package.json
│   ├── tsconfig.json
│   └── .env
│
├── docker-compose.yml         # Servicios Docker
└── Dockerfile               # Build de imagen

---

## 🛠️ Comandos Útiles

### Backend

```bash
cd web-panel/backend

# Crear migraciones
python manage.py makemigrations

# Aplicar migraciones
python manage.py migrate

# Ver todos los usuarios
python manage.py shell
>>> from apps.users.models import User
>>> User.objects.all()

# Crear usuario desde CLI
python manage.py shell
>>> from apps.users.models import User
>>> user = User.objects.create_user(username='john', password='pass123')
>>> user.save()

# Tests
python manage.py test

# Recolectar archivos estáticos
python manage.py collectstatic
```

### Frontend

```bash
cd web-panel/frontend

# Desarrollo
npm run dev

# Build para producción
npm run build

# Preview del build
npm run preview

# Type checking
npm run type-check

# Linting
npm run lint

# Formatear código
npm run format
```

---

## 🚨 Solución de Problemas

### Error: "Connection refused" en la API

**Problema**: El frontend no puede conectar con el backend.

**Solución**:
1. Verificar que el backend está corriendo (`python manage.py runserver`)
2. Verificar que `VITE_API_URL` en frontend .env apunta correctamente
3. Verificar CORS en `config/settings.py`

### Error: "migrate" fallando

**Problema**: Las migraciones de Django fallan.

**Solución**:
```bash
# Resetear base de datos (cuidado, borra datos)
python manage.py migrate zero

# Recrear migraciones
python manage.py migrate
```

### Error: Puerto ya en uso

**Problema**: El puerto 8000 o 5173 ya está en uso.

**Solución**:
```bash
# Backend en puerto diferente
python manage.py runserver 8001

# Frontend en puerto diferente
npm run dev -- --port 3000
```

### Error: "No module named 'apps'"

**Problema**: Python no encuentra los módulos de la app.

**Solución**:
```bash
# Asegúrate de estar en la carpeta web-panel/backend
cd web-panel/backend
python manage.py runserver
```

---

## 📦 Desplegar en Producción

### Usando Gunicorn + Nginx

```bash
# Instalar gunicorn
pip install gunicorn

# Ejecutar con gunicorn
gunicorn config.wsgi:application --bind 0.0.0.0:8000
```

### Configuración Nginx

```nginx
server {
    listen 80;
    server_name tu-dominio.com;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        proxy_pass http://127.0.0.1:5173;
    }
}
```

---

## 📚 Documentación

- [Django Docs](https://docs.djangoproject.com/)
- [React Docs](https://react.dev/)
- [Zustand](https://github.com/pmndrs/zustand)
- [TailwindCSS](https://tailwindcss.com/)
- [Axios](https://axios-http.com/)

---

## 🤝 Contribuir

Para contribuir al proyecto:

1. Fork el repositorio
2. Crear una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit cambios (`git commit -m 'Add AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abrir un Pull Request

---

## 📝 Licencia

GNU General Public License v3.0
