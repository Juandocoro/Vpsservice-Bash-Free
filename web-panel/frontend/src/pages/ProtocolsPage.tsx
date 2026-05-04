import { useEffect, useState } from 'react'
import { useProtocolsStore } from '../store'
import ProtocolsList from '../components/ProtocolsList'

/**
 * Página ProtocolsPage
 * 
 * Gestión de protocolos/servicios VPS
 * 
 * Funcionalidad:
 * - Listar protocolos disponibles e instalados
 * - Instalar nuevos protocolos
 * - Desinstalar protocolos
 * - Ver configuración de protocolos
 * - Reiniciar servicios
 * - Ver estado/logs del protocolo
 */
function ProtocolsPage() {
  // State para mostrar/ocultar modal de instalar protocolo
  const [showInstallForm, setShowInstallForm] = useState(false)
  const [selectedProtocol, setSelectedProtocol] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  // Store de protocolos
  const { protocols, fetchProtocols, installProtocol } = useProtocolsStore()

  // Protocolos disponibles que se pueden instalar
  const AVAILABLE_PROTOCOLS = [
    { id: 'stunnel', name: 'Stunnel', description: 'SSL/TLS wrapper' },
    { id: 'udp', name: 'UDP Custom', description: 'UDP personalizado' },
    { id: 'badvpn', name: 'BadVPN', description: 'BadVPN UDP tunnel' },
    { id: 'websocket', name: 'WebSocket', description: 'WebSocket proxy' },
    { id: 'dropbear', name: 'Dropbear SSH', description: 'SSH alternativo' },
    { id: 'slowdns', name: 'SlowDNS', description: 'DNS over HTTPS' },
    { id: 'squid', name: 'Squid Proxy', description: 'HTTP Proxy' },
    { id: 'v2ray', name: 'V2Ray', description: 'V2Ray proxy' },
    { id: 'shadowsocks', name: 'Shadowsocks', description: 'SOCKS5 proxy' },
    { id: 'openvpn', name: 'OpenVPN', description: 'OpenVPN server' },
    { id: 'wireguard', name: 'WireGuard', description: 'WireGuard VPN' },
  ]

  // Cargar protocolos al montar el componente
  useEffect(() => {
    const loadProtocols = async () => {
      setLoading(true)
      try {
        await fetchProtocols()
      } catch (error) {
        console.error('Error loading protocols:', error)
        alert('Error al cargar protocolos')
      } finally {
        setLoading(false)
      }
    }
    loadProtocols()
  }, [fetchProtocols])

  // Manejar instalar protocolo
  const handleInstallProtocol = (protocolId: string) => {
    setSelectedProtocol(protocolId)
    setShowInstallForm(true)
  }

  // Confirmar instalación
  const handleConfirmInstall = async () => {
    if (!selectedProtocol) return

    setLoading(true)
    try {
      console.log(`Installing protocol: ${selectedProtocol}`)
      // Enviar nombre (y puerto predeterminado = 0, el instalador usa el suyo)
      await installProtocol({ name: selectedProtocol, port: 0 })
      
      alert(`${selectedProtocol} instalado correctamente`)
      setShowInstallForm(false)
      setSelectedProtocol(null)
      // Recargar lista de protocolos
      await fetchProtocols()
    } catch (error) {
      console.error('Error installing protocol:', error)
      alert('Error al instalar protocolo')
    } finally {
      setLoading(false)
    }
  }

  // Protocolos instalados
  const installedProtocolIds = protocols.map(p => p.service_name)

  // Protocolos disponibles para instalar
  const availableToInstall = AVAILABLE_PROTOCOLS.filter(
    p => !installedProtocolIds.includes(p.id)
  )

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold text-white">Gestión de Protocolos</h1>
        {availableToInstall.length > 0 && (
          <select
            onChange={(e) => {
              if (e.target.value) {
                handleInstallProtocol(e.target.value)
              }
            }}
            value=""
            className="input-base max-w-xs"
          >
            <option value="">+ Instalar protocolo</option>
            {availableToInstall.map(p => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        )}
      </div>

      {/* Modal de confirmación */}
      {showInstallForm && selectedProtocol && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-gray-800 rounded-lg shadow-2xl p-8 w-full max-w-md">
            <h2 className="text-2xl font-bold text-white mb-4">
              Instalar Protocolo
            </h2>
            <p className="text-gray-300 mb-6">
              ¿Estás seguro de que deseas instalar{' '}
              <strong>
                {AVAILABLE_PROTOCOLS.find(p => p.id === selectedProtocol)?.name}
              </strong>
              ?
            </p>
            <div className="flex gap-3">
              <button
                onClick={() => {
                  setShowInstallForm(false)
                  setSelectedProtocol(null)
                }}
                className="btn-secondary flex-1"
              >
                Cancelar
              </button>
              <button
                onClick={handleConfirmInstall}
                disabled={loading}
                className="btn-primary flex-1 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {loading ? 'Instalando...' : 'Instalar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Lista de protocolos instalados */}
      <div>
        <h2 className="text-xl font-bold text-white mb-4">
          Protocolos Instalados ({protocols.length})
        </h2>
        {loading ? (
          <div className="card flex items-center justify-center py-12">
            <p className="text-gray-400">Cargando protocolos...</p>
          </div>
        ) : protocols.length === 0 ? (
          <div className="card text-center py-12">
            <p className="text-gray-400 mb-4">No hay protocolos instalados</p>
            <p className="text-sm text-gray-500">
              Instala un protocolo desde el menú superior
            </p>
          </div>
        ) : (
          <ProtocolsList />
        )}
      </div>

      {/* Protocolos disponibles */}
      {availableToInstall.length > 0 && (
        <div>
          <h2 className="text-xl font-bold text-white mb-4">
            Protocolos Disponibles ({availableToInstall.length})
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {availableToInstall.map(protocol => (
              <div key={protocol.id} className="card hover:border-blue-500 transition-colors">
                <h3 className="text-lg font-bold text-white mb-1">
                  {protocol.name}
                </h3>
                <p className="text-gray-400 text-sm mb-4">
                  {protocol.description}
                </p>
                <button
                  onClick={() => handleInstallProtocol(protocol.id)}
                  className="btn-primary w-full text-sm"
                >
                  Instalar
                </button>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

export default ProtocolsPage
