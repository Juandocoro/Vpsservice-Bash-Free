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

  ── CUENTAS ──
  [1] ▸ CREAR CUENTA            │ usuario nuevo
  [2] ▸ RENOVAR CUENTA          │ sumar días
  [3] ▸ CUENTAS                 │ ficha · editar · borrar
  [4] ▸ CONECTADOS AHORA        │ monitor
  ── SERVIDOR ──
  [5] ▸ PROTOCOLOS              │ instalar · datos
  [6] ▸ IP RESIDENCIAL          │ nodos · móvil beta  [ ON  ]
  [7] ▸ SISTEMA                 │ ssh · firewall · hora
  [8] ▸ PANEL                   │ actualizar · registro

  [0] ▸ SALIR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Digita una acción [0-8] »
```

El menú tiene dos bloques: **cuentas**, lo de todos los días, y **servidor**,
donde cada opción agrupa un tema completo. Debajo del
tablero, una línea de **alertas** avisa de lo que puede dejar a un cliente sin
servicio: un protocolo instalado que está caído, un nodo residencial caído, el
vigilante detenido o cuentas que vencen hoy.

Al **crear una cuenta** el panel pide nombre, contraseña (Enter genera una),
días (30 por defecto) y dispositivos (1 por defecto), y pregunta **por dónde va
a salir a Internet**: la IP del VPS o uno de los nodos residenciales. Al
terminar muestra una ficha con todo lo que hay que mandarle al cliente.
**Renovar** suma los días a lo que le queda a la cuenta, no los cuenta desde hoy.

**Cuentas** muestra la tabla; se elige una (por número o nombre) y se abre su
**ficha**, desde donde se hace todo sin volver a buscarla: renovar, contraseña,
límite de dispositivos, salida a Internet, datos para el cliente, desconectar y
eliminar. Desde la lista también se pueden **limpiar las vencidas** de golpe.

```
── PROTOCOLOS ──        ── IP RESIDENCIAL ──     ── SISTEMA ──         ── PANEL ──
 11 protocolos           Nodos                    Acceso root           Actualizar
 Datos de conexión       Asignar usuarios         Puerto SSH            Registro de eventos
                         Salida residencial       Cortafuegos UFW       Arranque automático
                         Nunca sin Internet       Zona horaria          Desinstalar
                         Diagnóstico              Optimizar
                         Móvil sin root (beta)    Reiniciar servidor
                         Avanzado
```

En **Protocolos**, cada uno muestra `[ ON ]`, `[ OFF ]` (no instalado) o
`[CAIDO]` (instalado pero parado). **Panel → Registro de eventos** enseña lo que
el panel hizo solo: servicios reiniciados por el guardián, nodos caídos y
recuperados, y sesiones cortadas por superar el límite.

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

Todos los instaladores validan que el puerto esté libre, comprueban que el
servicio arrancó (y si no, enseñan su registro) y se pueden volver a ejecutar
sin romper lo que ya funciona.

| Protocolo | Cuentas | Notas |
|---|---|---|
| SSH, SSL, WebSocket, Dropbear | las del panel | |
| UDP Custom | las del panel (PAM) | formato `IP:1-65535@usuario:clave`; no toca el UDP de WireGuard, los nodos, OpenVPN ni SlowDNS |
| OpenVPN | las del panel (PAM) | un solo `.ovpn` para todos; caduca con la cuenta; reinstalar conserva la PKI |
| SlowDNS | las del panel | protocolo dnstt (el de las apps SlowDNS); necesita un dominio con registro NS |
| Squid | — | solo da paso hacia este VPS: no es un proxy abierto |
| WireGuard | clientes propios | cada uno con su `.conf` y código QR; reinstalar conserva las claves |
| V2Ray, Shadowsocks | propias | reinstalar V2Ray conserva los usuarios; Shadowsocks genera clave y enlace `ss://` |
| BadVPN | — | compilado desde el código oficial |

---

## Nodos de salida residencial

En **IP residencial** puedes hacer que ciertos
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

1. En el panel: **IP residencial → Nodos → Registrar nodo móvil**.
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

### Móvil sin root · BETA

**IP residencial → Móvil sin root** es la forma rápida de que un
celular Android **sin root** preste su IP a los usuarios que elijas. No hace
falta instalar el proyecto del nodo:

1. **Añadir celular**: el VPS crea el nodo, genera su llave (limitada con
   `permitlisten` a su propio puerto) y te pregunta qué usuarios saldrán por él.
2. Pega en **Termux** (de F-Droid) el bloque que te muestra el panel. Instala
   OpenSSH, deja un script que se reconecta solo y lo registra en Termux:Boot.
3. **Probar** comprueba la IP del celular, la que verá el cliente (IPv4 e IPv6)
   y, si quieres, la velocidad real.

Es posible, pero con límites que no dependen del código: solo TCP (web y apps;
el UDP sale por el VPS), la velocidad máxima es la **subida** del celular, cada
MB del cliente gasta 2 MB del plan, y Android puede dormir Termux si no se
sigue la **Guía Android** del menú. Pensado para pocos usuarios por celular.

### IPv6

Si el VPS tiene IPv6, a los usuarios que salen por un nodo se les rechaza el TCP
por IPv6: sin esto, `sshd` abría primero por IPv6 las conexiones a Google,
YouTube o Cloudflare y salían con la IP del VPS. Al rechazarlo, `sshd` usa al
instante la IPv4, que sí pasa por el nodo. El diagnóstico prueba las dos familias.

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
- Los respaldos se fijan en **IP residencial → Nunca sin Internet**.
- **IP residencial → Diagnóstico** recorre la cadena entera y dice en qué
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
