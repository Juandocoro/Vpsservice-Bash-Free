# VPSService Script - FREE

Panel de administración para servidores VPS en Ubuntu. Instala y configura protocolos de túnel, proxies y servicios VPN desde un menú interactivo en terminal.

---

## Instalación

```bash
bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh)
```

El instalador realiza lo siguiente:
- Clona el repositorio en `/opt/vpsservice-free`
- Asigna permisos de ejecución a todos los scripts
- Instala las dependencias base (curl, python3, stunnel4, dropbear)
- Registra el comando `menu` de forma global
- Activa el monitor de cuotas (auto-killer por cron)

Una vez instalado, abre el panel desde cualquier directorio del servidor:

```bash
menu
```

---

## El panel

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ►►►  V P S S E R V I C E  ◄◄◄       [ FREE · v1.0 · e6b47c7 ]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  OS: Ubuntu 22.04    ▸ ARCH: x86_64        ▸ CORES: 2
  IP: 216.238.77.196  ▸ HORA: 12:17:35      ▸ UPTIME: 3d 4h
────────────────────────────────────────────────────────────────
  ● RAM   ▰▰▰▱▱▱▱▱▱▱ 77Mi/976Mi     (8%)
  ● DISCO ▰▰▰▰▱▱▱▱▱▱ 3.2G/25G       (13%)
  ● CPU   ▰▱▱▱▱▱▱▱▱▱ 2 nucleo(s)    (4%)
────────────────────────────────────────────────────────────────
  CUENTAS  ▸ Activas: 3      ▸ Por vencer: 1     ▸ Vencidas: 0
  ONLINE   ▸ SSH: 2          ▸ Dropbear: 1       ▸ OpenVPN: 0
────────────────────────────────────────────────────────────────
  ▪ SSH: 22           ▸ ▪ Dropbear: 442     ▸ ▪ SSL: 443
  ▪ WebSocket: 80     ▸ ▪ BadVPN: 7300      ▸ ▪ V2Ray: 8080
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [1] ▸ ADMINISTRAR CUENTAS     │ crear · editar · monitor
  [2] ▸ CONFIGURACIÓN DEL VPS   │ protocolos · sistema

  [0] ▸ SALIR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Digita una acción [0-2] »
```

El menú principal solo tiene dos destinos: las cuentas, que es el uso diario,
y la configuración, que agrupa el resto en tres bloques —**protocolos**,
**sistema** y **panel**:

```
── PROTOCOLOS ──          ── SISTEMA ──             ── PANEL ──
 Fábrica de túneles        Acceso root               Actualizar script
 Datos de conexión         Puerto SSH                Arranque automático
 Gateway residencial       Cortafuegos UFW           Reiniciar servidor
                           Zona horaria              Desinstalar panel
                           Optimizar servidor
```

Todo el aspecto gráfico vive en un único módulo, `modules/ui.sh`: paleta,
marcos, celdas alineadas, barras de carga y etiquetas `[ ON ]` / `[ OFF ]`.
El resto de módulos e instaladores lo importan, así que cambiar un color o el
ancho del panel se hace en un solo sitio y afecta a todas las pantallas.

---

## Estructura

```
main.sh                     Panel principal y bucle de menús
setup.sh                    Instalador remoto (clona y configura el VPS)
modules/
  ui.sh                     Lenguaje visual compartido
  system.sh                 Acceso root, puerto SSH, zona horaria y config SSH
  network.sh                Tablero de estado, puertos y cortafuegos UFW
  users.sh                  Alta, baja y monitor de cuentas
  optimize.sh               Limpieza de RAM, swap, caché y logs
  killer.sh                 Auto-killer de cuotas (cron, cada minuto)
  installers/               Un script por protocolo (11 en total)
```

---

## Protocolos disponibles

| Categoría | Protocolos |
|---|---|
| SSH / Túnel | Stunnel SSL, WebSocket, Dropbear |
| UDP | UDP Custom (1-65535), BadVPN Gateway |
| Proxy | SlowDNS, Squid |
| VPN | V2Ray (VMess+WS), Shadowsocks, OpenVPN, WireGuard |

---

## Nodos de salida residencial

Bajo **Configuración del VPS → Gateway residencial** puedes hacer que ciertos
usuarios SSH salgan a Internet por la conexión de otro equipo tuyo (un nodo),
no por la IP del VPS. Cada usuario sale por el nodo que le asignes, y varios
nodos pueden dar salida a la vez. Hay dos tipos:

| Tipo | Equipo | Cómo se conecta | Tráfico |
|---|---|---|---|
| **PC (WireGuard)** | PC de escritorio/Linux | Túnel WireGuard, el nodo hace NAT | Todo (TCP y UDP) |
| **Móvil (SOCKS)** | Celular Android **sin root** | Túnel inverso `ssh -R` desde Termux | Solo TCP |

### Nodo móvil (celular sin root)

Un teléfono no puede actuar como salida WireGuard sin root, así que se usa un
**SOCKS inverso**: el móvil abre una conexión *saliente* al VPS (funciona tras
CGNAT, sin root) que deja un SOCKS5 en el VPS. El tráfico de los usuarios
asignados se redirige a ese SOCKS con `redsocks`.

```
Usuario SSH ─(marca por UID)─▶ redsocks ─▶ SOCKS5 local ─┐
                                                          │ ssh -R
                        Internet ◀── Celular (Termux) ◀───┘
```

Pasos:

1. En el panel: **Gateway residencial → Gestionar nodos → Registrar nodo móvil**.
   Anota la contraseña que genera y sigue las instrucciones en pantalla.
2. En el celular (Android, sin root): instala **Termux**, luego
   `pkg install openssh` y ejecuta el comando `ssh -N -R …` que muestra el panel
   (déjalo abierto).
3. Asigna usuarios a ese nodo en **Asignar usuarios** y enciende la salida
   residencial.

El usuario del nodo es una cuenta de sistema (uid&lt;1000) restringida a solo
reenvío inverso, así que no aparece en la lista de cuentas ni puede abrir una
shell. El DNS (UDP) sigue resolviéndose en el VPS; las conexiones TCP salen por
el celular.

---

## Requisitos

- Ubuntu 20.04 / 22.04 x86_64
- Acceso root
- VPS con puertos abiertos

---

## FREE vs BASIC

| Característica | FREE | BASIC |
|---|---|---|
| Clave de licencia | No requerida | Requerida |
| Validación externa | No | Sí |
| Protocolos | 11 | 3 |
| Auto-Killer | Sí | Sí |
| Actualizaciones OTA | Sí | Sí |

---

## Solución de problemas

Si el instalador no puede clonar el repositorio:

1. Confirma que el repo sea público: `https://github.com/Juandocoro/Vpsservice-Bash-Free`
2. Verifica que el servidor tenga acceso saliente a GitHub
3. Revisa los logs del instalador para más detalles

---

## Aviso legal

Este proyecto se distribuye con fines educativos y para la administración legítima de servidores VPS. El autor no se responsabiliza por el uso indebido de estas herramientas. El usuario es responsable de cumplir con las leyes y los términos de servicio de su país y proveedor de internet. Este software no contiene puertas traseras, registro de credenciales ni recolección de datos de ningún tipo.
