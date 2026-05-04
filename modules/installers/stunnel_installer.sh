#!/bin/bash
# Módulo Instalador Stunnel

instalar_stunnel_service() {
    clear
    echo "================================================="
    echo "        CONFIGURAR Y LEVANTAR STUNNEL             "
    echo "================================================="
    echo "Stunnel4 y Dropbear ya han sido instalados silenciosamente."
    echo ""
    echo "Esta fase configurará los certificados SSL y montará"
    echo "el servicio proxy en el puerto 443 hacia SSH(22)."
    echo ""
    read -p "¿Deseas configurar y levantar el túnel AHORA? (s/n): " confirm
    if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then return; fi

    echo "[*] Generando certificado SSL TLS (10 años de validez)..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=Injector/CN=localhost" \
        -keyout /etc/stunnel/stunnel.pem \
        -out /etc/stunnel/stunnel.pem 2>/dev/null

    chmod 600 /etc/stunnel/stunnel.pem

    echo "[*] Escribiendo configuración /etc/stunnel/stunnel.conf..."
    cat <<EOF > /etc/stunnel/stunnel.conf
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = 443
connect = 127.0.0.1:22
EOF

    echo "[*] Montando puertos en el sistema y arrancando el servicio..."
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    systemctl enable stunnel4
    systemctl restart stunnel4

    echo ""
    echo "================================================="
    echo "   [+] Túnel Montado Correctamente "
    echo "   Escuchando en el puerto: 443"
    echo "   Dirigiendo internamente a: 22"
    echo "================================================="
        [ "$WEB_PANEL" = "1" ] && exit 0
    read -p "Presiona Enter para volver al menú de inicio..."
}

instalar_stunnel_service
