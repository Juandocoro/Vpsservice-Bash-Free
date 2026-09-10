#!/bin/bash
# =========================================================
# MODULO UI — Lenguaje visual compartido del panel
# ---------------------------------------------------------
# Todo el aspecto grafico del script vive aqui: paleta,
# separadores, celdas, etiquetas y cabeceras. Los modulos e
# instaladores hacen 'source' de este archivo para que el
# panel se vea igual en todas sus pantallas.
#
# Regla de oro para alinear: printf cuenta los codigos ANSI
# como caracteres, asi que el relleno SIEMPRE se calcula
# sobre el texto plano y el color se aplica despues.
# =========================================================

# Evitar recargas si ya fue importado
[ -n "${UI_LOADED:-}" ] && return 0
UI_LOADED=1

# El relleno de las columnas se calcula con ${#cadena}, que cuenta CARACTERES
# bajo un locale UTF-8 y BYTES bajo C/POSIX. Un VPS recien creado suele venir
# en POSIX, y ahi cada acento o simbolo de dibujo contaria doble y descuadraria
# la tabla entera. C.UTF-8 existe siempre en Debian/Ubuntu, asi que lo fijamos.
if ! locale charmap 2>/dev/null | grep -qi "utf-\?8"; then
    if locale -a 2>/dev/null | grep -qix "C.UTF-8"; then
        export LC_ALL=C.UTF-8 LANG=C.UTF-8
    elif locale -a 2>/dev/null | grep -qix "en_US.utf8"; then
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    fi
fi

# === PALETA ==============================================
CR="\033[0m"        # reset
BD="\033[1m"        # negrita
DM="\033[2;37m"     # tenue      — etiquetas, textos de apoyo
RD="\033[1;31m"     # rojo       — OFF, errores, peligro
GR="\033[1;32m"     # verde      — ON, exito
YL="\033[1;33m"     # amarillo   — marcos, avisos
BL="\033[1;34m"     # azul       — uso bajo
MG="\033[1;35m"     # magenta    — acentos del titulo
CY="\033[1;36m"     # cian       — numeros de opcion, puertos
WH="\033[1;37m"     # blanco     — valores, texto principal

# === GEOMETRIA ===========================================
UI_W=64             # ancho util del panel
UI_PAD="  "         # sangria izquierda

# =========================================================
# SEPARADORES
# =========================================================
# ui_line [color] [caracter]
ui_line() {
    local color="${1:-$YL}" ch="${2:-━}" out=""
    local i=0
    while [ $i -lt $UI_W ]; do out="${out}${ch}"; i=$((i+1)); done
    echo -e "${color}${out}${CR}"
}

ui_rule()  { ui_line "$DM" "─"; }   # divisor suave, dentro de un bloque
ui_solid() { ui_line "$YL" "━"; }   # divisor fuerte, entre bloques

ui_blank() { echo ""; }

# =========================================================
# TITULO PRINCIPAL
# ui_header <version>
# =========================================================
ui_header() {
    local ver="${1:-}"
    local name="V P S S E R V I C E"
    ui_solid
    printf "%b   %b►►►%b  %b%s%b  %b◄◄◄%b" "$CR" "$MG" "$CR" "$WH$BD" "$name" "$CR" "$MG" "$CR"
    if [ -n "$ver" ]; then
        # El relleno se calcula sobre el texto plano: 3 + 3 + 2 + len + 2 + 3
        local plain_len=$(( 3 + 3 + 2 + ${#name} + 2 + 3 ))
        local tag="[ $ver ]"
        local pad=$(( UI_W - plain_len - ${#tag} ))
        [ $pad -lt 1 ] && pad=1
        printf "%*s%b%s%b" "$pad" "" "$CY" "$tag" "$CR"
    fi
    echo ""
    ui_solid
}

# =========================================================
# CABECERA DE SECCION — para submenus e instaladores
# ui_section "TITULO" [subtitulo]
# =========================================================
ui_section() {
    local title="$1" sub="${2:-}"
    # Centrado sobre el texto plano
    local pad=$(( (UI_W - ${#title}) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "%*s%b%s%b\n" "$pad" "" "$WH$BD" "$title" "$CR"
    [ -n "$sub" ] && { pad=$(( (UI_W - ${#sub}) / 2 )); [ $pad -lt 0 ] && pad=0
                       printf "%*s%b%s%b\n" "$pad" "" "$DM" "$sub" "$CR"; }
    ui_solid
}

# =========================================================
# CELDAS Y FILAS DE DATOS
# ui_cell <etiqueta> <valor> [ancho] [color_valor]
# =========================================================
ui_cell() {
    local label="$1" value="${2:-N/A}" width="${3:-20}" vc="${4:-$WH}"
    local plain="${label}: ${value}"
    local pad=$(( width - ${#plain} ))
    [ $pad -lt 0 ] && pad=0
    printf "%b%s:%b %b%s%b%*s" "$DM" "$label" "$CR" "$vc" "$value" "$CR" "$pad" ""
}

# ui_row3 l1 v1 l2 v2 l3 v3  — tres celdas separadas por ▸
ui_row3() {
    local w=$(( (UI_W - 4) / 3 ))
    echo -e "${UI_PAD}$(ui_cell "$1" "$2" $w)${DM}▸${CR} $(ui_cell "$3" "$4" $w)${DM}▸${CR} $(ui_cell "$5" "$6" $w)"
}

# ui_row2 l1 v1 l2 v2  — dos celdas
ui_row2() {
    local w=$(( (UI_W - 2) / 2 ))
    echo -e "${UI_PAD}$(ui_cell "$1" "$2" $w)${DM}▸${CR} $(ui_cell "$3" "$4" $w)"
}

# =========================================================
# ETIQUETAS DE ESTADO
# =========================================================
ui_tag()     { [ -n "$1" ] && echo -e "${GR}[ ON  ]${CR}" || echo -e "${RD}[ OFF ]${CR}"; }
ui_tag_str() { [ "$1" = "on" ] && echo -e "${GR}[ ON  ]${CR}" || echo -e "${RD}[ OFF ]${CR}"; }

# Indicador de carga por porcentaje: azul <50 · verde 50-84 · rojo >=85
ui_dot() {
    local pct=${1:-0}
    if   [ "$pct" -ge 85 ]; then echo -e "${RD}●${CR}"
    elif [ "$pct" -ge 50 ]; then echo -e "${GR}●${CR}"
    else                         echo -e "${BL}●${CR}"
    fi
}

# Barra de progreso de 10 bloques
# ui_bar <pct>
ui_bar() {
    local pct=${1:-0} filled i out=""
    filled=$(( pct / 10 ))
    [ $filled -gt 10 ] && filled=10
    local color="$BL"
    [ "$pct" -ge 50 ] && color="$GR"
    [ "$pct" -ge 85 ] && color="$RD"
    for ((i=0;i<10;i++)); do
        if [ $i -lt $filled ]; then out="${out}▰"; else out="${out}▱"; fi
    done
    echo -e "${color}${out}${CR}"
}

# =========================================================
# OPCIONES DE MENU
# ui_opt <numero> <titulo> [detalle] [etiqueta_estado]
# =========================================================
ui_opt() {
    local num="$1" title="$2" detail="${3:-}" tag="${4:-}"
    local title_w=24 detail_w=19
    # '[10]' ocupa una columna mas que '[1]': se descuenta del relleno para que
    # todos los titulos arranquen en la misma columna.
    local pad=$(( title_w - ${#title} - ${#num} + 1 ))
    [ $pad -lt 1 ] && pad=1
    printf "${UI_PAD}${CY}[%s]${CR} ${DM}▸${CR} ${WH}%s${CR}%*s" "$num" "$title" "$pad" ""

    # La columna de detalle se imprime siempre, aunque vaya vacia: es lo que
    # mantiene las etiquetas [ON]/[OFF] alineadas entre todas las filas.
    if [ -n "$detail" ]; then
        printf "${DM}│ %s${CR}" "$detail"
        local dpad=$(( detail_w - ${#detail} - 2 ))
    else
        local dpad=$(( detail_w ))
    fi
    [ $dpad -lt 1 ] && dpad=1
    printf "%*s" "$dpad" ""

    [ -n "$tag" ] && printf "%b" "$tag"
    echo ""
}

# Opcion destacada en rojo (acciones destructivas)
ui_opt_danger() {
    local num="$1" title="$2" detail="${3:-}"
    local pad=$(( 24 - ${#title} - ${#num} + 1 ))
    [ $pad -lt 1 ] && pad=1
    printf "${UI_PAD}${CY}[%s]${CR} ${DM}▸${CR} ${RD}%s${CR}%*s" "$num" "$title" "$pad" ""
    [ -n "$detail" ] && printf "${RD}│ %s${CR}" "$detail"
    echo ""
}

# =========================================================
# MENSAJES
# =========================================================
ui_ok()   { echo -e "${UI_PAD}${GR}[+]${CR} $1"; }
ui_info() { echo -e "${UI_PAD}${YL}[*]${CR} $1"; }
ui_err()  { echo -e "${UI_PAD}${RD}[-]${CR} $1"; }
ui_warn() { echo -e "${UI_PAD}${YL}[!]${CR} $1"; }

# Prompt de entrada consistente
# ui_prompt "texto"  -> deja la respuesta en $REPLY_UI
ui_prompt() {
    read -p "$(echo -e "${UI_PAD}${DM}$1 ${CY}»${CR} ")" REPLY_UI
}

ui_pause() {
    echo ""
    read -p "$(echo -e "${UI_PAD}${DM}Presiona Enter para continuar...${CR}")"
}

# Alias cortos: varios instaladores ya usaban estos nombres con su propia
# paleta local. Al apuntarlos aqui, heredan el estilo del panel sin tocar
# el resto de su codigo.
_ok()   { ui_ok   "$1"; }
_info() { ui_info "$1"; }
_err()  { ui_err  "$1"; }
_warn() { ui_warn "$1"; }

# Compatibilidad con el codigo antiguo que usa $SEP
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
