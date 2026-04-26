#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

# ─── Colores ──────────────────────────────────────────────────────────────────
CR="\033[0m"; GR="\033[1;32m"; RD="\033[0;31m"
YL="\033[0;33m"; CY="\033[1;36m"; WH="\033[1;37m"; DM="\033[2;37m"
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

_ok()   { echo -e "  ${GR}[+]${CR} $1"; }
_info() { echo -e "  ${YL}[*]${CR} $1"; }
_err()  { echo -e "  ${RD}[-]${CR} $1"; }

CONFIG_FILE="/usr/local/etc/v2ray/config.json"
USERS_FILE="/etc/v2ray-users.conf"

# ─── Generar link VMess base64 ────────────────────────────────────────────────
# Formato estandar VMess compatible con clientes V2Ray
# REGLAS:
#   "add"  = IP real del servidor
#   "host" = dominio bug/SNI si se usa, o IP si WS lo necesita como Host header
#   "tls"  = "" (vacío = sin TLS) | "tls" (con TLS)
#   "scy"  = "none" (recomendado sin TLS) | "aes-128-gcm" | "chacha20-poly1305"
#   "type" = "none" (sin header obfuscation HTTP)
generate_vmess_link() {
    local uuid="$1"
    local host_ip="$2"   # IP real del servidor
    local port="$3"
    local path="$4"
    local remark="${5:-VPSService-FREE}"
    local bug_host="${6:-}"  # dominio SNI/Bug host (opcional, vacío si no hay)
    local use_tls="${7:-}"   # "tls" si hay TLS, vacío si no

    # Si no hay bug_host, usar la IP como host header del WebSocket
    local ws_host="$host_ip"
    [ -n "$bug_host" ] && ws_host="$bug_host"

    # Seguridad: sin TLS usar "none", con TLS usar "aes-128-gcm"
    local security="none"
    [ "$use_tls" = "tls" ] && security="aes-128-gcm"

    local json="{\"v\":\"2\",\"ps\":\"${remark}\",\"add\":\"${host_ip}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"${security}\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ws_host}\",\"path\":\"${path}\",\"tls\":\"${use_tls}\",\"sni\":\"${bug_host}\",\"alpn\":\"\",\"fp\":\"\"}"

    local b64
    b64=$(echo -n "$json" | base64 -w 0)
    echo "vmess://${b64}"
}

# ─── Leer clientes actuales del config.json ───────────────────────────────────
get_current_clients_json() {
    if [ -f "$CONFIG_FILE" ]; then
        python3 -c "
import json, sys
try:
    c = json.load(open('$CONFIG_FILE'))
    clients = c['inbounds'][0]['settings']['clients']
    print(json.dumps(clients))
except:
    print('[]')
" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# ─── Reconstruir config.json con lista de clientes actualizada ────────────────
write_config() {
    local port="$1"
    local path="$2"
    local clients_json="$3"

    mkdir -p /usr/local/etc/v2ray
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"loglevel": "none"},
  "inbounds": [
    {
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": ${clients_json}
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "${path}"}
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}}
  ]
}
EOF
}

# ─── MENÚ PRINCIPAL V2RAY ─────────────────────────────────────────────────────
while true; do
    clear
    echo -e "$SEP"
    echo -e "${WH}         V2Ray — VMess over WebSocket           ${CR}"
    echo -e "$SEP"

    # Estado actual
    if systemctl is-active --quiet v2ray 2>/dev/null; then
        V2_STATUS="${GR}[ ACTIVO ]${CR}"
        V2_PORT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['port'])" 2>/dev/null || echo "?")
        V2_PATH=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['wsSettings']['path'])" 2>/dev/null || echo "/v2ray")
    else
        V2_STATUS="${RD}[ INACTIVO ]${CR}"
        V2_PORT="—"
        V2_PATH="—"
    fi

    echo -e "  ${DM}Estado :${CR} $V2_STATUS"
    echo -e "  ${DM}Puerto :${CR} ${CY}$V2_PORT${CR}"
    echo -e "  ${DM}Path   :${CR} ${CY}$V2_PATH${CR}"
    echo ""
    echo -e "  ${CY}1)${CR} ${WH}Instalar / Reinstalar V2Ray${CR}"
    echo -e "  ${CY}2)${CR} ${WH}Agregar Usuario (generar VMess link)${CR}"
    echo -e "  ${CY}3)${CR} ${WH}Ver Usuarios y Links de Conexión${CR}"
    echo -e "  ${CY}4)${CR} ${WH}Eliminar Usuario${CR}"
    echo -e "  ${CY}0)${CR} ${WH}Volver${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Elige [0-4]: $(echo -e ${CR})" op

    case $op in

    # ─── INSTALAR ─────────────────────────────────────────────────────────────
    1)
        clear
        echo -e "$SEP"
        echo -e "${WH}          INSTALAR / REINSTALAR V2RAY           ${CR}"
        echo -e "$SEP"

        read -p "$(echo -e ${DM})Puerto WebSocket (Defecto: 8080): $(echo -e ${CR})" v2_port
        [ -z "$v2_port" ] && v2_port=8080
        if ! [[  "$v2_port" =~ ^[0-9]+$ ]] || [ "$v2_port" -lt 1 ] || [ "$v2_port" -gt 65535 ]; then
            _err "Puerto inválido. Usando 8080."; v2_port=8080
        fi

        read -p "$(echo -e ${DM})Path WebSocket (Defecto: /v2ray): $(echo -e ${CR})" v2_path
        [ -z "$v2_path" ] && v2_path="/v2ray"
        [[ "$v2_path" != /* ]] && v2_path="/$v2_path"

        echo ""
        echo -e "  ${DM}Bug Host / SNI es el dominio de camouflage del tunel${CR}"
        echo -e "  ${DM}para enmascarar la conexión. Si no usas uno, deja vacío.${CR}"
        read -p "$(echo -e ${DM})Bug Host / SNI (Enter para omitir): $(echo -e ${CR})" v2_bughost
        echo ""

        _info "Instalando V2Ray..."
        bash <(curl -sL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) &>/dev/null

        if [ ! -f "/usr/local/bin/v2ray" ]; then
            _err "Error al instalar V2Ray. Verifica conexión."; sleep 3; continue
        fi

        # Crear config con un usuario inicial
        FIRST_UUID=$(cat /proc/sys/kernel/random/uuid)
        FIRST_NAME="user1"
        CLIENTS_JSON="[{\"id\":\"$FIRST_UUID\",\"alterId\":0,\"email\":\"$FIRST_NAME\"}]"

        write_config "$v2_port" "$v2_path" "$CLIENTS_JSON"

        # Guardar usuario y bughost en archivo de referencia
        echo "$FIRST_NAME:$FIRST_UUID" > "$USERS_FILE"
        [ -n "$v2_bughost" ] && echo "BUGHOST=$v2_bughost" >> "$USERS_FILE"

        systemctl enable v2ray &>/dev/null
        systemctl restart v2ray
        sleep 2

        # Firewall
        if command -v ufw &>/dev/null; then
            ufw allow "${v2_port}/tcp" &>/dev/null
        fi

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        VMESS_LINK=$(generate_vmess_link "$FIRST_UUID" "$SERVER_IP" "$v2_port" "$v2_path" "$FIRST_NAME" "$v2_bughost" "")

        echo ""
        if systemctl is-active --quiet v2ray; then
            _ok "V2Ray instalado y activo."
        else
            _err "V2Ray no arrancó. Revisa: journalctl -u v2ray -n 20"
        fi

        echo ""
        echo -e "$SEP"
        echo -e "${WH}    USUARIO INICIAL CREADO — $FIRST_NAME             ${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}IP / Servidor :${CR}  ${GR}$SERVER_IP${CR}"
        echo -e "  ${DM}Puerto        :${CR}  ${CY}$v2_port${CR}"
        echo -e "  ${DM}UUID          :${CR}  ${CY}$FIRST_UUID${CR}"
        echo -e "  ${DM}AlterID       :${CR}  ${CY}0${CR}"
        echo -e "  ${DM}Red / Network :${CR}  ${CY}WebSocket (ws)${CR}"
        echo -e "  ${DM}Path          :${CR}  ${CY}$v2_path${CR}"
        echo -e "  ${DM}Seguridad     :${CR}  ${CY}none (sin TLS)${CR}"
        [ -n "$v2_bughost" ] && echo -e "  ${DM}Bug Host/SNI  :${CR}  ${CY}$v2_bughost${CR}"
        echo ""
        echo -e "  ${YL}━━━ LINK VMESS ━━━${CR}"
        echo ""
        echo -e "  ${GR}$VMESS_LINK${CR}"
        echo ""
        echo -e "  ${YL}━━━ CONFIGURACION MANUAL V2RAY ━━━${CR}"
        echo -e "  ${DM}1. Crea una nueva configuracion VMess${CR}"
        echo -e "  ${DM}2. Tunnel Type → V2Ray/Xray${CR}"
        echo -e "  ${DM}3. Ajustes (⚙) → V2Ray/Xray Settings → + (agregar)${CR}"
        echo -e "  ${DM}4. Pega el link VMess de arriba (auto-rellena todo)${CR}"
        echo -e "  ${DM}   o ingresa manualmente:${CR}"
        echo -e "     ${WH}Address  :${CR} ${CY}$SERVER_IP${CR}"
        echo -e "     ${WH}Port     :${CR} ${CY}$v2_port${CR}"
        echo -e "     ${WH}UUID     :${CR} ${CY}$FIRST_UUID${CR}"
        echo -e "     ${WH}AlterID  :${CR} ${CY}0${CR}"
        echo -e "     ${WH}Network  :${CR} ${CY}WebSocket${CR}"
        echo -e "     ${WH}Path     :${CR} ${CY}$v2_path${CR}"
        echo -e "     ${WH}Security :${CR} ${CY}None${CR}"
        [ -n "$v2_bughost" ] && echo -e "     ${WH}Host/SNI :${CR} ${CY}$v2_bughost${CR}"
        echo -e "  ${DM}5. Guarda y presiona Start en la pantalla principal${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
        ;;

    # ─── AGREGAR USUARIO ──────────────────────────────────────────────────────
    2)
        clear
        echo -e "$SEP"
        echo -e "${WH}              AGREGAR USUARIO V2RAY             ${CR}"
        echo -e "$SEP"

        if [ ! -f "$CONFIG_FILE" ]; then
            _err "V2Ray no está instalado. Instálalo primero (opción 1)."; sleep 2; continue
        fi

        read -p "$(echo -e ${DM})Nombre del usuario (ej: juan): $(echo -e ${CR})" uname
        [ -z "$uname" ] && uname="user_$(date +%s)"
        uname=$(echo "$uname" | tr -d ' ')

        # Leer bug host guardado
        SAVED_BUGHOST=$(grep '^BUGHOST=' "$USERS_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$SAVED_BUGHOST" ]; then
            echo -e "  ${DM}Bug Host guardado: ${CY}$SAVED_BUGHOST${CR}"
            read -p "$(echo -e ${DM})Nuevo Bug Host (Enter para usar '$SAVED_BUGHOST'): $(echo -e ${CR})" new_bughost
            [ -z "$new_bughost" ] && new_bughost="$SAVED_BUGHOST"
        else
            read -p "$(echo -e ${DM})Bug Host / SNI (Enter para omitir): $(echo -e ${CR})" new_bughost
        fi

        NEW_UUID=$(cat /proc/sys/kernel/random/uuid)

        # Leer clientes actuales y agregar el nuevo
        CURRENT_CLIENTS=$(get_current_clients_json)
        NEW_CLIENTS=$(python3 -c "
import json
clients = json.loads('$CURRENT_CLIENTS')
clients.append({'id':'$NEW_UUID','alterId':0,'email':'$uname'})
print(json.dumps(clients, indent=2))
" 2>/dev/null)

        if [ -z "$NEW_CLIENTS" ]; then
            _err "Error procesando usuarios. ¿Está python3 instalado?"; sleep 2; continue
        fi

        # Obtener puerto y path actuales
        CURR_PORT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['port'])" 2>/dev/null || echo 8080)
        CURR_PATH=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['wsSettings']['path'])" 2>/dev/null || echo "/v2ray")

        write_config "$CURR_PORT" "$CURR_PATH" "$NEW_CLIENTS"

        # Guardar en archivo de referencia
        echo "$uname:$NEW_UUID" >> "$USERS_FILE"

        systemctl restart v2ray &>/dev/null
        sleep 1

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        VMESS_LINK=$(generate_vmess_link "$NEW_UUID" "$SERVER_IP" "$CURR_PORT" "$CURR_PATH" "$uname" "$new_bughost" "")

        echo ""
        _ok "Usuario ${CY}$uname${CR} creado correctamente."
        echo ""
        echo -e "$SEP"
        echo -e "${WH}   DATOS DE CONEXIÓN — $uname${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}IP / Servidor :${CR}  ${GR}$SERVER_IP${CR}"
        echo -e "  ${DM}Puerto        :${CR}  ${CY}$CURR_PORT${CR}"
        echo -e "  ${DM}UUID          :${CR}  ${CY}$NEW_UUID${CR}"
        echo -e "  ${DM}AlterID       :${CR}  ${CY}0${CR}"
        echo -e "  ${DM}Red / Network :${CR}  ${CY}WebSocket (ws)${CR}"
        echo -e "  ${DM}Path          :${CR}  ${CY}$CURR_PATH${CR}"
        echo -e "  ${DM}Seguridad     :${CR}  ${CY}none (sin TLS)${CR}"
        [ -n "$new_bughost" ] && echo -e "  ${DM}Bug Host/SNI  :${CR}  ${CY}$new_bughost${CR}"
        echo ""
        echo -e "  ${YL}━━━ LINK VMess — importar en tu app ━━━${CR}"
        echo ""
        echo -e "  ${GR}$VMESS_LINK${CR}"
        echo ""
        echo -e "  ${YL}━━━ CONFIGURACION MANUAL V2RAY ━━━${CR}"
        echo -e "  ${DM}1. Tunnel Type → V2Ray/Xray${CR}"
        echo -e "  ${DM}2. Ajustes (⚙) → V2Ray/Xray Settings → + → Pegar VMess link${CR}"
        echo -e "     ${WH}Address  :${CR} ${CY}$SERVER_IP${CR}"
        echo -e "     ${WH}Port     :${CR} ${CY}$CURR_PORT${CR}"
        echo -e "     ${WH}UUID     :${CR} ${CY}$NEW_UUID${CR}"
        echo -e "     ${WH}AlterID  :${CR} ${CY}0${CR}"
        echo -e "     ${WH}Network  :${CR} ${CY}WebSocket${CR}"
        echo -e "     ${WH}Path     :${CR} ${CY}$CURR_PATH${CR}"
        echo -e "     ${WH}Security :${CR} ${CY}None${CR}"
        [ -n "$new_bughost" ] && echo -e "     ${WH}Host/SNI :${CR} ${CY}$new_bughost${CR}"
        echo -e "  ${DM}Compatible con clientes estandar VMess${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
        ;;

    # ─── VER USUARIOS ─────────────────────────────────────────────────────────
    3)
        clear
        echo -e "$SEP"
        echo -e "${WH}         USUARIOS V2RAY — LINKS DE CONEXIÓN     ${CR}"
        echo -e "$SEP"

        if [ ! -f "$CONFIG_FILE" ]; then
            _err "V2Ray no está instalado."; sleep 2; continue
        fi

        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "TU_IP")
        CURR_PORT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['port'])" 2>/dev/null || echo "?")
        CURR_PATH=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['wsSettings']['path'])" 2>/dev/null || echo "/v2ray")

        echo -e "  ${DM}Servidor : ${GR}$SERVER_IP${CR}  Puerto: ${CY}$CURR_PORT${CR}  Path: ${CY}$CURR_PATH${CR}"
        echo ""

        # Leer usuarios del config.json
        python3 -c "
import json
try:
    c = json.load(open('$CONFIG_FILE'))
    clients = c['inbounds'][0]['settings']['clients']
    for i, cl in enumerate(clients, 1):
        print(f\"{i}:{cl.get('email','user'+str(i))}:{cl['id']}\")
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null | while IFS=: read -r idx uname uuid; do
            if [ "$idx" = "ERROR" ]; then
                _err "Error leyendo config: $uname"; continue
            fi
            VMESS_LINK=$(generate_vmess_link "$uuid" "$SERVER_IP" "$CURR_PORT" "$CURR_PATH" "$uname")
            echo -e "  ${CY}[$idx]${CR} ${WH}$uname${CR}"
            echo -e "      ${DM}UUID:${CR} $uuid"
            echo -e "      ${YL}LINK:${CR} ${GR}$VMESS_LINK${CR}"
            echo ""
        done

        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
        ;;

    # ─── ELIMINAR USUARIO ─────────────────────────────────────────────────────
    4)
        clear
        echo -e "$SEP"
        echo -e "${WH}              ELIMINAR USUARIO V2RAY            ${CR}"
        echo -e "$SEP"

        if [ ! -f "$CONFIG_FILE" ]; then
            _err "V2Ray no está instalado."; sleep 2; continue
        fi

        CURR_PORT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['port'])" 2>/dev/null || echo 8080)
        CURR_PATH=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['wsSettings']['path'])" 2>/dev/null || echo "/v2ray")

        echo -e "  ${DM}Usuarios actuales:${CR}"
        python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
clients = c['inbounds'][0]['settings']['clients']
for i, cl in enumerate(clients, 1):
    print(f'  {i}) {cl.get(\"email\",\"user\"+str(i))}  [{cl[\"id\"][:8]}...]')
" 2>/dev/null
        echo ""
        read -p "$(echo -e ${DM})Nombre del usuario a eliminar: $(echo -e ${CR})" del_name
        [ -z "$del_name" ] && continue

        NEW_CLIENTS=$(python3 -c "
import json, sys
c = json.load(open('$CONFIG_FILE'))
clients = c['inbounds'][0]['settings']['clients']
before = len(clients)
clients = [cl for cl in clients if cl.get('email','') != '$del_name']
after = len(clients)
if before == after:
    print('NOTFOUND')
else:
    print(json.dumps(clients, indent=2))
" 2>/dev/null)

        if [ "$NEW_CLIENTS" = "NOTFOUND" ]; then
            _err "Usuario '${del_name}' no encontrado."; sleep 2; continue
        fi
        if [ -z "$NEW_CLIENTS" ]; then
            _err "Error procesando config."; sleep 2; continue
        fi

        write_config "$CURR_PORT" "$CURR_PATH" "$NEW_CLIENTS"
        # Actualizar archivo de referencia
        [ -f "$USERS_FILE" ] && sed -i "/^${del_name}:/d" "$USERS_FILE"

        systemctl restart v2ray &>/dev/null
        sleep 1
        _ok "Usuario '${del_name}' eliminado y V2Ray reiniciado."
        sleep 2
        ;;

    0) break ;;
    *) _err "Opción inválida."; sleep 1 ;;
    esac
done
