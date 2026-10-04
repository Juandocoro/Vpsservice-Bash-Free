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
────────────────────────────────────────────────────────────────
  ✓ Todo funcionando
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [1] ▸ CREAR CUENTA            │ usuario nuevo
  [2] ▸ RENOVAR CUENTA          │ sumar días
  [3] ▸ CONECTADOS AHORA        │ monitor
  [4] ▸ DATOS DE CONEXIÓN       │ para el cliente

  [5] ▸ ADMINISTRAR CUENTAS     │ clave · salida · borrar
  [6] ▸ CONFIGURACIÓN           │ protocolos · sistema

  [0] ▸ SALIR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Digita una acción [0-6] »
```

Lo que se hace a diario está a un toque desde el menú principal. Debajo del
tablero, una línea de **alertas** avisa de lo que puede dejar a un cliente sin
servicio: un protocolo instalado que está caído, un nodo residencial caído, el
vigilante detenido o cuentas que vencen hoy.

Al **crear una cuenta** el panel pide nombre, contraseña (Enter genera una),
días (30 por defecto) y dispositivos (1 por defecto), y pregunta **por dónde va
a salir a Internet**: la IP del VPS o uno de los nodos residenciales. Al
terminar muestra una ficha con todo lo que hay que mandarle al cliente.
**Renovar** suma los días a lo que le queda a la cuenta, no los cuenta desde hoy.

La configuración agrupa el resto en tres bloques —**protocolos**, **sistema**
y **panel**:

```
── PROTOCOLOS ──          ── SISTEMA ──             ── PANEL ──
 Fábrica de túneles        Acceso root               Actualizar script
 Gateway residencial       Puerto SSH                Arranque automático
                           Cortafuegos UFW           Reiniciar servidor
                           Zona horaria              Desinstalar panel
                           Optimizar servidor
```

En la fábrica, cada protocolo muestra `[ ON ]`, `[ OFF ]` (no instalado) o
`[CAIDO]` (instalado pero parado).

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
  guardian.sh               Reinicia los servicios caídos (cron, cada minuto)
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

La autenticación es **por llave**, igual que un nodo WireGuard se registra
pegando su clave pública. El nodo (proyecto
[`Vpsservice-Node-Gateway`](../Vpsservice-Node-Gateway), modo SOCKS) genera su
par SSH y muestra su clave; el panel la autoriza.

1. En el panel: **Gateway residencial → Nodos → Registrar nodo móvil**.
   Reserva el nodo y te muestra los datos a configurar en el celular (host,
   puerto SSH, usuario `snodeN` y puerto SOCKS).
2. En el celular (Android, sin root): instala **Termux** y el nodo, ejecuta
   `nodo`, opción `[1]`, e introduce esos datos. El nodo genera su llave y
   muestra su **clave pública**.
3. Vuelve al panel a **Registrar nodo móvil** con el mismo nombre y **pega esa
   clave pública**. Luego asigna usuarios y enciende la salida residencial.

El usuario del nodo es una cuenta de sistema (uid&lt;1000) **sin contraseña**
(solo entra con su llave), restringida a solo reenvío remoto, así que no aparece
en la lista de cuentas ni puede abrir una shell. El DNS (UDP) sigue
resolviéndose en el VPS; las conexiones TCP salen por el celular.

---

### Que nadie se quede sin Internet

Al encender la salida residencial se activa también el **vigilante**
(`homevpn-watchdog`). Si un nodo deja de responder, sus usuarios pasan solos a
su nodo de **respaldo** (si se le ha fijado uno y está vivo) y, si no, a la IP
del VPS. Cuando el nodo vuelve, regresan a él.

```
nodo preferido  ->  nodo de respaldo  ->  IP del VPS
```

- Un nodo PC se da por caído en 20-60 s y un móvil en unos 30 s.
- La salida residencial se restaura sola si el VPS se reinicia
  (`homevpn-rules`).
- El guardián comprueba cada minuto que las reglas sigan puestas y que los
  servicios instalados estén vivos, y los levanta si no.
- Los respaldos se fijan en **Gateway residencial → Nunca sin Internet**.
- **Gateway residencial → Diagnóstico** recorre la cadena entera y dice en qué
  eslabón se corta.

---

## Protección del servicio

| Riesgo | Qué hace el panel |
|---|---|
| Se cae un protocolo (stunnel, WebSocket, Dropbear…) | El guardián lo reinicia en menos de un minuto y lo anota en `/var/log/vpsservice-guardian.log` |
| Un cliente supera su límite de dispositivos | El auto-killer cierra solo las sesiones que sobran, las más antiguas |
| Sesiones fantasma (el móvil perdió la señal) | `ClientAliveInterval` las cierra en unos 2 minutos |
| Un cambio rompe la configuración de SSH | Se valida con `sshd -t` antes de aplicarla y, si falla, se vuelve a la anterior |
| Se cambia el puerto SSH | El 22 sigue escuchando en local para que SSL y WebSocket no se caigan |
| Sincronizar el cortafuegos | Solo añade reglas: no borra las de los nodos ni las del admin |
| Optimización automática | Solo limpia disco: no vacía la swap ni la caché |
| Una actualización con errores | Se valida con `bash -n` antes de instalarla, y se puede volver a la versión anterior |

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
