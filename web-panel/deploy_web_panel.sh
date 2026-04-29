#!/usr/bin/env bash
set -euo pipefail

# Instalador / Despliegue del panel web
# - Pide el dominio a usar
# - Genera archivos .env para backend y frontend
# - Opción para levantar con docker-compose

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$DIR/.." && pwd )"

CR="\033[0m"
GR="\033[1;32m"
RD="\033[0;31m"
YL="\033[0;33m"
DM="\033[2;37m"
WH="\033[1;37m"

echo -e "${WH}==> VPSService Web Panel - Instalador${CR}"
echo

read -p "Dominio (ej: panel.midominio.com) [dejar vacío para usar IP]: " DOMAIN

# Validar dominio simple
if [ -n "$DOMAIN" ]; then
    if ! echo "$DOMAIN" | grep -Eq "^([a-zA-Z0-9][-a-zA-Z0-9]{0,62})(\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+$"; then
        echo -e "${YL}[!]${CR} Dominio con formato inválido, continúa con el valor ingresado pero revisa manualmente."
    fi
fi

# Determinar API URL
if [ -n "$DOMAIN" ]; then
    API_URL="http://$DOMAIN/api"
else
    SERVER_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
    API_URL="http://$SERVER_IP/api"
    DOMAIN="$SERVER_IP"
fi

echo
echo -e "${DM}Generando archivos .env para backend y frontend...${CR}"

# BACKEND .env
BACKEND_ENV="$DIR/backend/.env"
if [ -f "$DIR/backend/.env.example" ]; then
    cp "$DIR/backend/.env.example" "$BACKEND_ENV"
else
    echo -e "${YL}[!]${CR} No se encontró backend/.env.example; creando .env básico"
    cat > "$BACKEND_ENV" <<EOF
DEBUG=False
SECRET_KEY=replace-me
ALLOWED_HOSTS=$DOMAIN
DB_ENGINE=django.db.backends.postgresql
DB_NAME=vpsservice_db
DB_USER=vpsservice_user
DB_PASSWORD=vpsservice_password
DB_HOST=localhost
DB_PORT=5432
REDIS_URL=redis://localhost:6379/0
EOF
fi

# Generar SECRET_KEY si está en la plantilla
if grep -q "SECRET_KEY" "$BACKEND_ENV" 2>/dev/null; then
    # generar secret key
    if command -v python3 >/dev/null 2>&1; then
        SECRET_KEY=$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(50))
PY
)
    else
        SECRET_KEY=$(head -c 32 /dev/urandom | base64)
    fi
    sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$SECRET_KEY/" "$BACKEND_ENV" || true
fi

# Actualizar ALLOWED_HOSTS
sed -i "s/^ALLOWED_HOSTS=.*/ALLOWED_HOSTS=${DOMAIN}/" "$BACKEND_ENV" || true

# FRONTEND .env
FRONTEND_ENV="$DIR/frontend/.env"
if [ -f "$DIR/frontend/.env.example" ]; then
    cp "$DIR/frontend/.env.example" "$FRONTEND_ENV"
else
    cat > "$FRONTEND_ENV" <<EOF
VITE_API_URL=$API_URL
VITE_APP_TITLE=VPSService Web Panel
EOF
fi

# Reemplazar VITE_API_URL si existe
if grep -q "VITE_API_URL" "$FRONTEND_ENV" 2>/dev/null; then
    sed -i "s|^VITE_API_URL=.*|VITE_API_URL=$API_URL|" "$FRONTEND_ENV" || true
else
    echo "VITE_API_URL=$API_URL" >> "$FRONTEND_ENV"
fi

echo -e "${GR}[+]${CR} Archivos .env generados:
  - $BACKEND_ENV
  - $FRONTEND_ENV"

echo
read -p "¿Deseas levantar los servicios con Docker Compose ahora? (recomendado) (s/n): " DOCKER_ANS
if [[ "$DOCKER_ANS" =~ ^[sS] ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RD}[-]${CR} Docker no está instalado en este sistema. Instala Docker y vuelve a intentar."
        exit 1
    fi
    if [ -f "$DIR/docker-compose.yml" ]; then
        echo -e "${DM}Ejecutando docker-compose up -d...${CR}"
        (cd "$DIR" && docker-compose up -d)
        echo -e "${GR}[+]${CR} Servicios levantados con Docker Compose."
    else
        echo -e "${YL}[!]${CR} No se encontró $DIR/docker-compose.yml. Ejecuta el despliegue manualmente."
    fi
else
    echo -e "${DM}Omitiendo levantamiento con Docker. Puedes iniciar manualmente más tarde.${CR}"
fi

echo
echo -e "${GR}[+]${CR} Instalación básica completada. Accede a: http://$DOMAIN (frontend) y http://$DOMAIN/api (API) si todo está levantado."
echo
exit 0
