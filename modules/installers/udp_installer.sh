#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

CR="\033[0m"; GR="\033[1;32m"; RD="\033[0;31m"
YL="\033[0;33m"; CY="\033[1;36m"; WH="\033[1;37m"; DM="\033[2;37m"
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

UDP_DIR="/root/udp"
CONFIG_FILE="$UDP_DIR/config.json"
USERS_FILE="$UDP_DIR/users.conf"
BINARY="$UDP_DIR/udp-custom"
SERVICE_FILE="/etc/systemd/system/udp-custom.service"

_ok()   { echo -e "  ${GR}[+]${CR} $1"; }
_info() { echo -e "  ${YL}[*]${CR} $1"; }
_err()  { echo -e "  ${RD}[-]${CR} $1"; }

# ─── Reconstruir config.json con usuarios actuales ────────────────────────────
write_config() {
    local port="$1"
    local excludes="$2"   # puertos a excluir ej: "53,5300"

    # Construir objeto passwords
    local pass_block=""
    if [ -f "$USERS_FILE" ]; then
        while IFS=: read -r uname upass; do
            [[ "$uname" == "#"* ]] && continue
            [ -z "$uname" ] && continue
            pass_block+=",\"$uname\":\"$upass\""
        done < "$USERS_FILE"
        # quitar coma inicial
        pass_block="${pass_block:1}"
    fi

    local excl_json="[]"
    if [ -n "$excludes" ]; then
        # Convertir "53,5300" → [53,5300]
        excl_json="[$(echo "$excludes" | tr ',' '\n' | awk '{printf "%s,", $1}' | sed 's/,$//')]"
    fi

    mkdir -p "$UDP_DIR"
    cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":${port}",
  "stream_buffer": 209715200,
  "receive_buffer": 104857600,
  "auth": {
    "mode": "passwords",
    "passwords": {${pass_block}}
  },
  "udp_ports_exclude": ${excl_json}
}
EOF
}

# ─── MENÚ PRINCIPAL ───────────────────────────────────────────────────────────
while true; do
    clear
    echo -e "$SEP"
    echo -e "${WH}             UDP CUSTOM — Túnel UDP Directo        ${CR}"
    echo -e "$SEP"
    echo -e "  ${DM}Formato de cuenta: ${WH}ip:puerto@usuario:contraseña${CR}"
    echo -e "  ${DM}Escucha en rango de puertos UDP 1-65535${CR}"
    echo ""

    # Estado
    if systemctl is-active --quiet udp-custom 2>/dev/null; then
        STATUS="${GR}[ ACTIVO ]${CR}"
        UDP_PORT=$(grep '"listen"' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*')
    else
        STATUS="${RD}[ INACTIVO ]${CR}"
        UDP_PORT="—"
    fi

    echo -e "  ${DM}Estado : ${CR}$STATUS"
    echo -e "  ${DM}Puerto : ${CR}${CY}$UDP_PORT${CR}"
    echo ""
    echo -e "  ${CY}1)${CR} ${WH}Instalar UDP Custom${CR}"
    echo -e "  ${CY}2)${CR} ${WH}Agregar Usuario${CR}"
    echo -e "  ${CY}3)${CR} ${WH}Ver Usuarios y Cuentas${CR}"
    echo -e "  ${CY}4)${CR} ${WH}Eliminar Usuario${CR}"
    echo -e "  ${CY}5)${CR} ${WH}Reiniciar Servicio${CR}"
    echo -e "  ${CY}0)${CR} ${WH}Volver${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Elige [0-5]: $(echo -e ${CR})" op

    case $op in

    # ─── INSTALAR ─────────────────────────────────────────────────────────────
    1)
        clear
        echo -e "$SEP"
        echo -e "${WH}            INSTALAR UDP CUSTOM                  ${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}UDP Custom escuchará en TODOS los puertos UDP (1-65535)${CR}"
        echo -e "  ${DM}Puerto interno del binario: ${CR}${CY}36712${CR}  ${DM}(no necesitas cambiarlo)${CR}"
        echo ""

        INTERNAL_PORT=36712

        echo -e "  ${DM}Puertos a ${WH}EXCLUIR${DM} del rango UDP (ej: BadVPN usa 7300):${CR}"
        echo -e "  ${DM}Default: ${CY}7300${DM} (BadVPN). Agrega más separados por coma.${CR}"
        read -p "$(echo -e ${DM})Puertos a excluir (Enter = solo 7300): $(echo -e ${CR})" excl_input
        [ -z "$excl_input" ] && excl_input="7300"
        # Asegurar que 7300 siempre esté excluido
        if ! echo "$excl_input" | grep -q "7300"; then
            excl_input="7300,$excl_input"
        fi
        excl_ports="$excl_input"

        # Descargar binario oficial de http-custom/udp-custom
        mkdir -p "$UDP_DIR"
        _info "Descargando binario udp-custom..."

        BIN_URLS=(
            "https://github.com/noobconner21/UDP-Custom-Script/raw/main/udp-custom-linux-amd64"
            "https://github.com/http-custom/udp-custom/raw/main/bin/udp-custom-linux-amd64"
        )

        BINARY_OK=false
        for URL in "${BIN_URLS[@]}"; do
            if wget -q --timeout=30 -O "$BINARY" "$URL" 2>/dev/null && \
               file "$BINARY" 2>/dev/null | grep -q "ELF"; then
                chmod +x "$BINARY"
                _ok "Binario descargado desde $(echo $URL | awk -F'/' '{print $4}')"
                BINARY_OK=true
                break
            fi
            rm -f "$BINARY"
        done

        if [ "$BINARY_OK" = false ]; then
            _err "No se pudo descargar el binario UDP Custom."
            _info "Intentando desde git clone..."
            if git clone https://github.com/http-custom/udp-custom /tmp/udp-custom-src &>/dev/null; then
                cp /tmp/udp-custom-src/bin/udp-custom-linux-amd64 "$BINARY" 2>/dev/null || true
                chmod +x "$BINARY" 2>/dev/null
                rm -rf /tmp/udp-custom-src
                if file "$BINARY" 2>/dev/null | grep -q "ELF"; then
                    _ok "Binario instalado desde git clone."
                    BINARY_OK=true
                fi
            fi
        fi

        if [ "$BINARY_OK" = false ]; then
            _err "No se pudo obtener el binario. Verifica conexión."
            sleep 4; continue
        fi

        # Crear primer usuario
        echo ""
        read -p "$(echo -e ${DM})Usuario inicial (Defecto: admin): $(echo -e ${CR})" first_user
        [ -z "$first_user" ] && first_user="admin"
        first_user=$(echo "$first_user" | tr -d ' ')
        read -p "$(echo -e ${DM})Contraseña: $(echo -e ${CR})" first_pass
        [ -z "$first_pass" ] && first_pass=$(cat /proc/sys/kernel/random/uuid | cut -c1-10)

        echo "${first_user}:${first_pass}" > "$USERS_FILE"
        write_config "$INTERNAL_PORT" "$excl_ports"

        # Servicio systemd
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=UDP Custom Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$UDP_DIR
ExecStart=$BINARY
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable udp-custom &>/dev/null
        systemctl stop udp-custom &>/dev/null; sleep 1
        systemctl start udp-custom; sleep 2

        # ── iptables: redirigir TODOS los puertos UDP → puerto interno ──────────
        _info "Configurando iptables (rango total UDP 1-65535)..."

        # Limpiar reglas anteriores de UDP Custom
        iptables -t nat -D PREROUTING -p udp -j REDIRECT --to-port "$INTERNAL_PORT" 2>/dev/null || true

        # Agregar regla base: todo UDP → INTERNAL_PORT
        iptables -t nat -A PREROUTING -p udp -j REDIRECT --to-port "$INTERNAL_PORT"

        # Excluir puertos específicos (insertar ANTES con mayor prioridad)
        IFS=',' read -ra EXCL_LIST <<< "$excl_ports"
        for eport in "${EXCL_LIST[@]}"; do
            eport=$(echo "$eport" | tr -d ' ')
            [ -z "$eport" ] && continue
            # Regla de excepción: este puerto NO se redirige → se inserta al inicio
            iptables -t nat -I PREROUTING 1 -p udp --dport "$eport" -j RETURN
            _ok "Puerto $eport excluido de UDP Custom."
        done

        # Guardar reglas iptables para que persistan tras reboot
        mkdir -p /etc/iptables 2>/dev/null
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            _ok "Reglas iptables guardadas en /etc/iptables/rules.v4"
        fi
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save &>/dev/null
        fi

        # Firewall: abrir el puerto interno
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${INTERNAL_PORT}/udp" &>/dev/null
            _ok "Firewall: puerto interno $INTERNAL_PORT abierto."
        fi

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        # CORRECCIÓN: UDP Custom usa puerto TCP interno internamente, pero escucha TODOS los UDP
        # por lo que el cliente debe usar:
        # Formato: servidor_ip:puerto_udp@usuario:pass
        # Donde puerto_udp puede ser cualquiera en el rango 1-65535 (excepto exclusiones)
        
        echo ""
        if systemctl is-active --quiet udp-custom; then
            _ok "UDP Custom activo — escuchando en ${CY}TODOS los puertos UDP${CR}"
            _ok "Puertos excluidos: ${CY}$excl_ports${CR}"
        else
            _err "UDP Custom no arrancó."
            journalctl -u udp-custom -n 10 --no-pager 2>/dev/null | sed 's/^/  /'
            sleep 3; continue
        fi

        echo ""
        echo -e "$SEP"
        echo -e "${WH}     CUENTA UDP CUSTOM — $first_user              ${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}Servidor  :${CR}  ${GR}$SERVER_IP${CR}"
        echo -e "  ${DM}Puerto    :${CR}  ${CY}cualquier puerto UDP${CR}  ${DM}(1-65535, excepto: $excl_ports)${CR}"
        echo -e "  ${DM}Usuario   :${CR}  ${CY}$first_user${CR}"
        echo -e "  ${DM}Contraseña:${CR}  ${CY}$first_pass${CR}"
        echo ""
        echo -e "  ${YL}━━━ DATOS DE CONEXION ━━━${CR}"
        echo ""
        echo -e "  ${GR}${SERVER_IP}:xxxx@${first_user}:${first_pass}${CR}  ${DM}(xxxx = cualquier puerto UDP)${CR}"
        echo ""
        echo -e "  ${YL}━━━ CONFIGURACION UDP CUSTOM ━━━${CR}"
        echo -e "  ${DM}1. Activa el modo UDP en el cliente${CR}"
        echo -e "  ${DM}2. Activa la casilla ${WH}☑ UDP Custom${DM} en pantalla principal${CR}"
        echo -e "  ${DM}3. En el campo de cuenta escribe uno de estos formatos:${CR}"
        echo -e "     ${WH}${SERVER_IP}:53@${first_user}:${first_pass}${CR}  ${DM}(puerto 53)${CR}"
        echo -e "     ${WH}${SERVER_IP}:123@${first_user}:${first_pass}${CR}  ${DM}(puerto 123)${CR}"
        echo -e "     ${WH}${SERVER_IP}:8080@${first_user}:${first_pass}${CR}  ${DM}(puerto 8080)${CR}"
        echo -e "  ${DM}4. Presiona Connect — NO necesitas SSH${CR}"
        echo -e "$SEP"
        [ "$WEB_PANEL" = "1" ] && exit 0
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
        ;;

    # ─── AGREGAR USUARIO ──────────────────────────────────────────────────────
    2)
        clear
        echo -e "$SEP"
        echo -e "${WH}           AGREGAR USUARIO UDP CUSTOM             ${CR}"
        echo -e "$SEP"

        if [ ! -f "$CONFIG_FILE" ]; then
            _err "UDP Custom no instalado. Usa opción 1 primero."; sleep 2; continue
        fi

        UDP_PORT=$(grep '"listen"' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*')

        read -p "$(echo -e ${DM})Nombre de usuario: $(echo -e ${CR})" new_user
        [ -z "$new_user" ] && new_user="user$(date +%s | tail -c4)"
        new_user=$(echo "$new_user" | tr -d ' ')

        if grep -q "^${new_user}:" "$USERS_FILE" 2>/dev/null; then
            _err "El usuario '$new_user' ya existe."; sleep 2; continue
        fi

        read -p "$(echo -e ${DM})Contraseña (Enter para generar): $(echo -e ${CR})" new_pass
        [ -z "$new_pass" ] && new_pass=$(cat /proc/sys/kernel/random/uuid | cut -c1-10)

        echo "${new_user}:${new_pass}" >> "$USERS_FILE"

        EXCL=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(','.join(map(str,c.get('udp_ports_exclude',[]))))" 2>/dev/null || echo "")
        write_config "$UDP_PORT" "$EXCL"
        systemctl restart udp-custom &>/dev/null; sleep 1

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        CUENTA="${SERVER_IP}:${UDP_PORT}@${new_user}:${new_pass}"

        echo ""
        _ok "Usuario ${CY}$new_user${CR} creado."
        echo ""
        echo -e "$SEP"
        echo -e "${WH}     CUENTA UDP CUSTOM — $new_user               ${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}Cuenta completa:${CR}"
        echo ""
        echo -e "  ${GR}$CUENTA${CR}"
        echo ""
        echo -e "  ${DM}Ingresa estos datos en el cliente UDP${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
        ;;

    # ─── VER USUARIOS ─────────────────────────────────────────────────────────
    3)
        clear
        echo -e "$SEP"
        echo -e "${WH}         CUENTAS UDP CUSTOM                      ${CR}"
        echo -e "$SEP"

        if [ ! -f "$USERS_FILE" ]; then
            _err "No hay usuarios."; sleep 2; continue
        fi

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        UDP_PORT=$(grep '"listen"' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*')

        echo -e "  ${DM}Servidor: ${GR}$SERVER_IP${CR}  Puerto: ${CY}$UDP_PORT${CR}"
        echo ""
        echo -e "  ${YL}Formato: ip:puerto@usuario:contraseña${CR}"
        echo ""

        i=1
        while IFS=: read -r uname upass; do
            [[ "$uname" == "#"* ]] && continue
            [ -z "$uname" ] && continue
            CUENTA="${SERVER_IP}:${UDP_PORT}@${uname}:${upass}"
            echo -e "  ${CY}[$i]${CR} ${WH}$uname${CR}"
            echo -e "      ${GR}$CUENTA${CR}"
            echo ""
            ((i++))
        done < "$USERS_FILE"

        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
        ;;

    # ─── ELIMINAR USUARIO ─────────────────────────────────────────────────────
    4)
        clear
        echo -e "$SEP"
        echo -e "${WH}          ELIMINAR USUARIO UDP CUSTOM             ${CR}"
        echo -e "$SEP"

        if [ ! -f "$USERS_FILE" ]; then
            _err "No hay usuarios."; sleep 2; continue
        fi

        i=1
        while IFS=: read -r uname _; do
            [ -z "$uname" ] && continue
            echo -e "    ${CY}$i)${CR} $uname"; ((i++))
        done < "$USERS_FILE"
        echo ""

        read -p "$(echo -e ${DM})Usuario a eliminar: $(echo -e ${CR})" del_user
        [ -z "$del_user" ] && continue

        if grep -q "^${del_user}:" "$USERS_FILE" 2>/dev/null; then
            sed -i "/^${del_user}:/d" "$USERS_FILE"
            UDP_PORT=$(grep '"listen"' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*')
            EXCL=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(','.join(map(str,c.get('udp_ports_exclude',[]))))" 2>/dev/null || echo "")
            write_config "$UDP_PORT" "$EXCL"
            systemctl restart udp-custom &>/dev/null
            _ok "Usuario '${del_user}' eliminado."
        else
            _err "Usuario no encontrado."
        fi
        sleep 2
        ;;

    # ─── REINICIAR ────────────────────────────────────────────────────────────
    5)
        systemctl restart udp-custom
        sleep 1
        if systemctl is-active --quiet udp-custom; then
            _ok "UDP Custom reiniciado correctamente."
        else
            _err "No pudo reiniciar. Revisa: journalctl -u udp-custom -n 20"
        fi
        sleep 2
        ;;

    0) break ;;
    *) _err "Opción inválida."; sleep 1 ;;
    esac
done
