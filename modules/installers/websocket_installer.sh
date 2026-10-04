#!/bin/bash
# Instalador WebSocket — proxy HTTP(101) -> SSH para HTTP Injector
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

UNIT=/etc/systemd/system/websocket_proxy.service

inst_header "WEBSOCKET PROXY" "HTTP Injector · payload con Upgrade: websocket"
ui_blank

act_ssh=$(grep -oE 'SSH_PORT=[0-9]+' "$UNIT" 2>/dev/null | cut -d= -f2)
act_web=$(grep -oE 'WS_PORT=[0-9]+' "$UNIT" 2>/dev/null | cut -d= -f2)

# Destino local: OpenSSH (22) es lo recomendado. Si se apunta a
# Dropbear, esos clientes no podran salir por la IP residencial.
while true; do
    ui_prompt "Puerto local SSH o Dropbear (Enter = ${act_ssh:-22} · 0 = cancelar)"
    s_port="${REPLY_UI:-${act_ssh:-22}}"
    [ "$s_port" = "0" ] && exit 0
    inst_port_valid "$s_port" && break
    ui_err "Puerto no válido."
done
inst_ask_port "Puerto público web" "${act_web:-80}" tcp python3 || exit 0
p_port="$INST_PORT"

ui_info "Instalando el proxy..."
command -v python3 &>/dev/null || inst_apt python3

mkdir -p /etc/websocket
cat << 'EOF' > /etc/websocket/proxy.py
#!/usr/bin/python3
import socket, threading, os

LISTEN_PORT = int(os.environ.get('WS_PORT', 80))
SSH_PORT    = int(os.environ.get('SSH_PORT', 22))
BUF         = 32768   # antes 4096: mas caudal por conexion con menos CPU

def forward(src, dst, stop_event):
    """Reenvia datos entre dos sockets. Cierra ambos al terminar."""
    try:
        while not stop_event.is_set():
            try:
                src.settimeout(60)
                data = src.recv(BUF)
            except socket.timeout:
                continue
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        stop_event.set()
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

def handle_client(client_socket):
    ssh_socket = None
    try:
        client_socket.settimeout(10)
        req = client_socket.recv(8192)
        if not req:
            return
        # Lo que venga detras de la cabecera HTTP en el mismo paquete
        # ya es del tunel: antes se tiraba y la conexion no arrancaba
        # con los payloads que no esperan la respuesta 101.
        # Solo si es el saludo SSH: un payload con una segunda peticion
        # HTTP ([split]) se sigue descartando, como siempre.
        resto = b''
        if b'\r\n\r\n' in req:
            resto = req.split(b'\r\n\r\n', 1)[1]
            if not resto.startswith(b'SSH-'):
                resto = b''
        client_socket.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                              b"Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        client_socket.settimeout(None)

        ssh_socket = socket.create_connection(('127.0.0.1', SSH_PORT), timeout=10)
        ssh_socket.settimeout(None)
        if resto:
            ssh_socket.sendall(resto)

        stop_event = threading.Event()
        threading.Thread(target=forward, args=(client_socket, ssh_socket, stop_event), daemon=True).start()
        threading.Thread(target=forward, args=(ssh_socket, client_socket, stop_event), daemon=True).start()
    except Exception:
        for s in (client_socket, ssh_socket):
            if s:
                try: s.close()
                except Exception: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(512)
    print(f"[*] Escuchando en {LISTEN_PORT} -> Redireccionando a {SSH_PORT}", flush=True)
    while True:
        try:
            client_socket, addr = server.accept()
            client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=handle_client, args=(client_socket,), daemon=True).start()
        except Exception:
            pass

if __name__ == '__main__':
    main()
EOF
chmod +x /etc/websocket/proxy.py

cat > "$UNIT" <<EOF
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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable websocket_proxy &>/dev/null
systemctl restart websocket_proxy &>/dev/null
inst_ufw_allow "$p_port/tcp"
inst_mark websocket_proxy

ui_blank
ui_solid
inst_check_service websocket_proxy "WebSocket"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto web" "$p_port/TCP" 34 "$CY")"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Entrega a " "127.0.0.1:$s_port" 34 "$CY")"
[ "$s_port" != "22" ] && ui_warn "Si $s_port es Dropbear, esos clientes no podrán usar la IP residencial."
ui_solid
ui_pause
