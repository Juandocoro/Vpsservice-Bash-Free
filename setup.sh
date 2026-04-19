#!/bin/bash
# =========================================================
# vpsservice Script FREE — Setup Universal
# Uso:
#   sudo bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh)
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Ejecutar como root."
    echo "    Usa: sudo bash setup.sh"
    exit 1
fi

clear
echo -e "\033[44m\033[1;33m ====►► \033[0;44;36m◈ \033[1;44;37mvpsservice \033[1;44;32mFREE \033[0;44;36m◈ \033[1;44;33m ◄◄==== \033[0m"
echo ""
echo -e "\033[0;33m[*]\033[0m Iniciando instalación..."
echo ""

# =========================================================
# PASO 1: Instalar git si no está presente
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
    echo -e "\033[0;33m[*]\033[0m Limpiando instalación anterior..."
    rm -rf "$TARGET_DIR"
fi

# =========================================================
# PASO 3: Clonar repositorio
# =========================================================
echo -e "\033[0;33m[*]\033[0m Clonando repositorio..."
git clone https://github.com/Juandocoro/Vpsservice-Bash-Free.git "$TARGET_DIR" &>/dev/null

if [ ! -d "$TARGET_DIR" ]; then
    echo -e "\033[0;31m[-]\033[0m Error al clonar. Revisa acceso a GitHub."
    exit 1
fi

# =========================================================
# PASO 4: Permisos totales — todos los .sh de una vez
# =========================================================
echo -e "\033[0;33m[*]\033[0m Aplicando permisos..."
chmod -R +x "$TARGET_DIR"

# =========================================================
# PASO 5: Registrar comando global 'menu'
# =========================================================
echo -e "\033[0;33m[*]\033[0m Registrando comando global..."
cat <<EOF > /usr/local/bin/menu
#!/bin/bash
cd "$TARGET_DIR" && sudo ./main.sh
EOF
chmod +x /usr/local/bin/menu

# =========================================================
# PASO 6: Sembrar Auto-Killer en cron
# =========================================================
if ! crontab -l 2>/dev/null | grep -q "killer.sh"; then
    echo -e "\033[0;33m[*]\033[0m Activando monitor de cuotas..."
    (crontab -l 2>/dev/null; echo "* * * * * $TARGET_DIR/modules/killer.sh") | crontab -
fi

# =========================================================
# PASO 7: Instalar dependencias base
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
echo -e "\033[0;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;32m[+]\033[0m Instalación completada."
echo -e "\033[2;37m    Instalado en: $TARGET_DIR\033[0m"
echo -e "\033[2;37m    Comando global: menu\033[0m"
echo -e "\033[0;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
read -p "$(echo -e "\033[2;37m")Presiona Enter para abrir el panel...$(echo -e "\033[0m")"
menu
