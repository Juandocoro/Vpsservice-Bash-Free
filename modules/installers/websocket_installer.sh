#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

# Lenguaje visual compartido del panel
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/../ui.sh"

clear

ui_header "FREE · INSTALADOR"
ui_section "WEBSOCKET PROXY"

ui_prompt "¿Instalar Proxy Websocket? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then
    exit 0
fi

ui_prompt "¿Puerto Local SSH o Dropbear? (Defecto: 22)"; s_port="$REPLY_UI"
if [ -z "$s_port" ]; then
    s_port=22
fi

ui_prompt "¿Puerto Público Web? (Defecto: 80)"; p_port="$REPLY_UI"
if [ -z "$p_port" ]; then
    p_port=80
fi

ui_info "Instalando scripts..."

mkdir -p /etc/websocket
cat << 'EOF' > /etc/websocket/proxy.py
#!/usr/bin/python3
import socket, threading, sys, os, signal

LISTEN_PORT = int(os.environ.get('WS_PORT', 80))
SSH_PORT    = int(os.environ.get('SSH_PORT', 22))

def forward(src, dst, stop_event):
    """Reenvía datos entre dos sockets. Cierra ambos al terminar."""
    try:
        while not stop_event.is_set():
            try:
                src.settimeout(60)          # timeout de inactividad 60 s
                data = src.recv(4096)
            except socket.timeout:
                continue
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        # FIX: cerrar ambos extremos para liberar descriptores y
        # evitar acumulación de conexiones en estado CLOSE_WAIT.
        stop_event.set()
        try: src.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        try: src.close()
        except Exception: pass
        try: dst.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        try: dst.close()
        except Exception: pass

def handle_client(client_socket):
    ssh_socket = None
    try:
        client_socket.settimeout(10)
        req = client_socket.recv(8192)
        if not req:
            return
        res = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n\r\n"
        )
        client_socket.sendall(res.encode('utf-8'))
        client_socket.settimeout(None)

        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.connect(('127.0.0.1', SSH_PORT))

        # stop_event compartido: cuando un lado cae, el otro se cierra también
        stop_event = threading.Event()
        t1 = threading.Thread(target=forward, args=(client_socket, ssh_socket, stop_event), daemon=True)
        t2 = threading.Thread(target=forward, args=(ssh_socket, client_socket, stop_event), daemon=True)
        t1.start()
        t2.start()
    except Exception:
        try: client_socket.close()
        except Exception: pass
        if ssh_socket:
            try: ssh_socket.close()
            except Exception: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # FIX: aumentar backlog y habilitar keepalive a nivel de servidor
    server.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(200)
    print(f"[*] Escuchando en {LISTEN_PORT} -> Redireccionando a {SSH_PORT}")
    while True:
        try:
            client_socket, addr = server.accept()
            # Keepalive en cada conexión cliente para detectar desconexiones
            client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            threading.Thread(target=handle_client, args=(client_socket,), daemon=True).start()
        except Exception:
            pass

if __name__ == '__main__':
    main()
EOF

chmod +x /etc/websocket/proxy.py

cat <<EOF > /etc/systemd/system/websocket_proxy.service
[Unit]
Description=Web Socket Proxy
After=network.target

[Service]
Type=simple
User=root
Environment=WS_PORT=$p_port
Environment=SSH_PORT=$s_port
ExecStart=/usr/bin/python3 /etc/websocket/proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable websocket_proxy &>/dev/null
systemctl restart websocket_proxy &>/dev/null

ui_section "[+] WebSocket Montado."
sleep 2
