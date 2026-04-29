# VPSService Web Panel - Frontend (React + TypeScript)

Panel web visual para gestionar VPS. Interfaz moderna con React, TypeScript y TailwindCSS.

## 📋 Requisitos

- Node.js 18+
- npm o yarn

## 🚀 Instalación Rápida

### 1. Instalar Dependencias

```bash
npm install
```

### 2. Crear Archivo .env

Crear archivo `.env` en la carpeta raíz del frontend:

```env
# API Backend
VITE_API_URL=http://localhost:8000/api

# Otros
VITE_APP_TITLE=VPSService Web Panel
```

### 3. Ejecutar en Desarrollo

```bash
npm run dev
```

El frontend estará disponible en: `http://localhost:5173`

### 4. Build para Producción

```bash
npm run build
```

Esto genera archivos optimizados en la carpeta `dist/`

## 📂 Estructura de Carpetas

```
frontend/
├── src/
│   ├── components/              # Componentes React reutilizables
│   │   ├── UsersList.tsx       # Tabla de usuarios
│   │   ├── ProtocolsList.tsx   # Tabla de protocolos
│   │   ├── LoginForm.tsx       # Formulario de login
│   │   ├── Sidebar.tsx         # Menú lateral
│   │   └── ...
│   │
│   ├── pages/                   # Páginas principales
│   │   ├── LoginPage.tsx       # Página de login
│   │   ├── DashboardPage.tsx   # Dashboard principal
│   │   ├── UsersPage.tsx       # Gestión de usuarios
│   │   ├── ProtocolsPage.tsx   # Gestión de protocolos
│   │   └── ...
│   │
│   ├── services/                # Servicios (API, etc)
│   │   ├── api.ts              # Cliente HTTP Axios
│   │   └── ...
│   │
│   ├── store/                   # Estado global (Zustand)
│   │   ├── index.ts            # Stores de auth, users, protocols
│   │   └── ...
│   │
│   ├── hooks/                   # Custom hooks
│   │   ├── useAuth.ts          # Hook de autenticación
│   │   ├── useUsers.ts         # Hook de usuarios
│   │   └── ...
│   │
│   ├── types/                   # Tipos e interfaces TypeScript
│   │   ├── index.ts
│   │   └── ...
│   │
│   ├── App.tsx                  # Componente raíz
│   └── main.tsx                # Punto de entrada
│
├── public/                      # Archivos estáticos
├── package.json
├── tsconfig.json
├── vite.config.ts
└── README.md
```

## 🎨 Componentes Principales

### UsersList (Lista de Usuarios)

Muestra tabla con usuarios SSH e integración con backend.

```tsx
<UsersList onSelectUser={(user) => console.log(user)} />
```

### ProtocolsList (Lista de Protocolos)

Muestra protocolos instalados.

```tsx
<ProtocolsList onSelectProtocol={(protocol) => console.log(protocol)} />
```

### LoginForm (Formulario de Login)

Autenticación con JWT.

```tsx
<LoginForm onLoginSuccess={() => navigate('/dashboard')} />
```

## 📡 Comunicación con Backend

Todos los datos se obtienen del backend Django a través de `/src/services/api.ts`

### Ejemplo: Crear Usuario

```typescript
import { useUsersStore } from '@/store';

// En componente
const { createUser } = useUsersStore();

const handleCreateUser = async () => {
  try {
    await createUser({
      username: 'john',
      password: 'password123',
      confirm_password: 'password123',
      max_connections: 2,
      expiry_date: '2026-05-29',
    });
  } catch (error) {
    console.error('Error:', error);
  }
};
```

### Ejemplo: Autenticación

```typescript
import { useAuthStore } from '@/store';

// En componente
const { login, isAuthenticated } = useAuthStore();

const handleLogin = async (username: string, password: string) => {
  try {
    await login(username, password);
    // Redirigir a dashboard
  } catch (error) {
    console.error('Error:', error);
  }
};
```

## 🎯 Flujo de Autenticación

1. **Login**: Usuario ingresa credenciales
2. **Token JWT**: Backend retorna `access_token` y `refresh_token`
3. **Almacenamiento**: Tokens se guardan en `localStorage`
4. **Requests**: Cada petición incluye token en header `Authorization: Bearer {token}`
5. **Refresh**: Si token expira, se auto-refresca con `refresh_token`
6. **Logout**: Tokens se borran de `localStorage`

## 🧪 Testing

```bash
# Ejecutar tests
npm test

# Coverage
npm run test:coverage
```

## 🚀 Desplegar en Producción

### Opción 1: Nginx

```nginx
server {
    listen 80;
    server_name yourdomain.com;

    root /var/www/vpsservice-panel/dist;
    index index.html;

    # SPA: redirigir 404 a index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    # API proxy
    location /api/ {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### Opción 2: Vercel

```bash
# Instalar CLI
npm i -g vercel

# Deploy
vercel

# Con dominio personalizado
vercel --prod --alias yourdomain.com
```

## 📚 Tecnologías

- **React 18**: UI library
- **TypeScript**: Type safety
- **Vite**: Build tool (rápido)
- **TailwindCSS**: Utility-first CSS
- **Zustand**: State management (simple y ligero)
- **Axios**: HTTP client
- **React Router**: Navigation

## 🔐 Seguridad

- ✅ JWT authentication
- ✅ CORS configurado
- ✅ HTTPS recommended en producción
- ✅ Tokens en localStorage (XSS protección recomendada)
- ✅ CSRF protection desde backend

## 🐛 Debugging

### Habilitar Redux DevTools

En componente App.tsx:

```typescript
// Instalar extensión en navegador primero
import { devtools } from 'zustand/middleware';
```

### Logs en Consola

El servicio API registra todos los requests/responses.

## 📞 Soporte

Para reportar issues: [GitHub Issues](https://github.com/Juandocoro/Vpsservice-Bash-Free/issues)

## 📄 Licencia

GNU General Public License v3.0
