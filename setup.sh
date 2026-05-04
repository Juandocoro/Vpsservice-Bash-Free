#!/bin/bash
# =========================================================
# vpsservice Script FREE - Setup Universal
# Uso (comando recomendado en el VPS):
#   curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/panel/setup.sh -o /tmp/vps.sh && sudo bash /tmp/vps.sh
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Ejecutar como root."
    echo "    Usa: sudo bash setup.sh"
    exit 1
fi

clear
echo -e "\033[44m\033[1;33m ====>> \033[0;44;36mo \033[1;44;37mvpsservice \033[1;44;32mFREE \033[0;44;36mo \033[1;44;33m <<==== \033[0m"
echo ""
echo -e "\033[0;33m[*]\033[0m Iniciando instalacion..."
echo ""

read -p "Que version deseas instalar? [panel/main] (panel por defecto): " INSTALL_BRANCH
INSTALL_BRANCH=${INSTALL_BRANCH:-panel}
if [ "$INSTALL_BRANCH" != "main" ] && [ "$INSTALL_BRANCH" != "panel" ]; then
    echo -e "\033[0;33m[*]\033[0m Opcion invalida, usando panel por defecto."
    INSTALL_BRANCH="panel"
fi

# =========================================================
# PASO 1: Instalar git si no esta presente
# =========================================================
if ! command -v git &>/dev/null; then
    echo -e "\033[0;33m[*]\033[0m Instalando git..."
    apt-get install -yq git &>/dev/null
fi

# =========================================================
# PASO 2: Limpiar repo anterior si existe
# =========================================================
TARGET_DIR="/opt/vpsservice-free"

if [ -d "$TARGET_DIR" ]; then
    echo -e "\033[0;33m[*]\033[0m Limpiando instalacion anterior..."
    rm -rf "$TARGET_DIR"
fi

# =========================================================
# PASO 3: Clonar repositorio
# =========================================================
echo -e "\033[0;33m[*]\033[0m Clonando repositorio..."
if ! git clone --branch "$INSTALL_BRANCH" --single-branch https://github.com/Juandocoro/Vpsservice-Bash-Free.git "$TARGET_DIR" 2>&1; then
    echo ""
    echo -e "\033[0;31m[-]\033[0m No se pudo clonar el repositorio."
    echo -e "\033[2;37m    Verifica: https://github.com/Juandocoro/Vpsservice-Bash-Free\033[0m"
    exit 1
fi

# =========================================================
# PASO 4: Eliminar CRLF de todos los scripts
# =========================================================
echo -e "\033[0;33m[*]\033[0m Normalizando saltos de linea (CRLF -> LF)..."
find "$TARGET_DIR" -name "*.sh" -exec sed -i 's/\r//' {} \;

# =========================================================
# PASO 5: Permisos totales
# =========================================================
echo -e "\033[0;33m[*]\033[0m Aplicando permisos..."
chmod -R +x "$TARGET_DIR"

# =========================================================
# PASO 6: Registrar comando global 'menu'
# =========================================================
echo -e "\033[0;33m[*]\033[0m Registrando comando global..."
printf '#!/bin/bash\nbash /opt/vpsservice-free/main.sh\n' > /usr/local/bin/menu
chmod +x /usr/local/bin/menu

# =========================================================
# PASO 7: Sembrar Auto-Killer en cron
# =========================================================
if ! crontab -l 2>/dev/null | grep -q "killer.sh"; then
    echo -e "\033[0;33m[*]\033[0m Activando monitor de cuotas..."
    (crontab -l 2>/dev/null; echo "* * * * * $TARGET_DIR/modules/killer.sh") | crontab -
fi

# =========================================================
# PASO 8: Instalar dependencias base
# =========================================================
echo -e "\033[0;33m[*]\033[0m Instalando dependencias base..."
apt-get update -yq &>/dev/null
apt-get install -yq curl stunnel4 openssl dropbear net-tools cmake build-essential python3 python3-pip &>/dev/null
systemctl stop stunnel4 &>/dev/null
systemctl disable stunnel4 &>/dev/null

# =========================================================
# LISTO
# =========================================================
echo ""
echo -e "\033[0;33m--------------------------------------------------------\033[0m"
echo -e "\033[1;32m[+]\033[0m Instalacion completada."
echo -e "\033[2;37m    Instalado en: $TARGET_DIR\033[0m"
echo -e "\033[2;37m    Rama instalada: $INSTALL_BRANCH\033[0m"
echo -e "\033[2;37m    Comando global: menu\033[0m"
echo -e "\033[0;33m--------------------------------------------------------\033[0m"
echo ""
read -p "Presiona Enter para abrir el panel..."
exec bash /opt/vpsservice-free/main.sh
