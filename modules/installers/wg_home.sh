#!/bin/bash
# =========================================================
# MÓDULO: Gateway Residencial por WireGuard
# Interfaz : wg-home
# Red VPN  : 10.77.77.0/24
# Droplet  : 10.77.77.1  (servidor, escucha 51820/UDP)
# PC Home  : 10.77.77.2  (cliente, sale a Internet residencial)
# Tabla RT : 200 homevpn (policy routing — no toca tabla main)
# =========================================================
# SEGURIDAD SSH: Esta implementación NUNCA modifica la ruta
# por defecto de la tabla main. SSH permanece siempre activo.
# =========================================================

# === Constantes del módulo ===
WGH_IFACE="wg-home"
WGH_CONF="/etc/wireguard/wg-home.conf"
WGH_PRIV_KEY="/etc/wireguard/wghome_droplet_private.key"
WGH_PUB_KEY="/etc/wireguard/wghome_droplet_public.key"
WGH_PORT="51820"
WGH_SUBNET="10.77.77.0/24"
WGH_DROPLET_IP="10.77.77.1"
WGH_PEER_IP="10.77.77.2"
WGH_RT_TABLE="200"
WGH_RT_NAME="homevpn"
WGH_RT_BACKUP="/etc/wireguard/wghome_route_backup"

# Paleta heredada del entorno (main.sh la exporta via source)
# CR CY GR RD YL WH DM SEP — ya están definidas

# =========================================================
# HELPERS INTERNOS
# =========================================================

# Detectar distribución base
_wgh_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Instalar WireGuard si no está presente
_wgh_ensure_installed() {
    if command -v wg &>/dev/null && command -v wg-quick &>/dev/null; then
        return 0
    fi
    echo -e "  ${YL}[*]${CR} WireGuard no encontrado. Instalando..."
    local distro
    distro=$(_wgh_distro)
    case "$distro" in
        ubuntu|debian)
            apt-get update -yq &>/dev/null
            apt-get install -yq wireguard wireguard-tools &>/dev/null
            ;;
        *)
            echo -e "  ${RD}[-]${CR} Distribución no reconocida: $distro"
            echo -e "  ${YL}[!]${CR} Intenta instalar manualmente: apt-get install wireguard wireguard-tools"
            return 1
            ;;
    esac
    if ! command -v wg &>/dev/null; then
        echo -e "  ${RD}[-]${CR} Error instalando WireGuard."
        return 1
    fi
    echo -e "  ${GR}[+]${CR} WireGuard instalado correctamente."
    return 0
}

# Registrar tabla de rutas si no existe
_wgh_ensure_rt_table() {
    if ! grep -q "^${WGH_RT_TABLE}[[:space:]]" /etc/iproute2/rt_tables 2>/dev/null; then
        echo -e "  ${YL}[*]${CR} Registrando tabla de rutas ${WGH_RT_TABLE} ${WGH_RT_NAME}..."
        echo "${WGH_RT_TABLE} ${WGH_RT_NAME}" >> /etc/iproute2/rt_tables
        echo -e "  ${GR}[+]${CR} Tabla ${WGH_RT_NAME} registrada."
    fi
}

# Activar IP forwarding (sin duplicar en sysctl.conf)
_wgh_enable_forwarding() {
    # Aplicar inmediatamente
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    # Persistir solo si no existe ya la directiva
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        # Asegurar que esté en 1 aunque exista la línea
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi
}

# Verificar que el túnel tiene handshake reciente (< 3 minutos)
_wgh_has_handshake() {
    local ts
    ts=$(wg show "${WGH_IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
    [ -z "$ts" ] && return 1
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    [ "$diff" -lt 180 ]
}

# Verificar que la ruta SSH principal no pasa por wg-home
_wgh_verify_ssh_route() {
    local default_gw
    default_gw=$(ip route show table main | grep '^default' | grep -v "wg-home" | head -1)
    if [ -z "$default_gw" ]; then
        echo -e "  ${RD}[!]${CR} ADVERTENCIA: La ruta por defecto en tabla main no se encontró o usa wg-home."
        echo -e "  ${RD}[!]${CR} SSH podría verse afectado. Verifica con: ip route show table main"
        return 1
    fi
    return 0
}

# Abrir puerto 51820/udp en UFW (si UFW está activo)
_wgh_open_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${WGH_PORT}/udp" &>/dev/null
        echo -e "  ${GR}[+]${CR} UFW: puerto ${WGH_PORT}/UDP abierto."
    fi
}

# Cerrar puerto 51820/udp en UFW (si UFW está activo)
_wgh_close_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "${WGH_PORT}/udp" &>/dev/null
        echo -e "  ${GR}[+]${CR} UFW: regla ${WGH_PORT}/UDP eliminada."
    fi
}

# Verificar si el módulo está instalado (conf existe)
_wgh_is_installed() {
    [ -f "${WGH_CONF}" ] && [ -f "${WGH_PRIV_KEY}" ]
}

# Verificar si el túnel está activo
_wgh_is_up() {
    ip link show "${WGH_IFACE}" &>/dev/null 2>&1
}

# Verificar si la salida residencial está activa
_wgh_routing_is_active() {
    ip rule show | grep -q "lookup ${WGH_RT_NAME}\|lookup ${WGH_RT_TABLE}"
}

# =========================================================
# 1. INSTALAR / CONFIGURAR GATEWAY RESIDENCIAL
# =========================================================
wghome_install() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     INSTALAR GATEWAY RESIDENCIAL (WireGuard)${CR}"
    echo -e "$SEP"

    if _wgh_is_installed; then
        echo -e "  ${YL}[!]${CR} El gateway ya está configurado."
        echo -e "  ${DM}    Conf: ${WGH_CONF}${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Reinstalar/sobreescribir? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."
            sleep 1
            return
        fi
        # Detener el túnel antes de reconfigurar
        systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    fi

    # Paso 1: Instalar WireGuard
    echo ""
    _wgh_ensure_installed || { sleep 2; return 1; }

    # Paso 2: Habilitar forwarding
    echo -e "  ${YL}[*]${CR} Habilitando IP forwarding..."
    _wgh_enable_forwarding
    echo -e "  ${GR}[+]${CR} IP forwarding activo."

    # Paso 3: Registrar tabla de rutas
    _wgh_ensure_rt_table

    # Paso 4: Generar claves
    echo -e "  ${YL}[*]${CR} Generando par de claves para la Droplet..."
    mkdir -p /etc/wireguard
    # Generar clave privada con permisos restringidos desde el inicio
    (umask 077; wg genkey > "${WGH_PRIV_KEY}")
    wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
    chmod 600 "${WGH_PRIV_KEY}"
    chmod 644 "${WGH_PUB_KEY}"
    echo -e "  ${GR}[+]${CR} Claves generadas (clave privada protegida, chmod 600)."

    # Paso 5: Crear wg-home.conf
    # IMPORTANTE: AllowedIPs = 10.77.77.2/32 — NO 0.0.0.0/0
    # wg-quick NO modifica la tabla main con este config.
    echo -e "  ${YL}[*]${CR} Creando ${WGH_CONF}..."
    local PRIV
    PRIV=$(cat "${WGH_PRIV_KEY}")

    # Leer clave pública del peer si ya existe registrada
    local PEER_PUB=""
    if [ -f /etc/wireguard/wghome_peer_public.key ]; then
        PEER_PUB=$(cat /etc/wireguard/wghome_peer_public.key)
    fi

    cat > "${WGH_CONF}" <<EOF
# =========================================================
# Gateway Residencial — Droplet (Servidor WireGuard)
# Interfaz : ${WGH_IFACE}
# Red VPN  : ${WGH_SUBNET}
# ATENCIÓN : AllowedIPs del peer NO incluye 0.0.0.0/0
#            para no alterar la ruta por defecto de la Droplet.
#            El policy routing se gestiona desde el panel.
# =========================================================

[Interface]
Address    = ${WGH_DROPLET_IP}/24
ListenPort = ${WGH_PORT}
PrivateKey = ${PRIV}

EOF

    if [ -n "$PEER_PUB" ]; then
        cat >> "${WGH_CONF}" <<EOF
[Peer]
# PC doméstico en Colombia
PublicKey        = ${PEER_PUB}
AllowedIPs       = ${WGH_PEER_IP}/32
PersistentKeepalive = 0
# Nota: PersistentKeepalive se configura en el PC doméstico (valor 25),
# no en el servidor.
EOF
    else
        cat >> "${WGH_CONF}" <<EOF
# [Peer] — Pendiente registrar clave pública del PC doméstico.
# Usa la opción "Registrar clave pública del PC doméstico" del menú.
EOF
    fi

    chmod 600 "${WGH_CONF}"
    echo -e "  ${GR}[+]${CR} ${WGH_CONF} creado (chmod 600)."

    # Paso 6: Abrir firewall
    _wgh_open_firewall

    # Paso 7: Habilitar servicio systemd (sin arrancar aún — requiere peer registrado)
    systemctl enable "wg-quick@${WGH_IFACE}" &>/dev/null
    echo -e "  ${GR}[+]${CR} Servicio wg-quick@${WGH_IFACE} habilitado en systemd."

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+]${CR} ¡Instalación completada!"
    echo ""
    echo -e "  ${YL}[!]${CR} Pasos siguientes:"
    echo -e "  ${DM}  1. Anota la clave pública de la Droplet (opción 2 del menú).${CR}"
    echo -e "  ${DM}  2. Configura el PC doméstico con esa clave pública.${CR}"
    echo -e "  ${DM}  3. Registra la clave pública del PC (opción 3 del menú).${CR}"
    echo -e "  ${DM}  4. Activa el túnel (opción 4 del menú).${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 2. MOSTRAR CLAVE PÚBLICA DE LA DROPLET
# =========================================================
wghome_show_pubkey() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     CLAVE PÚBLICA DE LA DROPLET${CR}"
    echo -e "$SEP"

    if [ ! -f "${WGH_PUB_KEY}" ]; then
        echo -e "  ${RD}[-]${CR} No se encontró la clave pública."
        echo -e "  ${DM}    Instala el gateway primero (opción 1).${CR}"
        sleep 2
        return
    fi

    local PUB IP_PUB
    PUB=$(cat "${WGH_PUB_KEY}")
    IP_PUB=$(curl -4 -s ifconfig.me 2>/dev/null || echo "N/A")

    echo ""
    echo -e "  ${DM}IP pública Droplet :${CR} ${GR}${IP_PUB}${CR}"
    echo -e "  ${DM}Puerto WireGuard   :${CR} ${CY}${WGH_PORT}/UDP${CR}"
    echo ""
    echo -e "  ${YL}[ Clave Pública Droplet ]${CR}"
    echo -e "  ${WH}${PUB}${CR}"
    echo ""
    echo -e "  ${DM}━━━ Configuración para el PC doméstico ━━━${CR}"
    echo -e "  ${DM}Copia esto en el archivo WireGuard de tu PC (ej. /etc/wireguard/wg-home.conf):${CR}"
    echo ""
    echo -e "  ${CY}[Interface]${CR}"
    echo -e "  ${WH}PrivateKey          = <ClavePrivada_Del_PC>${CR}"
    echo -e "  ${WH}Address             = ${WGH_PEER_IP}/24${CR}"
    echo -e "  ${DM}# En Linux, para que el PC doméstico comparta su internet residencial:${CR}"
    echo -e "  ${DM}# PostUp = iptables -A FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o <interfaz_internet> -j MASQUERADE${CR}"
    echo -e "  ${DM}# PostDown = iptables -D FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o <interfaz_internet> -j MASQUERADE${CR}"
    echo ""
    echo -e "  ${CY}[Peer]${CR}"
    echo -e "  ${WH}PublicKey           = ${PUB}${CR}"
    echo -e "  ${WH}Endpoint            = ${IP_PUB}:${WGH_PORT}${CR}"
    echo -e "  ${WH}AllowedIPs          = ${WGH_DROPLET_IP}/32${CR}"
    echo -e "  ${WH}PersistentKeepalive = 25${CR}"
    echo ""
    echo -e "  ${YL}[!]${CR} La clave privada de la Droplet ${RD}NUNCA${CR} se muestra aquí."
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 3. REGISTRAR CLAVE PÚBLICA DEL PC DOMÉSTICO
# =========================================================
wghome_register_peer() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     REGISTRAR PC DOMÉSTICO (Peer)${CR}"
    echo -e "$SEP"

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} El gateway no está instalado. Usa la opción 1 primero."
        sleep 2
        return
    fi

    echo ""
    echo -e "  ${DM}Introduce la clave pública del PC doméstico.${CR}"
    echo -e "  ${DM}(Se obtiene en el PC con: wg pubkey < privatekey)${CR}"
    echo ""
    read -p "$(echo -e ${CY})PublicKey del PC: $(echo -e ${CR})" PEER_PUB

    if [ -z "$PEER_PUB" ]; then
        echo -e "  ${RD}[-]${CR} Clave vacía. Operación cancelada."
        sleep 1
        return
    fi

    # Validar formato básico de clave WireGuard (44 chars base64)
    if ! echo "$PEER_PUB" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
        echo -e "  ${YL}[!]${CR} El formato no parece una clave WireGuard válida (base64, 44 chars)."
        read -p "$(echo -e ${DM})¿Continuar de todas formas? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."
            sleep 1
            return
        fi
    fi

    # Guardar clave del peer
    echo "${PEER_PUB}" > /etc/wireguard/wghome_peer_public.key
    chmod 644 /etc/wireguard/wghome_peer_public.key

    # Reescribir wg-home.conf con el nuevo peer
    local PRIV
    PRIV=$(cat "${WGH_PRIV_KEY}")

    cat > "${WGH_CONF}" <<EOF
# =========================================================
# Gateway Residencial — Droplet (Servidor WireGuard)
# Interfaz : ${WGH_IFACE}
# Red VPN  : ${WGH_SUBNET}
# =========================================================

[Interface]
Address    = ${WGH_DROPLET_IP}/24
ListenPort = ${WGH_PORT}
PrivateKey = ${PRIV}

[Peer]
# PC doméstico en Colombia
PublicKey        = ${PEER_PUB}
AllowedIPs       = ${WGH_PEER_IP}/32
EOF

    chmod 600 "${WGH_CONF}"

    echo -e "  ${GR}[+]${CR} Clave del PC doméstico registrada."
    echo -e "  ${GR}[+]${CR} Configuración ${WGH_CONF} actualizada."

    # Si el túnel ya está activo, recargar en caliente
    if _wgh_is_up; then
        echo -e "  ${YL}[*]${CR} Recargando configuración WireGuard en caliente..."
        wg syncconf "${WGH_IFACE}" <(wg-quick strip "${WGH_IFACE}" 2>/dev/null) 2>/dev/null && \
            echo -e "  ${GR}[+]${CR} Configuración recargada sin interrumpir el túnel." || \
            echo -e "  ${YL}[!]${CR} Recarga manual: systemctl restart wg-quick@${WGH_IFACE}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 4. ACTIVAR TÚNEL
# =========================================================
wghome_tunnel_up() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     ACTIVAR TÚNEL WireGuard${CR}"
    echo -e "$SEP"

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} Gateway no instalado. Usa la opción 1."
        sleep 2; return
    fi

    if ! grep -q "^\[Peer\]" "${WGH_CONF}" 2>/dev/null; then
        echo -e "  ${RD}[-]${CR} No hay Peer registrado en ${WGH_CONF}."
        echo -e "  ${YL}[!]${CR} Usa la opción 3 para registrar la clave del PC doméstico."
        sleep 2; return
    fi

    if _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} ya está activo."
        sleep 1; return
    fi

    echo -e "  ${YL}[*]${CR} Verificando que SSH no se verá afectado..."
    _wgh_verify_ssh_route

    echo -e "  ${YL}[*]${CR} Levantando wg-quick@${WGH_IFACE}..."
    systemctl start "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 2

    if _wgh_is_up; then
        echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} activo."
        echo ""
        echo -e "  ${DM}Interfaz:${CR}"
        ip addr show "${WGH_IFACE}" 2>/dev/null | grep -E "inet|link" | sed 's/^/    /'
        echo ""
        # Verificación de seguridad post-activación
        echo -e "  ${YL}[*]${CR} Verificando tabla main (SSH debe seguir intacto)..."
        local def_route
        def_route=$(ip route show table main | grep '^default' | head -1)
        echo -e "  ${DM}Ruta por defecto tabla main:${CR} ${WH}${def_route}${CR}"
        if echo "$def_route" | grep -q "wg-home"; then
            echo -e "  ${RD}[!]${CR} ADVERTENCIA: La ruta por defecto usa wg-home. SSH puede verse afectado."
        else
            echo -e "  ${GR}[+]${CR} Ruta por defecto correcta — SSH protegido."
        fi
    else
        echo -e "  ${RD}[-]${CR} Error al levantar el túnel. Revisa: journalctl -u wg-quick@${WGH_IFACE} -n 20"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 5. DESACTIVAR TÚNEL
# =========================================================
wghome_tunnel_down() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DESACTIVAR TÚNEL WireGuard${CR}"
    echo -e "$SEP"

    if ! _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} ya está inactivo."
        sleep 1; return
    fi

    # Si la salida residencial está activa, desactivarla primero para
    # no dejar reglas huérfanas que rompan el routing
    if _wgh_routing_is_active; then
        echo -e "  ${YL}[*]${CR} La salida residencial está activa. Desactivándola primero..."
        _wgh_routing_off_internal
    fi

    echo -e "  ${YL}[*]${CR} Bajando wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 1

    if ! _wgh_is_up; then
        echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} desactivado."
        # Verificar que SSH sigue bien
        _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — ruta por defecto intacta."
    else
        echo -e "  ${RD}[-]${CR} Error al detener el túnel."
    fi

    sleep 1
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 6. ESTADO DEL TÚNEL
# =========================================================
wghome_status() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     ESTADO DEL TÚNEL — ${WGH_IFACE}${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} Gateway no instalado."
        echo ""
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"; return
    fi

    # Estado del servicio systemd
    local svc_status
    svc_status=$(systemctl is-active "wg-quick@${WGH_IFACE}" 2>/dev/null)
    if [ "$svc_status" = "active" ]; then
        echo -e "  ${DM}Servicio systemd :${CR} ${GR}ACTIVO${CR}"
    else
        echo -e "  ${DM}Servicio systemd :${CR} ${RD}INACTIVO${CR}"
    fi

    # Estado de interfaz de red
    if _wgh_is_up; then
        echo -e "  ${DM}Interfaz ${WGH_IFACE}:${CR} ${GR}UP${CR}"
    else
        echo -e "  ${DM}Interfaz ${WGH_IFACE}:${CR} ${RD}DOWN${CR}"
    fi

    # Estado WireGuard
    echo ""
    echo -e "  ${YL}[ wg show ${WGH_IFACE} ]${CR}"
    if _wgh_is_up; then
        wg show "${WGH_IFACE}" 2>/dev/null | sed 's/^/    /'
    else
        echo -e "  ${DM}  (túnel inactivo)${CR}"
    fi

    # Dirección IP de la interfaz
    echo ""
    echo -e "  ${YL}[ ip addr show ${WGH_IFACE} ]${CR}"
    ip addr show "${WGH_IFACE}" 2>/dev/null | sed 's/^/    /' || echo -e "  ${DM}  (interfaz no existe)${CR}"

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 7. PROBAR CONECTIVIDAD CON PC DOMÉSTICO
# =========================================================
wghome_ping_peer() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     PROBAR CONECTIVIDAD — PC Doméstico${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_is_up; then
        echo -e "  ${RD}[-]${CR} El túnel ${WGH_IFACE} no está activo."
        echo -e "  ${YL}[!]${CR} Activa el túnel primero (opción 4)."
        sleep 2; return
    fi

    echo -e "  ${YL}[*]${CR} Haciendo ping a ${WGH_PEER_IP} (PC doméstico)..."
    echo ""
    if ping -c 4 -W 3 "${WGH_PEER_IP}" 2>/dev/null; then
        echo ""
        echo -e "  ${GR}[+]${CR} PC doméstico alcanzable vía WireGuard."
        if _wgh_has_handshake; then
            echo -e "  ${GR}[+]${CR} Handshake WireGuard reciente (< 3 min) — túnel saludable."
        else
            echo -e "  ${YL}[!]${CR} Handshake no reciente. El PC doméstico puede estar inactivo."
        fi
    else
        echo ""
        echo -e "  ${RD}[-]${CR} No se pudo alcanzar el PC doméstico."
        echo -e "  ${DM}  Causas posibles:${CR}"
        echo -e "  ${DM}  • El PC doméstico no está conectado a WireGuard.${CR}"
        echo -e "  ${DM}  • La clave pública del PC no está registrada.${CR}"
        echo -e "  ${DM}  • El PC doméstico no tiene PersistentKeepalive = 25.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# FUNCIÓN INTERNA: Desactivar salida residencial
# (llamada también desde wghome_tunnel_down para limpiar)
# =========================================================
_wgh_routing_off_internal() {
    # Guardar estado actual antes de modificar
    {
        echo "=== Backup tomado: $(date) ==="
        echo "--- ip rule show ---"
        ip rule show
        echo "--- ip route show table ${WGH_RT_TABLE} ---"
        ip route show table "${WGH_RT_TABLE}" 2>/dev/null
    } > "${WGH_RT_BACKUP}" 2>/dev/null

    # Eliminar reglas que apunten a la tabla homevpn
    while ip rule show | grep -q "lookup ${WGH_RT_NAME}\|lookup ${WGH_RT_TABLE}"; do
        ip rule del table "${WGH_RT_TABLE}" 2>/dev/null || break
    done

    # Vaciar tabla de rutas homevpn
    ip route flush table "${WGH_RT_TABLE}" 2>/dev/null || true

    # Eliminar reglas iptables asociadas a wg-home
    while iptables -t nat -D POSTROUTING -o "${WGH_IFACE}" -m comment --comment "wghome-nat" -j MASQUERADE 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o "${WGH_IFACE}" -j MASQUERADE 2>/dev/null; do :; done
    while iptables -D FORWARD -o "${WGH_IFACE}" -m comment --comment "wghome-fwd" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o "${WGH_IFACE}" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "wghome-fwd-in" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -m comment --comment "wghome-mangle" -j MARK --set-mark 0x77 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -p tcp --sport 22 -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null; do :; done
    local SSH_P="${PORT_SSH:-22}"
    [ "$SSH_P" != "22" ] && while iptables -t mangle -D OUTPUT -p tcp --sport "$SSH_P" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -p udp --dport "${WGH_PORT}" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -d "${WGH_SUBNET}" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -d 127.0.0.0/8 -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null; do :; done

    # Verificar que la tabla main está intacta
    _wgh_verify_ssh_route
}

# =========================================================
# 8. ACTIVAR SALIDA RESIDENCIAL
# =========================================================
wghome_routing_on() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     ACTIVAR SALIDA RESIDENCIAL${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} Gateway no instalado. Usa la opción 1 primero."
        sleep 2; return
    fi

    if ! _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} no está activo."
        read -p "$(echo -e ${DM})¿Deseas activar el túnel ahora? (s/n) [s]: $(echo -e ${CR})" autoup
        autoup=${autoup:-s}
        if [[ "$autoup" == "s" || "$autoup" == "S" ]]; then
            echo -e "  ${YL}[*]${CR} Levantando túnel wg-quick@${WGH_IFACE}..."
            systemctl start "wg-quick@${WGH_IFACE}" 2>/dev/null
            sleep 2
            if ! _wgh_is_up; then
                echo -e "  ${RD}[-]${CR} Error al iniciar el túnel. Revisa la opción 4 y 6."
                sleep 2; return
            fi
            echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} activo."
        else
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    if _wgh_routing_is_active; then
        echo -e "  ${YL}[!]${CR} La salida residencial ya está activa."
        echo ""
        echo -e "  ${DM}Reglas actuales (ip rule show):${CR}"
        ip rule show | grep -E "homevpn|${WGH_RT_TABLE}" | sed 's/^/    /'
        echo ""
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"; return
    fi

    echo -e "  ${YL}[!]${CR} Verificaciones de seguridad pre-activación..."
    echo ""

    # 1. Verificar que SSH no está en riesgo
    _wgh_verify_ssh_route || {
        echo -e "  ${RD}[!]${CR} Abortando por seguridad SSH."
        sleep 3; return
    }

    # 2. Verificar si el túnel tiene handshake (PC doméstico conectado)
    if ! _wgh_has_handshake; then
        echo -e "  ${YL}[!]${CR} ADVERTENCIA: No se detecta handshake reciente en WireGuard."
        echo -e "  ${YL}[!]${CR} El PC doméstico puede no estar conectado o sincronizado aún."
        echo ""
        read -p "$(echo -e ${DM})¿Activar la salida de todas formas? (s/n) [s]: $(echo -e ${CR})" resp
        resp=${resp:-s}
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    # 3. Guardar estado actual
    {
        echo "=== Backup pre-activación: $(date) ==="
        echo "--- ip rule show ---"
        ip rule show
        echo "--- ip route show table main ---"
        ip route show table main
        echo "--- ip route show table ${WGH_RT_TABLE} ---"
        ip route show table "${WGH_RT_TABLE}" 2>/dev/null
    } > "${WGH_RT_BACKUP}"
    echo -e "  ${GR}[+]${CR} Estado actual guardado en ${WGH_RT_BACKUP}"

    # 4. Registrar tabla si no existe
    _wgh_ensure_rt_table

    # 5. Asegurar IP Forwarding
    _wgh_enable_forwarding

    # 6. Añadir ruta por defecto en tabla homevpn (apunta al PC doméstico)
    echo -e "  ${YL}[*]${CR} Añadiendo ruta en tabla ${WGH_RT_NAME} (${WGH_RT_TABLE})..."
    ip route replace default via "${WGH_PEER_IP}" dev "${WGH_IFACE}" table "${WGH_RT_TABLE}" 2>/dev/null
    echo -e "  ${GR}[+]${CR} Ruta: default via ${WGH_PEER_IP} dev ${WGH_IFACE} table ${WGH_RT_NAME}"

    # 7. Selección del modo de salida residencial
    echo ""
    echo -e "  ${CY}━━━ Modo de Salida Residencial ━━━${CR}"
    echo -e "  ${CY}1)${CR} ${WH}Usuarios VPN y Túneles${CR} ${GR}[Recomendado]${CR}"
    echo -e "     ${DM}Enruta usuarios SSH/HTTP Injector (UID 1000+) y VPNs.${CR}"
    echo -e "     ${DM}SSH administrativo de root permanece por la IP de la VPS.${CR}"
    echo -e "  ${CY}2)${CR} ${WH}Modo Global (Todo el VPS excepto SSH de admin)${CR}"
    echo -e "     ${DM}Enruta todo el tráfico saliente del servidor por el PC doméstico.${CR}"
    echo ""
    read -p "$(echo -e ${DM})Elige una opción [1-2] (Defecto: 1): $(echo -e ${CR})" mode_rt
    mode_rt=${mode_rt:-1}

    echo ""
    echo -e "  ${YL}[*]${CR} Aplicando reglas de enrutamiento (Policy Routing)..."

    # Regla base: tráfico originado desde la IP local de wg-home (10.77.77.1)
    if ! ip rule show | grep -q "from ${WGH_DROPLET_IP} lookup"; then
        ip rule add from "${WGH_DROPLET_IP}" table "${WGH_RT_TABLE}" priority 1000 2>/dev/null || true
    fi

    # Regla base: tráfico con marca fwmark 0x77
    if ! ip rule show | grep -q "fwmark 0x77 lookup"; then
        ip rule add fwmark 0x77 table "${WGH_RT_TABLE}" priority 1001 2>/dev/null || true
    fi

    if [ "$mode_rt" = "2" ]; then
        echo -e "  ${YL}[*]${CR} Configurando marcado de paquetes global..."
        local SSH_P="22"
        [ -n "$PORT_SSH" ] && SSH_P="$PORT_SSH"

        iptables -t mangle -C OUTPUT -p tcp --sport "$SSH_P" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null || \
            iptables -t mangle -A OUTPUT -p tcp --sport "$SSH_P" -m comment --comment "wghome-mangle" -j RETURN
        [ "$SSH_P" != "22" ] && {
            iptables -t mangle -C OUTPUT -p tcp --sport 22 -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null || \
                iptables -t mangle -A OUTPUT -p tcp --sport 22 -m comment --comment "wghome-mangle" -j RETURN
        }
        iptables -t mangle -C OUTPUT -p udp --dport "${WGH_PORT}" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null || \
            iptables -t mangle -A OUTPUT -p udp --dport "${WGH_PORT}" -m comment --comment "wghome-mangle" -j RETURN
        iptables -t mangle -C OUTPUT -d "${WGH_SUBNET}" -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d "${WGH_SUBNET}" -m comment --comment "wghome-mangle" -j RETURN
        iptables -t mangle -C OUTPUT -d 127.0.0.0/8 -m comment --comment "wghome-mangle" -j RETURN 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d 127.0.0.0/8 -m comment --comment "wghome-mangle" -j RETURN
        iptables -t mangle -C OUTPUT -m comment --comment "wghome-mangle" -j MARK --set-mark 0x77 2>/dev/null || \
            iptables -t mangle -A OUTPUT -m comment --comment "wghome-mangle" -j MARK --set-mark 0x77

        echo -e "  ${GR}[+]${CR} Modo Global activo (SSH protegido en puerto $SSH_P y 22)."
    else
        # Modo Usuarios VPN (UID 1000+)
        if ! ip rule show | grep -q "uidrange 1000-65535 lookup"; then
            ip rule add uidrange 1000-65535 table "${WGH_RT_TABLE}" priority 1002 2>/dev/null || true
            echo -e "  ${GR}[+]${CR} Regla aplicada: usuarios VPN (UID 1000-65535)."
        fi

        # Clientes WireGuard (wg0)
        if ip link show wg0 &>/dev/null; then
            if ! ip rule show | grep -q "iif wg0 lookup"; then
                ip rule add iif wg0 table "${WGH_RT_TABLE}" priority 1003 2>/dev/null || true
                echo -e "  ${GR}[+]${CR} Regla aplicada: clientes WireGuard (wg0)."
            fi
        fi

        # Clientes OpenVPN (tun0)
        if ip link show tun0 &>/dev/null; then
            if ! ip rule show | grep -q "iif tun0 lookup"; then
                ip rule add iif tun0 table "${WGH_RT_TABLE}" priority 1004 2>/dev/null || true
                echo -e "  ${GR}[+]${CR} Regla aplicada: clientes OpenVPN (tun0)."
            fi
        fi
    fi

    # Reglas NAT / Forwarding en iptables para la interfaz wg-home
    echo -e "  ${YL}[*]${CR} Configurando NAT / Forwarding en iptables..."
    iptables -t nat -C POSTROUTING -o "${WGH_IFACE}" -m comment --comment "wghome-nat" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "${WGH_IFACE}" -m comment --comment "wghome-nat" -j MASQUERADE
    iptables -C FORWARD -o "${WGH_IFACE}" -m comment --comment "wghome-fwd" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -o "${WGH_IFACE}" -m comment --comment "wghome-fwd" -j ACCEPT
    iptables -C FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "wghome-fwd-in" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "wghome-fwd-in" -j ACCEPT
    echo -e "  ${GR}[+]${CR} Reenvío y NAT activos en interfaz ${WGH_IFACE}."

    # 8. Verificación final de seguridad SSH
    echo ""
    echo -e "  ${YL}[*]${CR} Verificación final de SSH..."
    _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — tabla main intacta."

    echo ""
    if _wgh_routing_is_active; then
        echo -e "  ${GR}━━━ [✓] SALIDA RESIDENCIAL ACTIVADA CON ÉXITO ━━━${CR}"
        echo -e "  ${DM}El tráfico seleccionado sale a Internet vía PC Doméstico.${CR}"
        echo -e "  ${DM}Puedes comprobar la IP en la opción 10 del menú.${CR}"
    else
        echo -e "  ${RD}[-] Error: No se pudo verificar la activación de las reglas.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 9. DESACTIVAR SALIDA RESIDENCIAL
# =========================================================
wghome_routing_off() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DESACTIVAR SALIDA RESIDENCIAL${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_routing_is_active; then
        echo -e "  ${YL}[!]${CR} La salida residencial no está activa."
        sleep 1; return
    fi

    echo -e "  ${YL}[*]${CR} Desactivando salida residencial de forma segura..."
    _wgh_routing_off_internal

    echo -e "  ${GR}[+]${CR} Reglas de tabla ${WGH_RT_NAME} eliminadas."
    echo -e "  ${GR}[+]${CR} Reglas iptables asociadas eliminadas."
    echo -e "  ${GR}[+]${CR} Tabla main intacta — SSH seguro."
    echo ""
    echo -e "  ${DM}Backup del estado previo guardado en: ${WGH_RT_BACKUP}${CR}"

    sleep 1
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 10. VER IP DE SALIDA
# =========================================================
wghome_check_ip() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     VERIFICAR IP DE SALIDA${CR}"
    echo -e "$SEP"
    echo ""

    echo -e "  ${YL}[*]${CR} Obteniendo IP pública normal de la Droplet..."
    local IP_NORMAL
    IP_NORMAL=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  ${DM}IP Droplet (tabla main) :${CR} ${GR}${IP_NORMAL}${CR}"
    echo ""

    if _wgh_is_up && _wgh_routing_is_active; then
        echo -e "  ${YL}[*]${CR} Obteniendo IP residencial vía gateway doméstico..."
        local IP_RESIDENCIAL_CHECK
        IP_RESIDENCIAL_CHECK=$(curl -4 -s --max-time 8 --interface "${WGH_IFACE}" https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 8 --interface "${WGH_IFACE}" https://ifconfig.me 2>/dev/null || echo "N/A")
        echo -e "  ${DM}IP Residencial (wg-home):${CR} ${CY}${IP_RESIDENCIAL_CHECK}${CR}"
        echo ""
        if [ "$IP_NORMAL" != "$IP_RESIDENCIAL_CHECK" ] && [ "$IP_RESIDENCIAL_CHECK" != "N/A" ]; then
            echo -e "  ${GR}[+] ¡Gateway residencial funcionando correctamente!${CR}"
            echo -e "  ${DM}    La IP residencial es diferente a la de la VPS.${CR}"
        elif [ "$IP_RESIDENCIAL_CHECK" = "N/A" ]; then
            echo -e "  ${YL}[!] Sin respuesta por ${WGH_IFACE}.${CR}"
            echo -e "  ${DM}    Verifica que el PC doméstico esté encendido y tenga NAT/masquerade activo.${CR}"
            echo -e "  ${DM}    Prueba hacer ping al PC doméstico con la opción 7.${CR}"
        else
            echo -e "  ${YL}[!] Misma IP o tráfico saliendo por la VPS.${CR}"
            echo -e "  ${DM}    Verifica las reglas con la opción 11 (Diagnóstico).${CR}"
        fi
    elif _wgh_is_up && ! _wgh_routing_is_active; then
        echo -e "  ${YL}[!]${CR} Túnel activo pero salida residencial desactivada."
        echo -e "  ${DM}  Usa la opción 8 para activar la salida residencial.${CR}"
    else
        echo -e "  ${YL}[!]${CR} Túnel inactivo — IP residencial no disponible."
        echo -e "  ${DM}  Activa el túnel con la opción 4.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 11. ELIMINAR CONFIGURACIÓN COMPLETA
# =========================================================
wghome_remove() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${RD}     ⚠   ELIMINAR GATEWAY RESIDENCIAL   ⚠${CR}"
    echo -e "$SEP"
    echo ""
    echo -e "  ${YL}[!]${CR} Esta acción eliminará:"
    echo -e "  ${DM}  • /etc/wireguard/wg-home.conf${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_private.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_public.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_peer_public.key${CR}"
    echo -e "  ${DM}  • Servicio wg-quick@wg-home${CR}"
    echo -e "  ${DM}  • Reglas de tabla ${WGH_RT_NAME} (${WGH_RT_TABLE})${CR}"
    echo -e "  ${DM}  • Entrada en /etc/iproute2/rt_tables${CR}"
    echo ""
    read -p "$(echo -e ${DM})¿Continuar? (s/n): $(echo -e ${CR})" resp
    if [[ "$resp" != "s" && "$resp" != "S" ]]; then
        echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
    fi

    read -p "$(echo -e ${RD})Escribe ELIMINAR para confirmar: $(echo -e ${CR})" confirm
    if [[ "$confirm" != "ELIMINAR" ]]; then
        echo -e "  ${RD}[-]${CR} Texto incorrecto. Cancelado."; sleep 2; return
    fi

    echo ""

    # 1. Desactivar salida residencial si está activa
    if _wgh_routing_is_active; then
        echo -e "  ${YL}[*]${CR} Eliminando reglas de policy routing..."
        _wgh_routing_off_internal
    fi

    # 2. Detener y deshabilitar servicio
    echo -e "  ${YL}[*]${CR} Deteniendo servicio wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    systemctl disable "wg-quick@${WGH_IFACE}" 2>/dev/null

    # 3. Eliminar archivos
    echo -e "  ${YL}[*]${CR} Eliminando archivos de configuración..."
    rm -f "${WGH_CONF}"
    rm -f "${WGH_PRIV_KEY}"
    rm -f "${WGH_PUB_KEY}"
    rm -f /etc/wireguard/wghome_peer_public.key
    rm -f "${WGH_RT_BACKUP}"

    # 4. Eliminar entrada de tabla de rutas
    echo -e "  ${YL}[*]${CR} Eliminando tabla ${WGH_RT_NAME} de rt_tables..."
    sed -i "/${WGH_RT_NAME}/d" /etc/iproute2/rt_tables 2>/dev/null

    # 5. Cerrar firewall (opcional)
    _wgh_close_firewall

    # 6. Verificación de seguridad final
    echo ""
    echo -e "  ${YL}[*]${CR} Verificación post-eliminación..."
    _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — tabla main intacta."

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+]${CR} Gateway residencial eliminado completamente."
    echo -e "$SEP"
    sleep 2
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# DIAGNÓSTICO COMPLETO
# =========================================================
wghome_diagnose() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DIAGNÓSTICO — Gateway Residencial${CR}"
    echo -e "$SEP"
    echo ""

    # ── Estado WireGuard ──────────────────────────────────
    echo -e "  ${YL}[ 1/7 ] Estado WireGuard${CR}"
    if _wgh_is_up; then
        echo -e "  ${GR}●${CR} Interfaz ${WGH_IFACE}: ${GR}UP${CR}"
        wg show "${WGH_IFACE}" 2>/dev/null | sed 's/^/    /'
    else
        echo -e "  ${RD}●${CR} Interfaz ${WGH_IFACE}: ${RD}DOWN${CR}"
    fi
    echo ""

    # ── Último handshake ─────────────────────────────────
    echo -e "  ${YL}[ 2/7 ] Último Handshake${CR}"
    if _wgh_is_up; then
        local hs_raw hs_ago
        hs_raw=$(wg show "${WGH_IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [ -n "$hs_raw" ] && [ "$hs_raw" != "0" ]; then
            local now diff
            now=$(date +%s)
            diff=$(( now - hs_raw ))
            echo -e "  ${DM}Hace ${diff} segundos ($(date -d "@${hs_raw}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${hs_raw}" 2>/dev/null))${CR}"
        else
            echo -e "  ${RD}Sin handshake registrado.${CR}"
        fi
    else
        echo -e "  ${DM}  (túnel inactivo)${CR}"
    fi
    echo ""

    # ── Transferencia RX/TX ──────────────────────────────
    echo -e "  ${YL}[ 3/7 ] Transferencia RX/TX${CR}"
    if _wgh_is_up; then
        wg show "${WGH_IFACE}" transfer 2>/dev/null | awk '{printf "  RX: %s bytes  TX: %s bytes\n", $2, $3}' | \
            sed "s/^/${WH}/;s/$/${CR}/" || echo -e "  ${DM}No hay datos de transferencia.${CR}"
    else
        echo -e "  ${DM}  (túnel inactivo)${CR}"
    fi
    echo ""

    # ── IP del PC WireGuard ──────────────────────────────
    echo -e "  ${YL}[ 4/7 ] PC Doméstico (WireGuard)${CR}"
    echo -e "  ${DM}IP esperada en VPN :${CR} ${WH}${WGH_PEER_IP}${CR}"
    if _wgh_is_up; then
        local peer_ep
        peer_ep=$(wg show "${WGH_IFACE}" endpoints 2>/dev/null | awk '{print $2}')
        if [ -n "$peer_ep" ]; then
            echo -e "  ${DM}Endpoint público   :${CR} ${CY}${peer_ep}${CR}"
        else
            echo -e "  ${DM}Endpoint público   :${CR} ${RD}No conectado aún${CR}"
        fi
    fi
    echo ""

    # ── Tabla de rutas utilizada ─────────────────────────
    echo -e "  ${YL}[ 5/7 ] Tabla de Rutas — ${WGH_RT_NAME} (${WGH_RT_TABLE})${CR}"
    local rt_out
    rt_out=$(ip route show table "${WGH_RT_TABLE}" 2>/dev/null)
    if [ -n "$rt_out" ]; then
        echo "$rt_out" | sed "s/^/  ${WH}/" | sed "s/$/${CR}/"
    else
        echo -e "  ${DM}  (tabla vacía — salida residencial inactiva)${CR}"
    fi
    echo ""

    # ── Reglas ip rule ───────────────────────────────────
    echo -e "  ${YL}[ 6/7 ] Reglas de Enrutamiento (ip rule show)${CR}"
    ip rule show | grep -E "homevpn|${WGH_RT_TABLE}|main|default" | head -20 | sed 's/^/    /'
    echo ""

    # ── IPs públicas ─────────────────────────────────────
    echo -e "  ${YL}[ 7/7 ] IPs Públicas${CR}"
    local IP_NORMAL
    IP_NORMAL=$(curl -4 -s --max-time 8 ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  ${DM}IP pública Droplet (tabla main) :${CR} ${GR}${IP_NORMAL}${CR}"

    if _wgh_is_up; then
        echo -e "  ${YL}[*]${CR} Consultando IP por interfaz ${WGH_IFACE}..."
        local IP_WGH
        IP_WGH=$(curl -4 -s --max-time 10 --interface "${WGH_IFACE}" ifconfig.me 2>/dev/null || echo "N/A")
        echo -e "  ${DM}IP vía wg-home (PC doméstico)   :${CR} ${CY}${IP_WGH}${CR}"
        if [ "$IP_WGH" != "N/A" ] && [ "$IP_NORMAL" != "$IP_WGH" ]; then
            echo -e "  ${GR}[+]${CR} Gateway residencial funcionando correctamente."
        elif [ "$IP_WGH" = "N/A" ]; then
            echo -e "  ${YL}[!]${CR} Sin respuesta por wg-home — verifica NAT en el PC doméstico."
        fi
    else
        echo -e "  ${DM}IP vía wg-home                  :${CR} ${RD}(túnel inactivo)${CR}"
    fi

    echo ""
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# MENÚ PRINCIPAL DEL MÓDULO
# =========================================================
wghome_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        echo -e "$SEP"
        echo -e "${WH}     GATEWAY RESIDENCIAL — WireGuard${CR}"
        echo -e "$SEP"

        # Tags de estado
        local TAG_INST TAG_TUNNEL TAG_ROUTING
        if _wgh_is_installed; then
            TAG_INST="${GR}[INSTALADO]${CR}"
        else
            TAG_INST="${RD}[NO INSTALADO]${CR}"
        fi

        if _wgh_is_up; then
            TAG_TUNNEL="${GR}[ ON  ]${CR}"
        else
            TAG_TUNNEL="${RD}[ OFF ]${CR}"
        fi

        if _wgh_routing_is_active; then
            TAG_ROUTING="${GR}[ ON  ]${CR}"
        else
            TAG_ROUTING="${RD}[ OFF ]${CR}"
        fi

        echo -e "  ${DM}Instalación   :${CR}  $TAG_INST"
        echo -e "  ${DM}Túnel wg-home :${CR}  $TAG_TUNNEL"
        echo -e "  ${DM}Salida Resid. :${CR}  $TAG_ROUTING"
        echo -e "$SEP"
        echo -e "  ${CY} 1)${CR}  ${WH}Instalar / Configurar Gateway${CR}"
        echo -e "  ${CY} 2)${CR}  ${WH}Mostrar clave pública de la Droplet${CR}"
        echo -e "  ${CY} 3)${CR}  ${WH}Registrar clave pública del PC doméstico${CR}"
        echo -e "  ${CY} 4)${CR}  ${WH}Activar túnel${CR}                  $TAG_TUNNEL"
        echo -e "  ${CY} 5)${CR}  ${WH}Desactivar túnel${CR}"
        echo -e "  ${CY} 6)${CR}  ${WH}Estado del túnel${CR}"
        echo -e "  ${CY} 7)${CR}  ${WH}Probar conectividad con PC doméstico${CR}"
        echo -e "  ${CY} 8)${CR}  ${WH}Activar salida residencial${CR}      $TAG_ROUTING"
        echo -e "  ${CY} 9)${CR}  ${WH}Desactivar salida residencial${CR}"
        echo -e "  ${CY}10)${CR}  ${WH}Ver IP de salida${CR}"
        echo -e "  ${CY}11)${CR}  ${WH}Diagnóstico completo${CR}"
        echo -e "  ${CY}12)${CR}  ${RD}⚠  Eliminar configuración${CR}"
        echo -e "  ${CY} 0)${CR}  ${WH}Volver${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige [0-12]: $(echo -e ${CR})" op

        case $op in
             1) wghome_install ;;
             2) wghome_show_pubkey ;;
             3) wghome_register_peer ;;
             4) wghome_tunnel_up ;;
             5) wghome_tunnel_down ;;
             6) wghome_status ;;
             7) wghome_ping_peer ;;
             8) wghome_routing_on ;;
             9) wghome_routing_off ;;
            10) wghome_check_ip ;;
            11) wghome_diagnose ;;
            12) wghome_remove ;;
             0) break ;;
             *) echo -e "  ${RD}[-]${CR} Opción no válida."; sleep 1 ;;
        esac
    done
}
