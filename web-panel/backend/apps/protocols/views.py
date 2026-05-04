import subprocess
from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .models import Protocol
from .serializers import ProtocolSerializer

VPS_DIR = '/opt/vpsservice-free'

INSTALLER_MAP = {
    'stunnel':      'stunnel_installer.sh',
    'udp':          'udp_installer.sh',
    'badvpn':       'badvpn_installer.sh',
    'websocket':    'websocket_installer.sh',
    'dropbear':     'dropbear_installer.sh',
    'slowdns':      'slowdns_installer.sh',
    'squid':        'squid_installer.sh',
    'v2ray':        'v2ray_installer.sh',
    'shadowsocks':  'shadowsocks_installer.sh',
    'openvpn':      'openvpn_installer.sh',
    'wireguard':    'wireguard_installer.sh',
}

SERVICE_MAP = {
    'stunnel':      'stunnel4',
    'dropbear':     'dropbear',
    'squid':        'squid',
    'v2ray':        'v2ray',
    'shadowsocks':  'shadowsocks-libev',
    'openvpn':      'openvpn',
    'wireguard':    'wg-quick@wg0',
}


def run_cmd(cmd, input_text=None):
    try:
        result = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=120)
        return result.returncode == 0, result.stdout.strip() or result.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, 'Timeout'
    except Exception as e:
        return False, str(e)


def get_service_status(service_name):
    """Retorna True si el servicio está activo."""
    key = service_name.lower()
    systemd_name = SERVICE_MAP.get(key, key)
    ok, out = run_cmd(['systemctl', 'is-active', systemd_name])
    return out.strip() == 'active'


def get_service_port(service_name):
    """Extrae el puerto del servicio leyendo sus archivos de configuración."""
    key = service_name.lower()
    port = 0
    try:
        if key == 'stunnel':
            ok, out = run_cmd(['bash', '-c', "grep -i 'accept' /etc/stunnel/stunnel.conf 2>/dev/null | head -n 1 | awk '{print $3}' | grep -o '[0-9]*'"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'dropbear':
            ok, out = run_cmd(['bash', '-c', "grep 'DROPBEAR_PORT=' /etc/default/dropbear 2>/dev/null | cut -d= -f2"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'udp':
            ok, out = run_cmd(['bash', '-c', "grep '\"listen\"' /etc/udp-custom/config.json 2>/dev/null | grep -o '[0-9]*' | head -n 1"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'v2ray':
            ok, out = run_cmd(['python3', '-c', "import json; print(json.load(open('/usr/local/etc/v2ray/config.json'))['inbounds'][0]['port'])"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'badvpn':
            ok, out = run_cmd(['bash', '-c', "grep -o '\\-\\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}'"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'shadowsocks':
            ok, out = run_cmd(['bash', '-c', "grep '\"server_port\"' /etc/shadowsocks-libev/config.json 2>/dev/null | grep -o '[0-9]*' | head -n 1"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'openvpn':
            ok, out = run_cmd(['bash', '-c', "grep '^port ' /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}'"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'wireguard':
            ok, out = run_cmd(['bash', '-c', "grep '^ListenPort' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}'"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'slowdns':
            port = 53
        elif key == 'squid':
            ok, out = run_cmd(['bash', '-c', "grep '^http_port ' /etc/squid/squid.conf 2>/dev/null | awk '{print $2}'"])
            if ok and out.isdigit(): port = int(out)
        elif key == 'websocket':
            ok, out = run_cmd(['bash', '-c', "grep 'ExecStart=' /etc/systemd/system/ws-proxy.service 2>/dev/null | awk '{print $NF}'"])
            if ok and out.isdigit(): port = int(out)
    except Exception:
        pass
    return port


class ProtocolViewSet(viewsets.ModelViewSet):
    """
    API REST para gestionar protocolos del VPS.

    GET    /api/protocols/                   - Listar todos (con estado real)
    POST   /api/protocols/{id}/toggle/       - Iniciar/Detener servicio
    POST   /api/protocols/{id}/install/      - Ejecutar installer
    DELETE /api/protocols/{id}/              - Desinstalar y eliminar
    GET    /api/protocols/{id}/logs/         - Ver ultimas lineas de log
    """

    queryset = Protocol.objects.all()
    serializer_class = ProtocolSerializer
    permission_classes = [IsAuthenticated]
    filterset_fields = ['name', 'is_installed', 'is_active', 'protocol_type']
    search_fields = ['name', 'description']
    ordering_fields = ['name', 'port', 'created_date']
    ordering = ['name']

    def list(self, request, *args, **kwargs):
        """Lista protocolos y actualiza el estado real de cada servicio."""
        protocols = Protocol.objects.all()
        for p in protocols:
            needs_update = False
            
            # Actualizar estado activo
            real_active = get_service_status(p.name)
            if p.is_active != real_active:
                p.is_active = real_active
                needs_update = True
                
            # Actualizar puerto dinámicamente si está instalado
            if p.is_installed:
                real_port = get_service_port(p.name)
                if real_port > 0 and p.port != real_port:
                    p.port = real_port
                    needs_update = True
                    
            if needs_update:
                p.save(update_fields=['is_active', 'port'])
                
        return super().list(request, *args, **kwargs)

    def destroy(self, request, *args, **kwargs):
        """Detiene y deshabilita el servicio antes de eliminarlo."""
        protocol = self.get_object()
        key = protocol.name.lower()
        systemd_name = SERVICE_MAP.get(key, key)
        
        # Detener servicio
        run_cmd(['systemctl', 'stop', systemd_name])
        run_cmd(['systemctl', 'disable', systemd_name])
        
        return super().destroy(request, *args, **kwargs)

    # ===== TOGGLE: Iniciar / Detener servicio =====
    @action(detail=True, methods=['post'])
    def toggle(self, request, pk=None):
        protocol = self.get_object()
        key = protocol.name.lower()
        systemd_name = SERVICE_MAP.get(key, key)

        if protocol.is_active:
            ok, msg = run_cmd(['systemctl', 'stop', systemd_name])
            if ok:
                protocol.is_active = False
                protocol.save()
        else:
            ok, msg = run_cmd(['systemctl', 'start', systemd_name])
            if ok:
                protocol.is_active = True
                protocol.save()

        if not ok:
            return Response({'error': msg}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        return Response(ProtocolSerializer(protocol).data)

    # ===== RESTART: Reiniciar servicio =====
    @action(detail=True, methods=['post'])
    def restart(self, request, pk=None):
        protocol = self.get_object()
        key = protocol.name.lower()
        systemd_name = SERVICE_MAP.get(key, key)

        ok, msg = run_cmd(['systemctl', 'restart', systemd_name])
        if ok:
            protocol.is_active = True
            protocol.save()
            return Response({'success': True, 'msg': msg})
        
        return Response({'error': msg}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    # ===== INSTALL: Ejecutar script de instalación =====
    @action(detail=True, methods=['post'])
    def install(self, request, pk=None):
        protocol = self.get_object()
        key = protocol.name.lower()
        installer = INSTALLER_MAP.get(key)

        if not installer:
            return Response(
                {'error': f'No hay installer para: {protocol.name}'},
                status=status.HTTP_400_BAD_REQUEST
            )

        script_path = f'{VPS_DIR}/modules/installers/{installer}'
        
        # Matar cualquier ttyd viejo corriendo en el puerto 8080
        subprocess.run(['fuser', '-k', '8080/tcp'], capture_output=True)
        
        # Lanzar ttyd en background con variable de entorno WEB_PANEL=1.
        # -O: Una vez que el cliente se desconecte, ttyd se cierra.
        try:
            subprocess.Popen(
                ['ttyd', '-O', '-p', '8080', 'env', 'WEB_PANEL=1', 'bash', script_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        # Devolvemos URL del terminal (el Nginx lo proxea a 8080)
        return Response({
            'success': True,
            'terminal_url': '/terminal/',
            'protocol': ProtocolSerializer(protocol).data
        })

    # ===== TERMINAL STATUS: Verificar si el terminal sigue activo =====
    @action(detail=False, methods=['get'])
    def terminal_status(self, request):
        # fuser 8080/tcp devuelve código 0 si alguien escucha ahí
        result = subprocess.run(['fuser', '8080/tcp'], capture_output=True)
        return Response({'is_running': result.returncode == 0})

    # ===== LOGS: Últimas líneas del log del servicio =====
    @action(detail=True, methods=['get'])
    def logs(self, request, pk=None):
        protocol = self.get_object()
        key = protocol.name.lower()
        systemd_name = SERVICE_MAP.get(key, key)
        lines = request.query_params.get('lines', '50')

        ok, output = run_cmd([
            'journalctl', '-u', systemd_name,
            '-n', str(lines), '--no-pager', '--output=short'
        ])

        return Response({
            'service': systemd_name,
            'lines': output if ok else f'Sin logs disponibles: {output}'
        })
