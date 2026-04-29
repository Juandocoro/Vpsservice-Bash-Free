#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "               DROPBEAR SSH                      "
echo "================================================="
echo "Dropbear es un servidor SSH alternativo, ligero"
echo "y eficiente. Ideal para correr en puertos extra."
echo ""

read -p "¿Instalar Dropbear SSH? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "¿Puerto para Dropbear? (Defecto: 442): " db_port
if [ -z "$db_port" ]; then db_port=442; fi

# Validar puerto
if ! [[ "$db_port" =~ ^[0-9]+$ ]] || [ "$db_port" -lt 1 ] || [ "$db_port" -gt 65535 ]; then
    echo "[-] Puerto inválido. Usando 442."
    db_port=442
fi

echo "[*] Instalando Dropbear..."
apt-get install -yq dropbear &>/dev/null

echo "[*] Configurando puerto $db_port..."
sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$db_port/" /etc/default/dropbear 2>/dev/null
sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear 2>/dev/null

# Si no existe la línea, la agregamos
if ! grep -q "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null; then
    echo "DROPBEAR_PORT=$db_port" >> /etc/default/dropbear
    echo "NO_START=0" >> /etc/default/dropbear
fi

# Asegurarse que no colisione con OpenSSH
if [ "$db_port" == "22" ]; then
    echo "[!] Advertencia: El puerto 22 es usado por OpenSSH. Se recomienda usar otro."
fi

systemctl enable dropbear &>/dev/null
systemctl restart dropbear &>/dev/null

# Abrir en firewall si aplica
if command -v ufw &>/dev/null; then
    ufw allow "$db_port"/tcp &>/dev/null
fi

echo ""
echo "================================================="
echo "[+] Dropbear SSH instalado y activo."
echo "    Puerto: $db_port/TCP"
echo "================================================="
read -p "Presiona Enter para volver..."
