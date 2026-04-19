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
    echo -e "  ${YL}[*]${CR} Buscando nuevas versiones en GitHub..."
    echo ""
    git fetch origin main &>/dev/null
    LOCAL=$(git rev-parse --short HEAD 2>/dev/null)
    REMOTE=$(git rev-parse --short FETCH_HEAD 2>/dev/null)
    [ -z "$LOCAL" ]  && LOCAL="Desconocida"
    [ -z "$REMOTE" ] && REMOTE="Desconocida"
    echo -e "  ${DM}Versión Instalada :${CR} ${WH}$LOCAL${CR}"
    echo -e "  ${DM}Versión Nube      :${CR} ${WH}$REMOTE${CR}"
    echo ""
    if [ "$LOCAL" == "$REMOTE" ]; then
        echo -e "  ${GR}[+]${CR} Tienes la última versión instalada."
        read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
    else
        echo -e "  ${YL}[!]${CR} Nueva actualización encontrada."
        echo -e "  ${YL}[*]${CR} Descargando y reparando permisos..."
        git reset --hard FETCH_HEAD &>/dev/null
        chmod -R +x "$DIR" 2>/dev/null
        echo -e "  ${GR}[+]${CR} Actualizado correctamente. Reiniciando..."
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
    echo -e "$SEP"
    echo -e "${WH}       DATOS DE CONEXIÓN — CLIENTES${CR}"
    echo -e "$SEP"
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  ${DM}Servidor  :${CR}  ${GR}$SERVER_IP${CR}"
    echo ""
    [ -n "$PORT_SSH" ]      && echo -e "  ${WH}SSH        :${CR}  puerto ${CY}$PORT_SSH${CR}"
    [ -n "$PORT_DROPBEAR" ] && echo -e "  ${WH}Dropbear   :${CR}  puerto ${CY}$PORT_DROPBEAR${CR}"
    [ -n "$PORT_SSL" ]      && echo -e "  ${WH}SSL/Stunnel:${CR}  puerto ${CY}$PORT_SSL${CR}"
    [ -n "$PORT_WS" ]       && echo -e "  ${WH}WebSocket  :${CR}  puerto ${CY}$PORT_WS${CR}  path: ${DM}/${CR}"
    [ -n "$PORT_SLOWDNS" ]  && echo -e "  ${WH}SlowDNS    :${CR}  puerto ${CY}$PORT_SLOWDNS${CR}"
    [ -n "$PORT_SQUID" ]    && echo -e "  ${WH}Squid      :${CR}  puerto ${CY}$PORT_SQUID${CR}"
    [ -n "$PORT_V2RAY" ]    && echo -e "  ${WH}V2Ray      :${CR}  puerto ${CY}$PORT_V2RAY${CR}  path: ${DM}/v2ray${CR}"
    [ -n "$PORT_SS" ]       && echo -e "  ${WH}Shadowsocks:${CR}  puerto ${CY}$PORT_SS${CR}  cifrado: ${DM}aes-256-gcm${CR}"
    [ -n "$PORT_OVPN" ]     && echo -e "  ${WH}OpenVPN    :${CR}  puerto ${CY}$PORT_OVPN${CR}"
    [ -n "$PORT_WG" ]       && echo -e "  ${WH}WireGuard  :${CR}  puerto ${CY}$PORT_WG${CR}"
    echo ""
    echo -e "  ${YL}--- PAYLOAD HTTP INJECTOR (WebSocket) ---${CR}"
    echo -e "  ${DM}GET / HTTP/1.1[crlf]${CR}"
    echo -e "  ${DM}Host: [host][crlf]${CR}"
    echo -e "  ${DM}Upgrade: websocket[crlf]${CR}"
    echo -e "  ${DM}Connection: Upgrade[crlf]${CR}"
    echo -e "  ${DM}[crlf]${CR}"
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
        echo -e "  ${YL}-- PROTOCOLOS SSH --${CR}"
        echo -e "  ${CY}1)${CR}  ${WH}Stunnel SSL${CR}    $(_tag "$PORT_SSL")"
        echo -e "  ${CY}2)${CR}  ${WH}UDP/BadVPN${CR}     $(_tag "$PORT_UDP")"
        echo -e "  ${CY}3)${CR}  ${WH}WebSocket${CR}      $(_tag "$PORT_WS")"
        echo -e "  ${CY}4)${CR}  ${WH}Dropbear${CR}       $(_tag "$PORT_DROPBEAR")"
        echo ""
        echo -e "  ${YL}-- PROTOCOLOS PROXY --${CR}"
        echo -e "  ${CY}5)${CR}  ${WH}SlowDNS${CR}        $(_tag "$PORT_SLOWDNS")"
        echo -e "  ${CY}6)${CR}  ${WH}Squid Proxy${CR}    $(_tag "$PORT_SQUID")"
        echo ""
        echo -e "  ${YL}-- PROTOCOLOS VPN --${CR}"
        echo -e "  ${CY}7)${CR}  ${WH}V2Ray${CR}          $(_tag "$PORT_V2RAY")"
        echo -e "  ${CY}8)${CR}  ${WH}Shadowsocks${CR}    $(_tag "$PORT_SS")"
        echo -e "  ${CY}9)${CR}  ${WH}OpenVPN${CR}        $(_tag "$PORT_OVPN")"
        echo -e " ${CY}10)${CR}  ${WH}WireGuard${CR}      $(_tag "$PORT_WG")"
        echo ""
        echo -e "  ${CY}C)${CR}  ${WH}Ver Datos de Conexión (clientes)${CR}"
        echo -e "  ${CY}0)${CR}  ${WH}Retroceder${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige una opción [0-10 | C]: $(echo -e ${CR})" op

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
            3)  _run "websocket_installer.sh" ;;
            4)  _run "dropbear_installer.sh" ;;
            5)  _run "slowdns_installer.sh" ;;
            6)  _run "squid_installer.sh" ;;
            7)  _run "v2ray_installer.sh" ;;
            8)  _run "shadowsocks_installer.sh" ;;
            9)  _run "openvpn_installer.sh" ;;
            10) _run "wireguard_installer.sh" ;;
            [Cc]) client_data ;;
            0) break ;;
            *) echo -e "  ${RD}[-]${CR} Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MENÚ PRINCIPAL
# =========================================================
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
    echo -e "  ${CY}2)${CR}  ${WH}Instalación de Protocolos${CR}"
    echo -e "  ${CY}3)${CR}  ${WH}Arranque Automático      ${CR}  $AUTO_TAG"
    echo -e "  ${CY}4)${CR}  ${WH}Actualizar${CR}"
    echo -e "  ${CY}0)${CR}  ${WH}Salir${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Digita una acción [0-4]: $(echo -e ${CR})" opcion

    case $opcion in
        1) users_menu ;;
        2) sub_menu_installers ;;
        3) toggle_autostart ;;
        4) update_script ;;
        0) clear; echo -e "${DM}Saliendo... (escribe 'menu' para volver)${CR}"; exit 0 ;;
        *) echo -e "  ${RD}[-]${CR} Opción no reconocida."; sleep 1; show_menu ;;
    esac
}

# Lazo de vida infinito
while true; do
    show_menu
done
