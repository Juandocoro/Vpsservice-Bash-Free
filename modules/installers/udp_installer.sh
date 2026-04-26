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
    echo -e "${WH}      UDP CUSTOM — Protocolo para HTTP Custom      ${CR}"
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

        read -p "$(echo -e ${DM})Puerto UDP (Defecto: 7300): $(echo -e ${CR})" udp_port
        [ -z "$udp_port" ] && udp_port=7300
        [[ ! "$udp_port" =~ ^[0-9]+$ ]] && udp_port=7300

        echo ""
        echo -e "  ${DM}Si tienes otros servicios UDP en ciertos puertos (ej: BadVPN${CR}"
        echo -e "  ${DM}en 7300, OpenVPN en 1194), puedes excluirlos.${CR}"
        read -p "$(echo -e ${DM})Puertos a excluir separados por coma (Enter = ninguno): $(echo -e ${CR})" excl_ports

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
            _info "Intentando instalar desde repositorio oficial..."
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
            _err "No se pudo obtener el binario. Verifica conexión y prueba manualmente:"
            echo -e "  ${DM}git clone https://github.com/http-custom/udp-custom${CR}"
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
        write_config "$udp_port" "$excl_ports"

        # Crear servicio systemd
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=UDP Custom Server (HTTP Custom App)
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

        # Firewall
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${udp_port}/udp" &>/dev/null
            ufw allow "${udp_port}/tcp" &>/dev/null
            _ok "Firewall: puerto $udp_port abierto."
        fi

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        CUENTA="${SERVER_IP}:${udp_port}@${first_user}:${first_pass}"

        echo ""
        if systemctl is-active --quiet udp-custom; then
            _ok "UDP Custom activo en puerto ${CY}$udp_port${CR}"
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
        echo -e "  ${DM}Puerto    :${CR}  ${CY}$udp_port${CR}"
        echo -e "  ${DM}Usuario   :${CR}  ${CY}$first_user${CR}"
        echo -e "  ${DM}Contraseña:${CR}  ${CY}$first_pass${CR}"
        echo ""
        echo -e "  ${YL}━━━ CUENTA — Pegar en HTTP Custom ━━━${CR}"
        echo ""
        echo -e "  ${GR}$CUENTA${CR}"
        echo ""
        echo -e "  ${YL}━━━ CÓMO USAR EN HTTP CUSTOM ━━━${CR}"
        echo -e "  ${DM}1. Abre HTTP Custom${CR}"
        echo -e "  ${DM}2. Activa la casilla ${WH}☑ UDP Custom${DM} en pantalla principal${CR}"
        echo -e "  ${DM}3. En el campo de cuenta escribe:${CR}"
        echo -e "     ${WH}$SERVER_IP:$udp_port@$first_user:$first_pass${CR}"
        echo -e "  ${DM}4. Presiona Connect — NO necesitas SSH${CR}"
        echo -e "$SEP"
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
        echo -e "  ${DM}Pega esto en HTTP Custom → campo UDP Custom${CR}"
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
