#!/bin/bash
# =========================================================
# VPSService Web Panel - Deploy sin Docker
# Instala backend (Django + Gunicorn) y frontend (Vite build)
# sirviendo todo desde Nginx en el mismo VPS
# =========================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$DIR/backend"
FRONTEND_DIR="$DIR/frontend"
PANEL_PORT=8765
DOMAIN=""

GR="\033[1;32m"
RD="\033[0;31m"
YL="\033[0;33m"
WH="\033[1;37m"
DM="\033[2;37m"
CR="\033[0m"

echo -e "${WH}=> VPSService Web Panel - Instalador${CR}"
echo ""

# =========================================================
# 0. Verificar root
# =========================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RD}[-]${CR} Ejecutar como root: sudo bash deploy_web_panel.sh"
    exit 1
fi

# =========================================================
# 1. Pedir dominio (opcional)
# =========================================================
read -p "Dominio o IP para el panel [dejar vacio = usar IP publica]: " DOMAIN
if [ -z "$DOMAIN" ]; then
    DOMAIN=$(curl -s ifconfig.me 2>/dev/null || echo "127.0.0.1")
fi
echo -e "${DM}  Usando: $DOMAIN${CR}"
echo ""

# =========================================================
# 2. Instalar dependencias del sistema
# =========================================================
echo -e "${YL}[*]${CR} Instalando dependencias del sistema..."
apt-get update -yq &>/dev/null
apt-get install -yq python3 python3-pip python3-venv nginx curl wget &>/dev/null

if ! command -v ttyd &> /dev/null; then
    echo -e "${YL}[*]${CR} Instalando ttyd para terminales web..."
    wget -qO /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.3/ttyd.x86_64
    chmod +x /usr/local/bin/ttyd
fi
echo -e "${GR}[+]${CR} Dependencias instaladas."

# =========================================================
# 3. Backend: entorno virtual + dependencias Python
# =========================================================
echo -e "${YL}[*]${CR} Configurando backend Python..."
cd "$BACKEND_DIR"

# Crear entorno virtual si no existe
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate

# Instalar dependencias
pip install -q --upgrade pip
pip install -q -r requirements.txt
pip install -q gunicorn

# Generar .env si no existe
if [ ! -f ".env" ]; then
    SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
    cat > .env <<ENVEOF
DEBUG=False
SECRET_KEY=$SECRET
ALLOWED_HOSTS=$DOMAIN,localhost,127.0.0.1
DB_ENGINE=django.db.backends.sqlite3
CORS_ALLOWED_ORIGINS=http://$DOMAIN,http://localhost
ENVEOF
    echo -e "${GR}[+]${CR} Archivo .env generado."
fi

# Migraciones y superusuario
python3 manage.py migrate --run-syncdb &>/dev/null
python3 manage.py collectstatic --noinput &>/dev/null
deactivate
echo -e "${GR}[+]${CR} Backend configurado."

# =========================================================
# 4. Frontend: usar build precompilado
# =========================================================
echo -e "${YL}[*]${CR} Verificando frontend..."
if [ ! -d "$FRONTEND_DIR/dist" ]; then
    echo -e "${RD}[-]${CR} Error: La carpeta 'dist' del frontend no existe."
    echo -e "${DM}    Asegurate de descargar la version completa del panel desde GitHub.${CR}"
    exit 1
fi
echo -e "${GR}[+]${CR} Frontend detectado correctamente."

# =========================================================
# 5. Configurar servicio systemd para Gunicorn
# =========================================================
echo -e "${YL}[*]${CR} Configurando servicio Gunicorn..."
cat > /etc/systemd/system/vpsservice-panel.service <<SVCEOF
[Unit]
Description=VPSService Web Panel (Gunicorn)
After=network.target

[Service]
User=root
WorkingDirectory=$BACKEND_DIR
ExecStart=$BACKEND_DIR/venv/bin/gunicorn config.wsgi:application --bind 127.0.0.1:$PANEL_PORT --workers 2
Restart=always
RestartSec=5
Environment="DJANGO_SETTINGS_MODULE=config.settings"

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable vpsservice-panel &>/dev/null
systemctl restart vpsservice-panel
echo -e "${GR}[+]${CR} Gunicorn corriendo en 127.0.0.1:$PANEL_PORT."

# =========================================================
# 6. Configurar Nginx
# =========================================================
echo -e "${YL}[*]${CR} Configurando Nginx..."
cat > /etc/nginx/sites-available/vpsservice-panel <<NGINXEOF
server {
    listen 80 default_server;
    server_name _;

    # Frontend (archivos estaticos de React)
    root $FRONTEND_DIR/dist;
    index index.html;

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Prevenir caché agresivo de index.html
    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    # API -> Gunicorn
    location /api/ {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }

    # Terminal Web TTYD (WebSockets)
    location /terminal/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    # Admin Django
    location /admin/ {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
    }

    # Estaticos Django
    location /static/ {
        alias $BACKEND_DIR/staticfiles/;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/vpsservice-panel /etc/nginx/sites-enabled/vpsservice-panel
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t && systemctl reload nginx
echo -e "${GR}[+]${CR} Nginx configurado y recargado."

# =========================================================
# LISTO
# =========================================================
echo ""
echo -e "${YL}--------------------------------------------------------${CR}"
echo -e "${GR}[+]${CR} Panel web instalado correctamente."
echo -e "${DM}    URL del panel  : ${WH}http://$DOMAIN${CR}"
echo -e "${DM}    API Backend    : ${WH}http://$DOMAIN/api/${CR}"
echo -e "${DM}    Usuario login  : ${WH}root${CR} (usa tu password root actual)"
echo -e "${YL}--------------------------------------------------------${CR}"
echo ""
