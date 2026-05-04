#!/bin/bash

# =========================================================
# RUTAS ABSOLUTAS GLOBALES
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"
# =========================================================

# === PALETA DE COLORES ===
CR="\033[0m"
CY="\033[1;36m"       # Cian bold  — números de opción, labels
GR="\033[1;32m"       # Verde bold — ON, éxito
RD="\033[0;31m"       # Rojo       — OFF, errores
YL="\033[0;33m"       # Amarillo   — separadores, [*] info
WH="\033[1;37m"       # Blanco bold— textos de opciones
DM="\033[2;37m"       # Tenue      — prompts, subtextos
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

# Referencias Modulares
source "$DIR/modules/network.sh"
source "$DIR/modules/users.sh"

# =========================================================
# CABECERA GENERAL
# =========================================================
function print_title() {
    echo -e "\033[44m\033[1;33m ====►► \033[0;44;36m◈ \033[1;44;37mvpsservice \033[1;44;32mFREE \033[0;44;36m◈ \033[1;44;33m ◄◄==== \033[0m"
}

# =========================================================
# ARRANQUE AUTOMÁTICO
# =========================================================
function toggle_autostart() {
    clear
    print_title
    echo -e "$SEP"
    echo -e "${WH}          ARRANQUE AUTOMÁTICO${CR}"
    echo -e "$SEP"
    if grep -q "^menu$" /root/.bashrc 2>/dev/null; then
        echo -e "  Estado actual: ${GR}[ ON  ]${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Desactivar? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" == "s" || "$resp" == "S" ]]; then
            sed -i '/^menu$/d' /root/.bashrc
            echo -e "  ${GR}[+]${CR} Arranque desactivado."
        fi
    else
        echo -e "  Estado actual: ${RD}[ OFF ]${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Activar? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" == "s" || "$resp" == "S" ]]; then
            echo "menu" >> /root/.bashrc
            echo -e "  ${GR}[+]${CR} Arranque activado."
        fi
    fi
    sleep 2
    show_menu
}

# =========================================================
# MENÚ USUARIOS
# =========================================================
function users_menu() {
    while true; do
        clear
        print_title
        echo -e "$SEP"
        echo -e "${WH}              MENÚ DE USUARIOS${CR}"
        echo -e "$SEP"
        echo -e "  ${CY}1)${CR}  ${WH}Crear Usuario${CR}"
        echo -e "  ${CY}2)${CR}  ${WH}Administrar Usuarios${CR}"
        echo -e "  ${CY}0)${CR}  ${WH}Volver${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige [0-2]: $(echo -e ${CR})" op
        case $op in
            1) crear_usuario ;;
            2) administrar_usuarios ;;
            0) break ;;
            *) echo -e "  ${RD}[-]${CR} Opción inválida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# ACTUALIZAR
# =========================================================
function update_script() {
    clear
    print_title
    echo -e "$SEP"
    echo -e "${WH}                ACTUALIZAR${CR}"
    echo -e "$SEP"
    CURRENT_BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -z "$CURRENT_BRANCH" ] && CURRENT_BRANCH="panel"
    echo -e "  ${YL}[*]${CR} Buscando nuevas versiones en GitHub..."
    echo ""
    git -C "$DIR" fetch origin "$CURRENT_BRANCH" &>/dev/null
    LOCAL=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    REMOTE=$(git -C "$DIR" rev-parse --short FETCH_HEAD 2>/dev/null)
    [ -z "$LOCAL" ]  && LOCAL="Desconocida"
    [ -z "$REMOTE" ] && REMOTE="Desconocida"
    echo -e "  ${DM}Rama activa       :${CR} ${WH}$CURRENT_BRANCH${CR}"
    echo -e "  ${DM}Version Instalada :${CR} ${WH}$LOCAL${CR}"
    echo -e "  ${DM}Version Nube      :${CR} ${WH}$REMOTE${CR}"
    echo ""
    if [ "$LOCAL" == "$REMOTE" ]; then
        echo -e "  ${GR}[+]${CR} Tienes la ultima version instalada."
        read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
    else
        echo -e "  ${YL}[!]${CR} Nueva actualizacion encontrada."
        echo -e "  ${YL}[*]${CR} Aplicando actualizacion..."
        git -C "$DIR" reset --hard "origin/$CURRENT_BRANCH" &>/dev/null
        echo -e "  ${YL}[*]${CR} Normalizando scripts (CRLF -> LF)..."
        find "$DIR" -name "*.sh" -exec sed -i 's/\r//' {} \;
        chmod -R +x "$DIR" 2>/dev/null
        echo -e "  ${GR}[+]${CR} Actualizado correctamente. Reiniciando..."
        sleep 2
        exec bash "$DIR/main.sh"
    fi
}

# =========================================================
# DATOS DE CONEXIÓN PARA CLIENTES
# =========================================================
function client_data() {
    refresh_ports
    clear
    print_title
    echo -e "$SEP"
    echo -e "${WH}       DATOS DE CONEXIÓN — CLIENTES${CR}"
    echo -e "$SEP"
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  ${DM}Servidor  :${CR}  ${GR}$SERVER_IP${CR}"
    echo ""

    echo -e "  ${YL}[ PROTOCOLOS SSH ]${CR}"
    [ -n "$PORT_SSH" ]          && echo -e "  ${WH}SSH          :${CR}  ${CY}$PORT_SSH${CR}  (TCP)"
    [ -n "$PORT_DROPBEAR" ]     && echo -e "  ${WH}Dropbear     :${CR}  ${CY}$PORT_DROPBEAR${CR}  (TCP)"
    [ -n "$PORT_SSL" ]          && echo -e "  ${WH}SSL/Stunnel  :${CR}  ${CY}$PORT_SSL${CR}  (TCP)"
    [ -n "$PORT_WS" ]           && echo -e "  ${WH}WebSocket    :${CR}  ${CY}$PORT_WS${CR}  path: ${DM}/${CR}"
    if [ -n "$PORT_UDPCUSTOM" ]; then
        echo -e "  ${WH}UDP Custom   :${CR}  ${CY}$PORT_UDPCUSTOM${CR}  ${DM}(túnel UDP directo — sin SSH)${CR}"
    fi
    if [ -n "$PORT_BADVPN" ]; then
        echo -e "  ${WH}BadVPN       :${CR}  ${DM}127.0.0.1:${CR}${CY}$PORT_BADVPN${CR}  ${DM}(juegos/llamadas via SSH)${CR}"
    fi
    echo ""

    echo -e "  ${YL}[ PROTOCOLOS PROXY / VPN ]${CR}"
    [ -n "$PORT_SLOWDNS" ]      && echo -e "  ${WH}SlowDNS      :${CR}  ${CY}$PORT_SLOWDNS${CR}"
    [ -n "$PORT_SQUID" ]        && echo -e "  ${WH}Squid        :${CR}  ${CY}$PORT_SQUID${CR}"
    [ -n "$PORT_V2RAY" ]        && echo -e "  ${WH}V2Ray VMess  :${CR}  ${CY}$PORT_V2RAY${CR}  path: ${DM}/v2ray${CR}"
    [ -n "$PORT_SS" ]           && echo -e "  ${WH}Shadowsocks  :${CR}  ${CY}$PORT_SS${CR}  ${DM}aes-256-gcm${CR}"
    [ -n "$PORT_OVPN" ]         && echo -e "  ${WH}OpenVPN      :${CR}  ${CY}$PORT_OVPN${CR}  (UDP)"
    [ -n "$PORT_WG" ]           && echo -e "  ${WH}WireGuard    :${CR}  ${CY}$PORT_WG${CR}  (UDP)"
    echo ""

    echo -e "  ${YL}━━━ PAYLOAD WEBSOCKET ━━━${CR}"
    echo -e "  ${DM}GET / HTTP/1.1[crlf]${CR}"
    echo -e "  ${DM}Host: ${SERVER_IP}[crlf]${CR}"
    echo -e "  ${DM}Upgrade: websocket[crlf]${CR}"
    echo -e "  ${DM}Connection: Upgrade[crlf]${CR}"
    echo -e "  ${DM}[crlf]${CR}"
    echo ""

    if [ -n "$PORT_UDPCUSTOM" ]; then
        echo -e "  ${YL}━━━ UDP CUSTOM ━━━${CR}"
        echo -e "  ${DM}Tunnel Type: UDP${CR}"
        echo -e "  ${DM}Server     : ${CR}${WH}$SERVER_IP${CR}"
        echo -e "  ${DM}Port       : ${CR}${CY}$PORT_UDPCUSTOM${CR}  (NO requiere SSH)${CR}"
        echo ""
    fi

    if [ -n "$PORT_BADVPN" ]; then
        echo -e "  ${YL}━━━ BADVPN — Gateway UDP ━━━${CR}"
        echo -e "  ${DM}1. Conecta primero por SSH (puerto ${CY}$PORT_SSH${DM})${CR}"
        echo -e "  ${DM}2. Settings → UDP Custom → Enable${CR}"
        echo -e "  ${DM}3. Host: ${CR}${WH}127.0.0.1${CR}  ${DM}Port: ${CR}${CY}$PORT_BADVPN${CR}"
        echo ""
    fi

    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
}

# =========================================================
# FÁBRICA DE TÚNELES & PROXIES
# =========================================================
function sub_menu_installers() {
    # Helper local: imprime tag ON/OFF según si $1 tiene contenido
    _tag() { [ -n "$1" ] && echo -e "${GR}[ ON  ]${CR}" || echo -e "${RD}[ OFF ]${CR}"; }

    while true; do
        refresh_ports
        clear
        print_title
        echo -e "$SEP"
        echo -e "${WH}       FÁBRICA DE TÚNELES & PROXIES${CR}"
        echo -e "$SEP"
        echo -e "  ${YL}-- PROTOCOLOS SSH / TÚNEL --${CR}"
        echo -e "  ${CY}1)${CR}  ${WH}Stunnel SSL${CR}         $(_tag "$PORT_SSL")"
        echo -e "  ${CY}2)${CR}  ${WH}UDP Custom${CR}  ${DM}(túnel UDP directo)${CR}  $(_tag "$PORT_UDPCUSTOM")"
        echo -e "  ${CY}3)${CR}  ${WH}BadVPN${CR}      ${DM}(juegos/llamadas+SSH)${CR} $(_tag "$PORT_BADVPN")"
        echo -e "  ${CY}4)${CR}  ${WH}WebSocket${CR}           $(_tag "$PORT_WS")"
        echo -e "  ${CY}5)${CR}  ${WH}Dropbear${CR}            $(_tag "$PORT_DROPBEAR")"
        echo ""
        echo -e "  ${YL}-- PROTOCOLOS PROXY --${CR}"
        echo -e "  ${CY}6)${CR}  ${WH}SlowDNS${CR}             $(_tag "$PORT_SLOWDNS")"
        echo -e "  ${CY}7)${CR}  ${WH}Squid Proxy${CR}         $(_tag "$PORT_SQUID")"
        echo ""
        echo -e "  ${YL}-- PROTOCOLOS VPN --${CR}"
        echo -e "  ${CY}8)${CR}   ${WH}V2Ray${CR}              $(_tag "$PORT_V2RAY")"
        echo -e "  ${CY}9)${CR}   ${WH}Shadowsocks${CR}        $(_tag "$PORT_SS")"
        echo -e " ${CY}10)${CR}   ${WH}OpenVPN${CR}            $(_tag "$PORT_OVPN")"
        echo -e " ${CY}11)${CR}   ${WH}WireGuard${CR}          $(_tag "$PORT_WG")"
        echo ""
        echo -e "  ${CY}C)${CR}  ${WH}Ver Datos de Conexión (clientes)${CR}"
        echo -e "  ${CY}0)${CR}  ${WH}Retroceder${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige una opción [0-11 | C]: $(echo -e ${CR})" op

        _run() {
            if [ -x "$DIR/modules/installers/$1" ]; then
                sudo "$DIR/modules/installers/$1"
            else
                echo -e "  ${RD}[-]${CR} Installer no encontrado: $1"
            fi
            sleep 1
        }

        case $op in
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
            *) echo -e "  ${RD}[-]${CR} Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MENÚ PRINCIPAL
# =========================================================

# =========================================================
# HABILITAR PANEL WEB
# =========================================================
function enable_web_panel() {
    clear
    print_title
    echo -e "$SEP"
    echo -e "${WH}           HABILITAR PANEL WEB — Web UI${CR}"
    echo -e "$SEP"

    # 1) Asegurar que existe el panel web (permite instalar el manager primero,
    # y descargar el panel después desde SSH)
    if [ ! -x "$DIR/web-panel/deploy_web_panel.sh" ]; then
        echo -e "  ${YL}[*]${CR} Panel web no encontrado localmente. Intentando descargar la carpeta web-panel..."

        if ! command -v curl >/dev/null 2>&1; then
            echo -e "  ${RD}[-]${CR} Falta 'curl'. Instálalo y reintenta. (apt-get install -y curl)"
            read -p "Presiona Enter para volver..."
            return
        fi
        if ! command -v tar >/dev/null 2>&1; then
            echo -e "  ${RD}[-]${CR} Falta 'tar'. Instálalo y reintenta. (apt-get install -y tar)"
            read -p "Presiona Enter para volver..."
            return
        fi

        TMP_DIR=$(mktemp -d)
        PANEL_ARCHIVE_URL="https://github.com/Juandocoro/Vpsservice-Bash-Free/archive/refs/heads/panel.tar.gz"
        if curl -fsSL "$PANEL_ARCHIVE_URL" -o "$TMP_DIR/panel.tar.gz"; then
            tar -xzf "$TMP_DIR/panel.tar.gz" -C "$TMP_DIR"
            SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "Vpsservice-Bash-Free-panel*" | head -n 1)
            if [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR/web-panel" ]; then
                rm -rf "$DIR/web-panel" 2>/dev/null || true
                cp -a "$SRC_DIR/web-panel" "$DIR/"
                chmod -R +x "$DIR/web-panel" 2>/dev/null || true
                echo -e "  ${GR}[+]${CR} Panel web descargado en: $DIR/web-panel"
            else
                echo -e "  ${RD}[-]${CR} No se pudo localizar 'web-panel' dentro del paquete descargado."
                rm -rf "$TMP_DIR" 2>/dev/null || true
                read -p "Presiona Enter para volver..."
                return
            fi
        else
            echo -e "  ${RD}[-]${CR} No se pudo descargar el panel desde GitHub."
            rm -rf "$TMP_DIR" 2>/dev/null || true
            read -p "Presiona Enter para volver..."
            return
        fi
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi

    # 2) Ejecutar el instalador/deploy script dentro de web-panel
    echo -e "  ${YL}[*]${CR} Iniciando instalador del panel web..."
    sudo "$DIR/web-panel/deploy_web_panel.sh"
    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para volver al menu principal...$(echo -e ${CR})"
}

# =========================================================
# DESINSTALAR PANEL
# =========================================================
function uninstall_panel() {
    clear
    print_title
    echo -e "$SEP"
    echo -e "${RD}         ⚠   DESINSTALAR PANEL   ⚠${CR}"
    echo -e "$SEP"
    echo -e "  ${YL}[!]${CR} Esta accion eliminara permanentemente:"
    echo ""
    echo -e "  ${DM}  •  Directorio /opt/vpsservice-free${CR}"
    echo -e "  ${DM}  •  Comando global 'menu' (/usr/local/bin/menu)${CR}"
    echo -e "  ${DM}  •  Cron job del auto-killer${CR}"
    echo -e "  ${DM}  •  Entrada de arranque automatico en .bashrc${CR}"
    echo -e "  ${DM}  •  Servicios activos (stunnel, badvpn, udp, ws...)${CR}"
    echo -e "  ${DM}  •  Servicio del panel web (vpsservice-panel)${CR}"
    echo ""
    echo -e "  ${YL}[!]${CR} Los usuarios SSH creados ${WH}NO${CR} seran eliminados."
    echo ""
    echo -e "$SEP"
    read -p "$(echo -e ${DM})¿Deseas continuar? (s/n): $(echo -e ${CR})" resp
    if [[ "$resp" != "s" && "$resp" != "S" ]]; then
        echo -e "  ${GR}[+]${CR} Operacion cancelada."
        sleep 2
        show_menu
        return
    fi

    echo ""
    echo -e "  ${RD}[!]${CR} Escribe ${WH}CONFIRMAR${CR} para proceder (distingue mayusculas):"
    read -p "$(echo -e ${DM})  > $(echo -e ${CR})" confirm
    if [[ "$confirm" != "CONFIRMAR" ]]; then
        echo -e "  ${RD}[-]${CR} Texto incorrecto. Operacion cancelada."
        sleep 2
        show_menu
        return
    fi

    echo ""
    echo -e "  ${YL}[*]${CR} Deteniendo servicios activos..."
    for svc in stunnel4 dropbear badvpn udp-custom ws-server slowdns squid v2ray shadowsocks openvpn wg-quick@wg0 vpsservice-panel nginx; do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
    done
    pkill -f badvpn    2>/dev/null
    pkill -f udpgw     2>/dev/null
    pkill -f ws-server 2>/dev/null
    pkill -f gunicorn  2>/dev/null
    echo -e "  ${GR}[+]${CR} Servicios detenidos."

    echo -e "  ${YL}[*]${CR} Eliminando servicio systemd del panel web..."
    rm -f /etc/systemd/system/vpsservice-panel.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    echo -e "  ${GR}[+]${CR} Servicio web eliminado."

    echo -e "  ${YL}[*]${CR} Eliminando config de Nginx..."
    rm -f /etc/nginx/sites-enabled/vpsservice-panel 2>/dev/null
    rm -f /etc/nginx/sites-available/vpsservice-panel 2>/dev/null
    systemctl reload nginx 2>/dev/null
    echo -e "  ${GR}[+]${CR} Nginx limpiado."

    echo -e "  ${YL}[*]${CR} Eliminando cron del auto-killer..."
    crontab -l 2>/dev/null | grep -v 'killer.sh' | crontab - 2>/dev/null
    echo -e "  ${GR}[+]${CR} Cron eliminado."

    echo -e "  ${YL}[*]${CR} Eliminando arranque automatico de .bashrc..."
    sed -i '/^menu$/d' /root/.bashrc 2>/dev/null
    echo -e "  ${GR}[+]${CR} Autostart eliminado."

    echo -e "  ${YL}[*]${CR} Eliminando comando global 'menu'..."
    rm -f /usr/local/bin/menu 2>/dev/null
    echo -e "  ${GR}[+]${CR} Comando eliminado."

    echo -e "  ${YL}[*]${CR} Eliminando directorio del panel..."
    rm -rf /opt/vpsservice-free 2>/dev/null
    echo -e "  ${GR}[+]${CR} Directorio eliminado."

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+]${CR} Panel desinstalado correctamente."
    echo -e "  ${DM}    Cierra esta sesion SSH para finalizar.${CR}"
    echo -e "$SEP"
    echo ""
    exit 0
}

function show_menu() {
    clear
    print_title
    echo -e "$SEP"
    echo -e "${WH}              MENU PRINCIPAL${CR}"
    echo -e "$SEP"

    show_network_status

    echo -e "$SEP"

    # Estado arranque automático
    if grep -q "^menu$" /root/.bashrc 2>/dev/null; then
        AUTO_TAG="${GR}[ ON  ]${CR}"
    else
        AUTO_TAG="${RD}[ OFF ]${CR}"
    fi

    echo -e "  ${CY}1)${CR}  ${WH}Usuarios (Crear/Modificar)${CR}"
    echo -e "  ${CY}2)${CR}  ${WH}Instalacion de Protocolos${CR}"
    echo -e "  ${CY}3)${CR}  ${WH}Arranque Automatico      ${CR}  $AUTO_TAG"
    echo -e "  ${CY}4)${CR}  ${WH}Actualizar${CR}"
    echo -e "  ${CY}5)${CR}  ${WH}Habilitar Panel Web (Web UI)${CR}"
    echo -e "  ${CY}6)${CR}  ${RD}⚠  Desinstalar Panel${CR}"
    echo -e "  ${CY}0)${CR}  ${WH}Salir${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Digita una accion [0-6]: $(echo -e ${CR})" opcion

    case $opcion in
        1) users_menu ;;
        2) sub_menu_installers ;;
        3) toggle_autostart ;;
        4) update_script ;;
        5) enable_web_panel ;;
        6) uninstall_panel ;;
        0) clear; echo -e "${DM}Saliendo... (escribe 'menu' para volver)${CR}"; exit 0 ;;
        *) echo -e "  ${RD}[-]${CR} Opcion no reconocida."; sleep 1; show_menu ;;
    esac
}

# Lazo de vida infinito
while true; do
    show_menu
done