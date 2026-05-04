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


def run_cmd(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
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
            real_active = get_service_status(p.name)
            if p.is_active != real_active:
                p.is_active = real_active
                p.save(update_fields=['is_active'])
        return super().list(request, *args, **kwargs)

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
        ok, msg = run_cmd(['bash', script_path])

        if ok:
            protocol.is_installed = True
            protocol.is_active = get_service_status(key)
            protocol.save()

        return Response({
            'success': ok,
            'output': msg,
            'protocol': ProtocolSerializer(protocol).data
        })

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
