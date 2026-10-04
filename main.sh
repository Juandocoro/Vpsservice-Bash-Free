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
source "$DIR/modules/system.sh"
source "$DIR/modules/installers/wg_home.sh"
source "$DIR/modules/installers/mobile_beta.sh"

VPS_VERSION="v1.0"

# Estado persistente del panel. Antes se usaba /tmp, que el sistema vacia en
# cada reinicio: el firewall se reseteaba solo y borraba reglas del admin.
STATE_DIR="/var/lib/vpsservice"
mkdir -p "$STATE_DIR" 2>/dev/null

# =========================================================
# CABECERA GENERAL
# =========================================================
# La version no cambia mientras el panel esta abierto (actualizar lo
# relanza): se calcula una vez. Antes eran dos 'git' por pantalla.
PANEL_VER=""
function print_title() {
    if [ -z "$PANEL_VER" ]; then
        local COMMIT
        COMMIT=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
        PANEL_VER="FREE · ${VPS_VERSION}${COMMIT:+ · ${COMMIT}}"
    fi
    echo ""
    ui_header "$PANEL_VER"
}

# =========================================================
# ARRANQUE AUTOMÁTICO — interruptor directo
# =========================================================
function toggle_autostart() {
    if grep -q "^menu$" /root/.bashrc 2>/dev/null; then
        sed -i '/^menu$/d' /root/.bashrc
        ui_ok "Arranque automático ${RD}desactivado${CR}."
    else
        echo "menu" >> /root/.bashrc
        ui_ok "Arranque automático ${GR}activado${CR}."
    fi
    sleep 1
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

    git -C "$DIR" fetch origin main &>/dev/null
    local LOCAL REMOTE PREV
    LOCAL=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    REMOTE=$(git -C "$DIR" rev-parse --short FETCH_HEAD 2>/dev/null)
    PREV=$(cat "$STATE_DIR/.prev_commit" 2>/dev/null)
    [ -z "$LOCAL" ]  && LOCAL="Desconocida"
    [ -z "$REMOTE" ] && REMOTE="Desconocida"

    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Versión instalada" "$LOCAL" 34)"
    echo -e "${UI_PAD}${CY}▪${CR} $(ui_cell "Versión en la nube" "$REMOTE" 34 "$CY")"
    [ -n "$PREV" ] && echo -e "${UI_PAD}${DM}▪${CR} $(ui_cell "Versión anterior" "${PREV:0:7}" 34 "$DM")"
    ui_blank

    if [ "$LOCAL" == "$REMOTE" ] || [ "$REMOTE" = "Desconocida" ]; then
        if [ "$REMOTE" = "Desconocida" ]; then ui_warn "No se pudo consultar GitHub."
        else ui_ok "Ya tienes la última versión instalada."; fi
        if [ -n "$PREV" ]; then
            ui_blank
            ui_prompt "Escribe ANTERIOR para volver a la versión previa (Enter = salir)"
            [ "$REPLY_UI" = "ANTERIOR" ] && _instalar_version "$PREV"
        else
            ui_solid; ui_pause
        fi
        return
    fi

    ui_warn "Nueva actualización disponible."
    _instalar_version FETCH_HEAD
}

# Instala una version del repositorio, pero solo si todos sus scripts
# pasan 'bash -n'. Antes se hacia 'git reset --hard' a ciegas, y el
# auto-killer, el guardian y el vigilante se ejecutan desde aqui: un
# commit roto llegaba a la vez a todos los VPS y los dejaba sin servicio.
_instalar_version() {
    local ref="$1" tmp bad="" f
    ui_info "Comprobando la versión antes de instalarla..."
    tmp=$(mktemp -d)
    if ! git -C "$DIR" archive "$ref" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; ui_err "No se pudo leer esa versión. El panel sigue como estaba."; ui_pause; return
    fi
    while IFS= read -r f; do
        bash -n "$f" 2>/dev/null || bad="$bad ${f#"$tmp"/}"
    done < <(find "$tmp" -name '*.sh')
    rm -rf "$tmp"
    if [ -n "$bad" ]; then
        ui_err "La versión tiene errores en:${bad}"
        ui_err "No se instala. Tu panel sigue como estaba."
        ui_pause; return
    fi

    git -C "$DIR" rev-parse HEAD > "$STATE_DIR/.prev_commit" 2>/dev/null
    git -C "$DIR" reset --hard "$ref" &>/dev/null
    chmod -R +x "$DIR" 2>/dev/null
    # El vigilante es un proceso que no termina: si no se reinicia,
    # seguiria corriendo el codigo viejo hasta el proximo arranque.
    systemctl try-restart homevpn-watchdog.service &>/dev/null
    ui_ok "Actualizado correctamente. Reiniciando el panel..."
    sleep 2
    exec "$DIR/main.sh"
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
        ui_section "PROTOCOLOS" "instalar · reconfigurar · datos para el cliente"
        ui_blank

        echo -e "${UI_PAD}${YL}── SSH / TÚNEL ──${CR}"
        # [CAIDO] = instalado pero parado: sus clientes no tienen servicio.
        ui_opt "1"  "STUNNEL SSL"  "SSH sobre TLS"     "$(ui_tag_svc "$PORT_SSL" stunnel4)"
        ui_opt "2"  "UDP CUSTOM"   "túnel UDP directo" "$(ui_tag_svc "$PORT_UDPCUSTOM" udp-custom)"
        ui_opt "3"  "BADVPN"       "juegos + llamadas" "$(ui_tag_svc "$PORT_BADVPN" badvpn)"
        ui_opt "4"  "WEBSOCKET"    "HTTP Injector"     "$(ui_tag_svc "$PORT_WS" websocket_proxy)"
        ui_opt "5"  "DROPBEAR"     "SSH ligero"        "$(ui_tag_svc "$PORT_DROPBEAR" dropbear)"
        ui_blank
        echo -e "${UI_PAD}${YL}── PROXY ──${CR}"
        ui_opt "6"  "SLOWDNS"      "túnel por DNS"     "$(ui_tag_svc "$PORT_SLOWDNS" slowdns)"
        ui_opt "7"  "SQUID PROXY"  "proxy HTTP"        "$(ui_tag_svc "$PORT_SQUID" squid)"
        ui_blank
        echo -e "${UI_PAD}${YL}── VPN ──${CR}"
        ui_opt "8"  "V2RAY"        "VMess + WS"        "$(ui_tag_svc "$PORT_V2RAY" v2ray)"
        ui_opt "9"  "SHADOWSOCKS"  "aes-256-gcm"       "$(ui_tag_svc "$PORT_SS" shadowsocks-libev)"
        ui_opt "10" "OPENVPN"      "perfil .ovpn"      "$(ui_tag_svc "$PORT_OVPN" openvpn@server)"
        ui_opt "11" "WIREGUARD"    "ChaCha20 / UDP"    "$(ui_tag_svc "$PORT_WG" wg-quick@wg0)"
        ui_blank
        ui_opt "D"  "DATOS DE CONEXIÓN" "puertos y payload"
        ui_opt "0"  "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-11 | D]"
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
            [Dd]) client_data ;;
            0|"") break ;;
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
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Cron del auto-killer, del guardián y de la optimización${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Entrada de arranque automático en .bashrc${CR}"
    echo -e "${UI_PAD}${RD}▪${CR} ${DM}Servicios activos (stunnel, badvpn, udp, ws...)${CR}"
    ui_blank
    ui_warn "Los usuarios SSH creados ${WH}NO${CR} serán eliminados."
    ui_solid
    ui_prompt "Escribe CONFIRMAR para proceder (Enter = cancelar)"
    if [[ "$REPLY_UI" != "CONFIRMAR" ]]; then
        ui_info "Operación cancelada."
        sleep 2
        return
    fi

    ui_blank
    ui_info "Deteniendo servicios activos..."
    for svc in stunnel4 dropbear badvpn udp-custom ws-server websocket_proxy slowdns squid v2ray shadowsocks-libev openvpn@server wg-quick@wg0 \
               homevpn-watchdog homevpn-rules \
               $(systemctl list-units --all --plain --no-legend 'wg-quick@wg-home*' 'redsocks-node*' 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
    done
    pkill -f badvpn    2>/dev/null
    pkill -f udpgw     2>/dev/null
    pkill -f ws-server 2>/dev/null
    ui_ok "Servicios detenidos."

    ui_info "Eliminando tareas cron..."
    crontab -l 2>/dev/null | grep -v 'killer.sh' | grep -v 'guardian.sh' | grep -v 'optimize.sh' | crontab - 2>/dev/null
    ui_ok "Tareas cron eliminadas."

    ui_info "Eliminando arranque automático..."
    sed -i '/^menu$/d' /root/.bashrc 2>/dev/null
    ui_ok "Autostart eliminado."

    ui_info "Eliminando comando global 'menu'..."
    rm -f /usr/local/bin/menu 2>/dev/null
    ui_ok "Comando eliminado."

    ui_info "Eliminando estado y directorio del panel..."
    rm -f /root/movil-*.txt 2>/dev/null
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
# SISTEMA — el sistema operativo del VPS
# =========================================================
function sistema_menu() {
    while true; do
        refresh_ports
        clear
        print_title
        ui_section "SISTEMA" "acceso, red y mantenimiento del VPS"
        ui_blank

        local ROOT_TAG TZ_NOW
        _root_ssh_allowed && ROOT_TAG="$(ui_tag_str on)" || ROOT_TAG="$(ui_tag_str off)"
        TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null || echo "N/A")

        echo -e "${UI_PAD}${YL}── ACCESO ──${CR}"
        ui_opt "1" "ACCESO ROOT"         "clave y login"  "$ROOT_TAG"
        ui_opt "2" "PUERTO SSH"          "actual: ${PORT_SSH:-22}"
        ui_opt "3" "CORTAFUEGOS UFW"     "abrir puertos"
        ui_blank
        echo -e "${UI_PAD}${YL}── MANTENIMIENTO ──${CR}"
        ui_opt "4" "ZONA HORARIA"        "${TZ_NOW##*/}"
        ui_opt "5" "OPTIMIZAR"           "RAM · disco"
        ui_opt "6" "REINICIAR SERVIDOR"  "cierra túneles"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-6]"

        case "$REPLY_UI" in
            1) root_access_menu ;;
            2) ssh_port_config ;;
            3) clear; print_title; ui_section "CORTAFUEGOS UFW"; ui_blank; sync_firewall ;;
            4) timezone_config ;;
            5) optimize_menu ;;
            6) reboot_vps ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# REGISTRO DE EVENTOS
# ---------------------------------------------------------
# El guardian, el vigilante y el auto-killer trabajan solos, y
# hasta ahora no habia forma de saber que habian hecho: si un
# cliente decia "anoche se me corto", no habia donde mirarlo.
# =========================================================
function eventos_panel() {
    clear
    print_title
    ui_section "REGISTRO DE EVENTOS" "lo que el panel hizo solo"
    ui_blank
    local l
    echo -e "${UI_PAD}${YL}── SERVICIOS (guardián) ──${CR}"
    l=$(tail -n 8 /var/log/vpsservice-guardian.log 2>/dev/null)
    [ -n "$l" ] && echo "$l" | sed "s/^/${UI_PAD}/" || echo -e "${UI_PAD}${GR}Ninguna caída registrada.${CR}"
    ui_blank
    echo -e "${UI_PAD}${YL}── NODOS (vigilante) ──${CR}"
    l=$(grep -E 'CAIDO|recuperado|restaurad|Vigilante (iniciado|activado|desactivado)' /var/log/homevpn.log 2>/dev/null | tail -n 8)
    [ -n "$l" ] && echo "$l" | sed "s/^/${UI_PAD}/" || echo -e "${UI_PAD}${DM}Sin eventos de nodos.${CR}"
    ui_blank
    echo -e "${UI_PAD}${YL}── LÍMITE DE DISPOSITIVOS (auto-killer) ──${CR}"
    l=$(journalctl -t vpsservice-killer -n 8 --no-pager -o short-iso 2>/dev/null | grep -v '^-- ')
    [ -n "$l" ] && echo "$l" | sed "s/^/${UI_PAD}/" || echo -e "${UI_PAD}${DM}Nadie ha superado su límite.${CR}"
    ui_solid
    ui_pause
}

# =========================================================
# PANEL — el propio script
# =========================================================
function panel_menu() {
    while true; do
        clear
        print_title
        ui_section "PANEL" "versión, registro y arranque"
        ui_blank
        local AUTO_TAG
        grep -q "^menu$" /root/.bashrc 2>/dev/null && AUTO_TAG="$(ui_tag_str on)" || AUTO_TAG="$(ui_tag_str off)"

        ui_opt "1" "ACTUALIZAR"          "desde GitHub"
        ui_opt "2" "REGISTRO DE EVENTOS" "caídas y cortes"
        ui_opt "3" "ARRANQUE AUTOMÁTICO" "al entrar por SSH" "$AUTO_TAG"
        ui_blank
        ui_opt_danger "4" "DESINSTALAR PANEL" "borrado total"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-4]"

        case "$REPLY_UI" in
            1) update_script ;;
            2) eventos_panel ;;
            3) toggle_autostart ;;
            4) uninstall_panel ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MENÚ PRINCIPAL
# Lo de todos los dias, a un toque; lo demas en sus submenus.
# El tablero de arriba ya informa del estado y de las alertas.
# =========================================================
function show_menu() {
    clear
    print_title

    show_network_status

    ui_solid
    local RES_TAG
    _wgh_routing_is_active && RES_TAG="$(ui_tag_str on)" || RES_TAG="$(ui_tag_str off)"

    # Dos bloques: lo de cada dia (cuentas) y lo del servidor. Cada
    # opcion del bloque SERVIDOR agrupa un tema completo; antes todo
    # vivia junto en un menu de configuracion de 12 opciones.
    echo -e "${UI_PAD}${YL}── CUENTAS ──${CR}"
    ui_opt "1" "CREAR CUENTA"         "usuario nuevo"
    ui_opt "2" "RENOVAR CUENTA"       "sumar días"
    ui_opt "3" "CUENTAS"              "ficha · editar · borrar"
    ui_opt "4" "CONECTADOS AHORA"     "monitor"
    echo -e "${UI_PAD}${YL}── SERVIDOR ──${CR}"
    ui_opt "5" "PROTOCOLOS"           "instalar · datos"
    ui_opt "6" "IP RESIDENCIAL"       "nodos · móvil beta" "$RES_TAG"
    ui_opt "7" "SISTEMA"              "ssh · firewall · hora"
    ui_opt "8" "PANEL"                "actualizar · registro"
    ui_blank
    ui_opt "0" "SALIR"
    ui_solid
    ui_prompt "Digita una acción [0-8]"

    case "$REPLY_UI" in
        1) crear_usuario ;;
        2) renovar_vigencia ;;
        3) cuentas_menu ;;
        4) monitor_conexiones ;;
        5) sub_menu_installers ;;
        6) wghome_menu ;;
        7) sistema_menu ;;
        8) panel_menu ;;
        0) clear; echo -e "${DM}Saliendo... (escribe 'menu' para volver)${CR}"; exit 0 ;;
        "") ;;
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

# =========================================================
# PUESTA AL DIA — para los VPS que ya tenian el panel
# ---------------------------------------------------------
# Todo es idempotente: si ya esta bien, no toca nada ni
# reinicia ningun servicio.
# =========================================================
_ensure_cron() {
    local line="$1" pat="$2"
    crontab -l 2>/dev/null | grep -qF "$pat" && return 0
    (crontab -l 2>/dev/null; echo "$line") | crontab - 2>/dev/null
}

_puesta_al_dia() {
    # SSH de tunneling (y sesiones fantasma con ClientAlive). Solo
    # recarga sshd si la configuracion cambia.
    ssh_apply_tunnel_config

    # Auto-killer y guardian de servicios, cada minuto.
    _ensure_cron "* * * * * bash $DIR/modules/killer.sh"   "modules/killer.sh"
    _ensure_cron "* * * * * bash $DIR/modules/guardian.sh" "modules/guardian.sh"

    # Gateway residencial
    [ -f "$_SOCKS_SSHD_DROPIN" ] && _socks_harden_sshd
    if _wgh_routing_is_active; then
        # Antes la salida no sobrevivia a un reinicio: se registra.
        [ -f "$WGH_ROUTING_FLAG" ] || _wgh_persist_on
        # Y nunca sin vigilante: es lo que evita que un nodo caido
        # deje a sus usuarios sin Internet.
        _wgh_watchdog_is_on || _wgh_watchdog_enable
    fi
    # El vigilante corre sin parar: tras actualizar el panel hay que
    # reiniciarlo para que use el codigo nuevo (y su unidad corregida).
    local head
    head=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
    if _wgh_watchdog_is_on && [ "$(cat "$STATE_DIR/.watchdog_commit" 2>/dev/null)" != "$head" ]; then
        _wgh_watchdog_enable
        echo "$head" > "$STATE_DIR/.watchdog_commit"
    fi
}
_puesta_al_dia &>/dev/null

# Lazo de vida infinito
while true; do
    show_menu
done
