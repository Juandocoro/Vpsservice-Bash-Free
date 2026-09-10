#!/bin/bash

# =========================================================
# RUTAS ABSOLUTAS GLOBALES
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"
# =========================================================

# Lenguaje visual compartido — paleta, marcos, celdas y etiquetas
source "$DIR/modules/ui.sh"

# Referencias Modulares
source "$DIR/modules/network.sh"
source "$DIR/modules/users.sh"
source "$DIR/modules/optimize.sh"
source "$DIR/modules/installers/wg_home.sh"

VPS_VERSION="v1.0"

# Estado persistente del panel. Antes se usaba /tmp, que el sistema vacia en
# cada reinicio: el firewall se reseteaba solo y borraba reglas del admin.
STATE_DIR="/var/lib/vpsservice"
mkdir -p "$STATE_DIR" 2>/dev/null

# =========================================================
# CABECERA GENERAL
# =========================================================
function print_title() {
    local VER="$VPS_VERSION"
    if git -C "$DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local COMMIT
        COMMIT=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
        [ -n "$COMMIT" ] && VER="FREE · ${VPS_VERSION} · ${COMMIT}"
    fi
    [ "$VER" = "$VPS_VERSION" ] && VER="FREE · ${VPS_VERSION}"
    echo ""
    ui_header "$VER"
}

# =========================================================
# ARRANQUE AUTOMÁTICO
# =========================================================
function toggle_autostart() {
    clear
    print_title
    ui_section "ARRANQUE AUTOMÁTICO" "abrir el panel al entrar por SSH"
    ui_blank
    if grep -q "^menu$" /root/.bashrc 2>/dev/null; then
        echo -e "${UI_PAD}Estado actual:  $(ui_tag_str on)"
        ui_blank
        ui_prompt "¿Desactivar? (s/n)"
        if [[ "$REPLY_UI" == "s" || "$REPLY_UI" == "S" ]]; then
            sed -i '/^menu$/d' /root/.bashrc
            ui_ok "Arranque automático desactivado."
        fi
    else
        echo -e "${UI_PAD}Estado actual:  $(ui_tag_str off)"
        ui_blank
        ui_prompt "¿Activar? (s/n)"
        if [[ "$REPLY_UI" == "s" || "$REPLY_UI" == "S" ]]; then
            echo "menu" >> /root/.bashrc
            ui_ok "Arranque automático activado."
        fi
    fi
    sleep 2
}

# =========================================================
# MENÚ USUARIOS
# =========================================================
function users_menu() {
    while true; do
        clear
        print_title
        ui_section "GESTIÓN DE CUENTAS" "SSH · SSL · Dropbear"
        ui_blank

        contar_cuentas
        echo -e "${UI_PAD}$(ui_cell "Total" "${USR_TOTAL:-0}" 16)${DM}▸${CR} $(ui_cell "Activas" "${USR_ACTIVAS:-0}" 16 "$GR")${DM}▸${CR} $(ui_cell "Vencidas" "${USR_VENCIDAS:-0}" 16 "$RD")"
        ui_rule
        ui_blank

        ui_opt "1" "CREAR CUENTA"        "usuario nuevo"
        ui_opt "2" "ADMINISTRAR CUENTAS" "editar · borrar"
        ui_opt "3" "USUARIOS CONECTADOS" "monitor en vivo"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-3]"

        case "$REPLY_UI" in
            1) crear_usuario ;;
            2) administrar_usuarios ;;
            3) monitor_conexiones ;;
            0) break ;;
            *) ui_err "Opción inválida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# ACTUALIZAR
# =========================================================
function update_script() {
    clear
    print_title
    ui_section "ACTUALIZAR PANEL" "descarga la última versión desde GitHub"
    ui_blank
    ui_info "Buscando nuevas versiones..."
    ui_blank

    git fetch origin main &>/dev/null
    LOCAL=$(git rev-parse --short HEAD 2>/dev/null)
    REMOTE=$(git rev-parse --short FETCH_HEAD 2>/dev/null)
    [ -z "$LOCAL" ]  && LOCAL="Desconocida"
    [ -z "$REMOTE" ] && REMOTE="Desconocida"

    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Versión instalada" "$LOCAL" 34)"
    echo -e "${UI_PAD}${CY}▪${CR} $(ui_cell "Versión en la nube" "$REMOTE" 34 "$CY")"
    ui_blank

    if [ "$LOCAL" == "$REMOTE" ]; then
        ui_ok "Ya tienes la última versión instalada."
        ui_solid
        ui_pause
    else
        ui_warn "Nueva actualización disponible."
        ui_info "Descargando y reparando permisos..."
        git reset --hard FETCH_HEAD &>/dev/null
        chmod -R +x "$DIR" 2>/dev/null
        ui_ok "Actualizado correctamente. Reiniciando el panel..."
        sleep 2
        exec "$DIR/main.sh"
    fi
}

# =========================================================
# DATOS DE CONEXIÓN PARA CLIENTES
# =========================================================
function client_data() {
    refresh_ports
    clear
    print_title
    ui_section "DATOS DE CONEXIÓN" "para configurar la app del cliente"

    SERVER_IP=$(_public_ip)
    SSH_PORT="${PORT_SSH:-22}"

    ui_blank
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 30 "$GR")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto SSH" "$SSH_PORT" 30 "$CY")"
    ui_blank

    # ── HTTP INJECTOR — WebSocket ───────────────────────────────────────────
    if [ -n "$PORT_WS" ]; then
        ui_rule
        echo -e "${UI_PAD}${WH}${BD}HTTP INJECTOR — WebSocket${CR} ${DM}(método principal)${CR}"
        ui_rule
        echo -e "${UI_PAD}$(ui_cell "Remote Proxy" "$SERVER_IP:$PORT_WS" 34 "$WH")${DM}tipo: HTTP${CR}"
        ui_blank
        echo -e "${UI_PAD}${CY}Payload — pegar exacto en la app:${CR}"
        echo -e "${UI_PAD}  ${WH}GET / HTTP/1.1[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}Host: $SERVER_IP[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}Upgrade: websocket[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}Connection: Upgrade[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}[crlf]${CR}"
        ui_blank
        echo -e "${UI_PAD}${DM}Pasos: SSH Host → $SERVER_IP  ·  SSH Port → $SSH_PORT${CR}"
        echo -e "${UI_PAD}${DM}       Proxy Type → Websocket  ·  Server → $SERVER_IP:$PORT_WS${CR}"
        ui_blank
    fi

    # ── HTTP INJECTOR — SSL/Stunnel ─────────────────────────────────────────
    if [ -n "$PORT_SSL" ]; then
        ui_rule
        echo -e "${UI_PAD}${WH}${BD}HTTP INJECTOR — SSL / Stunnel${CR} ${DM}(HTTPS)${CR}"
        ui_rule
        echo -e "${UI_PAD}$(ui_cell "Remote Proxy" "$SERVER_IP:$PORT_SSL" 34 "$WH")${DM}tipo: SSL${CR}"
        echo -e "${UI_PAD}${DM}SSL/TLS: ACTIVADO — certificado autofirmado, ignorar la advertencia${CR}"
        ui_blank
        echo -e "${UI_PAD}${CY}Payload para SSL Injector:${CR}"
        # El payload sigue al puerto SSH real; antes estaba fijo en 22 y fallaba
        # en cualquier servidor con SSH en otro puerto.
        echo -e "${UI_PAD}  ${WH}CONNECT $SERVER_IP:$SSH_PORT HTTP/1.0[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}Host: $SERVER_IP[crlf]${CR}"
        echo -e "${UI_PAD}  ${WH}[crlf]${CR}"
        ui_blank
    fi

    # ── Puertos ─────────────────────────────────────────────────────────────
    ui_rule
    echo -e "${UI_PAD}${YL}PUERTOS SSH${CR}"
    ui_rule
    [ -n "$PORT_SSH" ]      && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "OpenSSH " "$PORT_SSH" 24 "$CY")${DM}TCP${CR}"
    [ -n "$PORT_DROPBEAR" ] && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Dropbear" "$PORT_DROPBEAR" 24 "$CY")${DM}TCP${CR}"
    ui_blank

    ui_rule
    echo -e "${UI_PAD}${YL}OTROS PROTOCOLOS${CR}"
    ui_rule
    [ -n "$PORT_UDPCUSTOM" ] && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "UDP Custom " "$PORT_UDPCUSTOM" 26 "$CY")${DM}túnel UDP directo${CR}"
    [ -n "$PORT_BADVPN" ]    && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "BadVPN     " "127.0.0.1:$PORT_BADVPN" 26 "$CY")${DM}juegos/llamadas vía SSH${CR}"
    [ -n "$PORT_SLOWDNS" ]   && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "SlowDNS    " "$PORT_SLOWDNS" 26 "$CY")"
    [ -n "$PORT_SQUID" ]     && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Squid      " "$PORT_SQUID" 26 "$CY")"
    [ -n "$PORT_V2RAY" ]     && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "V2Ray VMess" "$PORT_V2RAY" 26 "$CY")${DM}path: /v2ray${CR}"
    [ -n "$PORT_SS" ]        && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Shadowsocks" "$PORT_SS" 26 "$CY")${DM}aes-256-gcm${CR}"
    [ -n "$PORT_OVPN" ]      && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "OpenVPN    " "$PORT_OVPN" 26 "$CY")${DM}UDP${CR}"
    [ -n "$PORT_WG" ]        && echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "WireGuard  " "$PORT_WG" 26 "$CY")${DM}UDP${CR}"
    ui_blank

    if [ -n "$PORT_BADVPN" ]; then
        ui_rule
        echo -e "${UI_PAD}${YL}BADVPN — Gateway UDP${CR}"
        ui_rule
        echo -e "${UI_PAD}${DM}1. Conecta primero por SSH (puerto ${CY}$SSH_PORT${DM})${CR}"
        echo -e "${UI_PAD}${DM}2. Settings → UDP Custom → Enable${CR}"
        echo -e "${UI_PAD}${DM}3. Host: ${WH}127.0.0.1${DM}   Port: ${CY}$PORT_BADVPN${CR}"
        ui_blank
    fi

    ui_solid
    ui_pause
}

# =========================================================
# FÁBRICA DE TÚNELES & PROXIES
# =========================================================
function sub_menu_installers() {
    while true; do
        refresh_ports
        clear
        print_title
        ui_section "FÁBRICA DE TÚNELES & PROXIES" "11 protocolos disponibles"
        ui_blank

        echo -e "${UI_PAD}${YL}── SSH / TÚNEL ──${CR}"
        ui_opt "1"  "STUNNEL SSL"  "SSH sobre TLS"     "$(ui_tag "$PORT_SSL")"
        ui_opt "2"  "UDP CUSTOM"   "túnel UDP directo" "$(ui_tag "$PORT_UDPCUSTOM")"
        ui_opt "3"  "BADVPN"       "juegos + llamadas" "$(ui_tag "$PORT_BADVPN")"
        ui_opt "4"  "WEBSOCKET"    "HTTP Injector"     "$(ui_tag "$PORT_WS")"
        ui_opt "5"  "DROPBEAR"     "SSH ligero"        "$(ui_tag "$PORT_DROPBEAR")"
        ui_blank
        echo -e "${UI_PAD}${YL}── PROXY ──${CR}"
        ui_opt "6"  "SLOWDNS"      "túnel por DNS"     "$(ui_tag "$PORT_SLOWDNS")"
        ui_opt "7"  "SQUID PROXY"  "proxy HTTP"        "$(ui_tag "$PORT_SQUID")"
        ui_blank
        echo -e "${UI_PAD}${YL}── VPN ──${CR}"
        ui_opt "8"  "V2RAY"        "VMess + WS"        "$(ui_tag "$PORT_V2RAY")"
        ui_opt "9"  "SHADOWSOCKS"  "aes-256-gcm"       "$(ui_tag "$PORT_SS")"
        ui_opt "10" "OPENVPN"      "perfil .ovpn"      "$(ui_tag "$PORT_OVPN")"
        ui_opt "11" "WIREGUARD"    "ChaCha20 / UDP"    "$(ui_tag "$PORT_WG")"
        ui_blank
        ui_opt "C"  "DATOS DE CONEXIÓN" "para el cliente"
        ui_opt "0"  "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-11 | C]"
        local op="$REPLY_UI"

        _run() {
            if [ -x "$DIR/modules/installers/$1" ]; then
                sudo "$DIR/modules/installers/$1"
            else
                ui_err "Instalador no encontrado: $1"
            fi
            sleep 1
        }

        case "$op" in
            1)  _run "stunnel_installer.sh" ;;
            2)  _run "udp_installer.sh" ;;
            3)  _run "badvpn_installer.sh" ;;
            4)  _run "websocket_installer.sh" ;;
            5)  _run "dropbear_installer.sh" ;;
            6)  _run "slowdns_installer.sh" ;;
            7)  _run "squid_installer.sh" ;;
            8)  _run "v2ray_installer.sh" ;;
            9)  _run "shadowsocks_installer.sh" ;;
            10) _run "openvpn_installer.sh" ;;
            11) _run "wireguard_installer.sh" ;;
            [Cc]) client_data ;;
            0) break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# DESINSTALAR PANEL
# =========================================================
function uninstall_panel() {
    clear
    print_title
    ui_section "⚠  DESINSTALAR PANEL  ⚠" "esta acción no se puede deshacer"
    ui_blank
    ui_warn "Se eliminará permanentemente:"
    ui_blank
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Directorio /opt/vpsservice-free${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Comando global 'menu' (/usr/local/bin/menu)${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Cron del auto-killer y de la optimización${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Entrada de arranque automático en .bashrc${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Servicios activos (stunnel, badvpn, udp, ws...)${CR}"
    ui_blank
    ui_warn "Los usuarios SSH creados ${WH}NO${CR} serán eliminados."
    ui_solid
    ui_prompt "¿Deseas continuar? (s/n)"
    if [[ "$REPLY_UI" != "s" && "$REPLY_UI" != "S" ]]; then
        ui_ok "Operación cancelada."
        sleep 2
        return
    fi

    ui_blank
    ui_err "Escribe ${WH}CONFIRMAR${CR} para proceder (distingue mayúsculas):"
    ui_prompt " "
    if [[ "$REPLY_UI" != "CONFIRMAR" ]]; then
        ui_err "Texto incorrecto. Operación cancelada."
        sleep 2
        return
    fi

    ui_blank
    ui_info "Deteniendo servicios activos..."
    for svc in stunnel4 dropbear badvpn udp-custom ws-server websocket_proxy slowdns squid v2ray shadowsocks-libev openvpn@server wg-quick@wg0 wg-quick@wg-home; do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
    done
    pkill -f badvpn    2>/dev/null
    pkill -f udpgw     2>/dev/null
    pkill -f ws-server 2>/dev/null
    ui_ok "Servicios detenidos."

    ui_info "Eliminando tareas cron..."
    crontab -l 2>/dev/null | grep -v 'killer.sh' | grep -v 'optimize.sh' | crontab - 2>/dev/null
    ui_ok "Tareas cron eliminadas."

    ui_info "Eliminando arranque automático..."
    sed -i '/^menu$/d' /root/.bashrc 2>/dev/null
    ui_ok "Autostart eliminado."

    ui_info "Eliminando comando global 'menu'..."
    rm -f /usr/local/bin/menu 2>/dev/null
    ui_ok "Comando eliminado."

    ui_info "Eliminando estado y directorio del panel..."
    rm -rf "$STATE_DIR" 2>/dev/null
    rm -rf /opt/vpsservice-free 2>/dev/null
    ui_ok "Directorio eliminado."

    ui_blank
    ui_solid
    ui_ok "Panel desinstalado correctamente."
    echo -e "${UI_PAD}${DM}Cierra esta sesión SSH para finalizar.${CR}"
    ui_solid
    echo ""
    exit 0
}

# =========================================================
# MENÚ PRINCIPAL
# =========================================================
function show_menu() {
    clear
    print_title

    show_network_status

    ui_solid
    ui_blank

    # Estado del arranque automático
    local AUTO_TAG
    if grep -q "^menu$" /root/.bashrc 2>/dev/null; then
        AUTO_TAG="$(ui_tag_str on)"
    else
        AUTO_TAG="$(ui_tag_str off)"
    fi

    # Estado del gateway residencial
    local WGH_TAG
    if ip link show wg-home &>/dev/null; then
        WGH_TAG="$(ui_tag_str on)"
    else
        WGH_TAG="$(ui_tag_str off)"
    fi

    ui_opt "1" "ADMINISTRAR CUENTAS"  "crear · editar"
    ui_opt "2" "FÁBRICA DE TÚNELES"   "11 protocolos"
    ui_opt "3" "ARRANQUE AUTOMÁTICO"  ""               "$AUTO_TAG"
    ui_opt "4" "ACTUALIZAR SCRIPT"    "desde GitHub"
    ui_opt_danger "5" "DESINSTALAR PANEL" "borrado total"
    ui_opt "6" "SINCRONIZAR UFW"      "cortafuegos"
    ui_opt "7" "OPTIMIZAR SERVIDOR"   "RAM · caché"
    ui_opt "8" "GATEWAY RESIDENCIAL"  "WireGuard"      "$WGH_TAG"
    ui_blank
    ui_opt "0" "SALIR"
    ui_solid
    ui_prompt "Digita una acción [0-8]"

    case "$REPLY_UI" in
        1) users_menu ;;
        2) sub_menu_installers ;;
        3) toggle_autostart ;;
        4) update_script ;;
        5) uninstall_panel ;;
        6) clear; print_title; ui_section "SINCRONIZAR CORTAFUEGOS"; ui_blank; sync_firewall ;;
        7) optimize_menu ;;
        8) wghome_menu ;;
        0) clear; echo -e "${DM}Saliendo... (escribe 'menu' para volver)${CR}"; exit 0 ;;
        *) ui_err "Opción no reconocida."; sleep 1 ;;
    esac
}

# =========================================================
# ARRANQUE
# =========================================================
clear
print_title

# El centinela vive en /var/lib para que sobreviva a los reinicios. Con /tmp,
# el firewall se reseteaba en cada arranque y borraba las reglas manuales.
if [ ! -f "$STATE_DIR/.firewall_synced" ]; then
    sync_firewall
    touch "$STATE_DIR/.firewall_synced"
fi

# Asegurar configuración SSH para todos los usuarios (Corrección Global)
if [ -d /etc/ssh/sshd_config.d ]; then
    if [ ! -f /etc/ssh/sshd_config.d/10-vpsservice.conf ]; then
        rm -f /etc/ssh/sshd_config.d/99-vpsservice.conf 2>/dev/null
        # FIX: el drop-in incluye AllowTcpForwarding para HTTP Injector
        cat > /etc/ssh/sshd_config.d/10-vpsservice.conf <<'SSHEOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
SSHEOF
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
fi

# Lazo de vida infinito
while true; do
    show_menu
done
