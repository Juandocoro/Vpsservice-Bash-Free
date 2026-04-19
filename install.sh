#!/bin/bash
# =========================================================
# vpsservice Script FREE — Instalador interno
# (Llamado por setup.sh — no ejecutar directamente)
# =========================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecutar como root."
  exit 1
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo -e "\033[0;33m[*]\033[0m Instalando dependencias..."
apt-get update -yq &>/dev/null
apt-get install -yq curl stunnel4 openssl dropbear net-tools cmake build-essential python3 python3-pip &>/dev/null

systemctl stop stunnel4 &>/dev/null
systemctl disable stunnel4 &>/dev/null

echo -e "\033[0;33m[*]\033[0m Aplicando permisos..."
chmod -R +x "$DIR"

echo -e "\033[0;33m[*]\033[0m Sembrando monitor de cuotas (Auto-Killer)..."
if ! crontab -l 2>/dev/null | grep -q "killer.sh"; then
    (crontab -l 2>/dev/null; echo "* * * * * $DIR/modules/killer.sh") | crontab -
fi

echo -e "\033[0;33m[*]\033[0m Registrando comando global 'menu'..."
cat <<EOF > /usr/local/bin/menu
#!/bin/bash
cd "$DIR" && sudo ./main.sh
EOF
chmod +x /usr/local/bin/menu

echo ""
echo -e "\033[0;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;32m[+]\033[0m Instalación completada."
echo -e "\033[2;37m    Comando global: menu\033[0m"
echo -e "\033[0;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
read -p "$(echo -e "\033[2;37m")Presiona Enter para abrir el panel...$(echo -e "\033[0m")"
menu
