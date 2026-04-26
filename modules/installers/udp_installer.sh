#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                  UDP CUSTOM (BadVPN)            "
echo "================================================="

read -p "¿Instalar UDP Custom? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then
    exit 0
fi

# ── Intentar instalar binario precompilado primero (más rápido y confiable) ───
BINARY_URL="https://github.com/ambrop72/badvpn/releases/download/1.999.130/badvpn-udpgw"
echo "[*] Intentando instalar binario precompilado..."
if wget -q --timeout=15 -O /usr/local/bin/badvpn-udpgw "$BINARY_URL" 2>/dev/null && \
   file /usr/local/bin/badvpn-udpgw 2>/dev/null | grep -q "ELF"; then
    chmod +x /usr/local/bin/badvpn-udpgw
    echo "[+] Binario descargado correctamente."
else
    # ── Fallback: compilar desde fuente ──────────────────────────────────────
    rm -f /usr/local/bin/badvpn-udpgw 2>/dev/null
    echo "[*] Binario no disponible — compilando desde fuente..."
    echo "[*] Instalando dependencias de compilación..."
    if ! apt-get install -y cmake build-essential gcc git; then
        echo "[-] Error instalando dependencias. Abortando."
        sleep 3; exit 1
    fi

    cd /tmp
    rm -rf badvpn
    if ! git clone https://github.com/ambrop72/badvpn.git; then
        echo "[-] Error clonando repositorio badvpn. Verifica conexión."
        sleep 3; exit 1
    fi

    cd badvpn && mkdir -p build && cd build
    if ! cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1; then
        echo "[-] Error en cmake. Revisa dependencias o versión del compilador."
        sleep 3; exit 1
    fi
    if ! make install; then
        echo "[-] Error compilando badvpn. Revisa el log anterior."
        sleep 3; exit 1
    fi
fi

if [ ! -f "/usr/local/bin/badvpn-udpgw" ]; then
    echo "[-] No se pudo instalar badvpn-udpgw. Abortando."
    sleep 3
    exit 1
fi

read -p "¿Qué puerto asignar? (Defecto: 7300): " udp_port
if [ -z "$udp_port" ]; then
    udp_port=7300
fi

# Validar que sea un número de puerto
if ! [[ "$udp_port" =~ ^[0-9]+$ ]] || [ "$udp_port" -lt 1 ] || [ "$udp_port" -gt 65535 ]; then
    echo "[-] Puerto inválido. Usando 7300."
    udp_port=7300
fi

cat <<EOF > /etc/systemd/system/badvpn.service
[Unit]
Description=Protocolo Core UDP-Custom BadVPN (Túneles)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${udp_port} --max-clients 500 --max-connections-for-client 10 --client-socket-sndbuf 10000 --client-socket-rcvbuf 10000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn &>/dev/null
systemctl restart badvpn

sleep 2
if systemctl is-active --quiet badvpn; then
    echo "================================================="
    echo "[+] BadVPN UDP instalado y activo en puerto $udp_port."
    echo "================================================="
else
    echo "================================================="
    echo "[-] Servicio instalado pero NO está corriendo."
    echo "    Revisa: systemctl status badvpn"
    echo "================================================="
fi
sleep 2
