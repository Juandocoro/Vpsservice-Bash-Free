#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                 WEBSOCKET PROXY                 "
echo "================================================="

read -p "¿Instalar Proxy Websocket? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then
    exit 0
fi

read -p "¿Puerto Local SSH o Dropbear? (Defecto: 22): " s_port
if [ -z "$s_port" ]; then
    s_port=22
fi

read -p "¿Puerto Público Web? (Defecto: 80): " p_port
if [ -z "$p_port" ]; then
    p_port=80
fi

echo "[*] Instalando scripts..."

mkdir -p /etc/websocket
cat << 'EOF' > /etc/websocket/proxy.py
#!/usr/bin/python3
import socket, threading, sys, os

LISTEN_PORT = int(os.environ.get('WS_PORT', 80))
SSH_PORT = int(os.environ.get('SSH_PORT', 22))

def handle_client(client_socket):
    try:
        req = client_socket.recv(8192)
        res = "HTTP/1.1 101 Switching Protocols\r\n" \
              "Upgrade: websocket\r\n" \
              "Connection: Upgrade\r\n\r\n"
        client_socket.sendall(res.encode('utf-8'))

        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.connect(('127.0.0.1', SSH_PORT))

        def forward(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data: break
                    dst.sendall(data)
            except: pass

        threading.Thread(target=forward, args=(client_socket, ssh_socket)).start()
        threading.Thread(target=forward, args=(ssh_socket, client_socket)).start()
    except Exception as e:
        client_socket.close()

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(100)
    print(f"[*] Escuchando en {LISTEN_PORT} -> Redireccionando a {SSH_PORT}")
    while True:
        client_socket, addr = server.accept()
        threading.Thread(target=handle_client, args=(client_socket,)).start()

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

echo "================================================="
echo "[+] WebSocket Montado."
echo "================================================="
sleep 2
