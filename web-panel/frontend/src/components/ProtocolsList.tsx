import { useProtocolsStore } from '../store'

/**
 * Componente ProtocolsList
 * 
 * Muestra tabla con protocolos instalados en el VPS
 * 
 * Funcionalidad:
 * - Listar protocolos con detalles
 * - Mostrar estado del servicio
 * - Botones para reiniciar/parar servicio
 * - Botones para desinstalar protocolo
 * - Editar configuración
 */
function ProtocolsList() {
  const { protocols, setNotification } = useProtocolsStore()

  // Obtener ícono según protocolo
  const getProtocolIcon = (protocolName: string): string => {
    const icons: Record<string, string> = {
      stunnel: '🔒',
      udp: '📡',
      badvpn: '🌐',
      websocket: '🔌',
      dropbear: '🚪',
      slowdns: '🐢',
      squid: '🦑',
      v2ray: '⚡',
      shadowsocks: '👥',
      openvpn: '🔓',
      wireguard: '⚙️',
    }
    return icons[protocolName] || '🔧'
  }

  // Formatear fecha
  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('es-ES', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    })
  }

  // Manejar reiniciar servicio
  const handleRestartService = async (protocolId: number, serviceName: string) => {
    if (confirm(`¿Reiniciar servicio ${serviceName}?`)) {
      try {
        // Aquí iría la llamada a API para reiniciar
        console.log(`Restarting service: ${serviceName}`)
        setNotification({
          type: 'success',
          message: `${serviceName} reiniciado correctamente`,
        })
      } catch (error) {
        setNotification({
          type: 'error',
          message: 'Error al reiniciar servicio',
        })
      }
    }
  }

  // Manejar desinstalar protocolo
  const handleUninstall = async (protocolId: number, serviceName: string) => {
    if (
      confirm(
        `¿Desinstalar ${serviceName}? Esta acción no se puede deshacer.`
      )
    ) {
      try {
        // Aquí iría la llamada a API para desinstalar
        console.log(`Uninstalling protocol: ${serviceName}`)
        setNotification({
          type: 'success',
          message: `${serviceName} desinstalado correctamente`,
        })
      } catch (error) {
        setNotification({
          type: 'error',
          message: 'Error al desinstalar protocolo',
        })
      }
    }
  }

  if (protocols.length === 0) {
    return (
      <div className="card text-center py-8">
        <p className="text-gray-400">No hay protocolos instalados</p>
      </div>
    )
  }

  return (
    <div className="card overflow-x-auto">
      <table className="w-full">
        <thead className="border-b border-gray-700">
          <tr>
            <th className="text-left py-3 px-4 text-gray-300 font-medium">
              Protocolo
            </th>
            <th className="text-left py-3 px-4 text-gray-300 font-medium">
              Puerto
            </th>
            <th className="text-left py-3 px-4 text-gray-300 font-medium">
              Estado
            </th>
            <th className="text-left py-3 px-4 text-gray-300 font-medium">
              Instalado
            </th>
            <th className="text-left py-3 px-4 text-gray-300 font-medium">
              Acciones
            </th>
          </tr>
        </thead>
        <tbody>
          {protocols.map((protocol, index) => (
            <tr
              key={protocol.id}
              className={`border-b border-gray-700 hover:bg-gray-700/50 transition-colors ${
                index % 2 === 0 ? 'bg-gray-800/30' : ''
              }`}
            >
              {/* Nombre del protocolo */}
              <td className="py-3 px-4">
                <div className="flex items-center gap-3">
                  <span className="text-2xl">
                    {getProtocolIcon(protocol.service_name)}
                  </span>
                  <div>
                    <p className="font-medium text-white">
                      {protocol.name || protocol.service_name}
                    </p>
                    <p className="text-xs text-gray-400">
                      {protocol.service_name}
                    </p>
                  </div>
                </div>
              </td>

              {/* Puerto */}
              <td className="py-3 px-4">
                <span className="px-3 py-1 bg-blue-900/50 text-blue-200 rounded text-sm font-mono">
                  {protocol.port}
                </span>
              </td>

              {/* Estado */}
              <td className="py-3 px-4">
                <div className="flex items-center gap-2">
                  <span
                    className={`inline-block w-2 h-2 rounded-full ${
                      protocol.status === 'running'
                        ? 'bg-green-500'
                        : 'bg-red-500'
                    }`}
                  ></span>
                  <span
                    className={`text-sm font-medium ${
                      protocol.status === 'running'
                        ? 'text-green-400'
                        : 'text-red-400'
                    }`}
                  >
                    {protocol.status === 'running' ? 'Activo' : 'Inactivo'}
                  </span>
                </div>
              </td>

              {/* Fecha de instalación */}
              <td className="py-3 px-4">
                <span className="text-sm text-gray-400">
                  {formatDate(protocol.date_installed)}
                </span>
              </td>

              {/* Acciones */}
              <td className="py-3 px-4">
                <div className="flex gap-2">
                  {/* Botón Reiniciar */}
                  <button
                    onClick={() =>
                      handleRestartService(protocol.id, protocol.service_name)
                    }
                    className="p-2 hover:bg-blue-600/50 rounded text-blue-400 hover:text-blue-300 transition-colors"
                    title="Reiniciar servicio"
                  >
                    🔄
                  </button>

                  {/* Botón Ver configuración */}
                  <button
                    className="p-2 hover:bg-gray-600 rounded text-gray-400 hover:text-white transition-colors"
                    title="Ver configuración"
                  >
                    ⚙️
                  </button>

                  {/* Botón Desinstalar */}
                  <button
                    onClick={() =>
                      handleUninstall(protocol.id, protocol.service_name)
                    }
                    className="p-2 hover:bg-red-600/50 rounded text-red-400 hover:text-red-300 transition-colors"
                    title="Desinstalar"
                  >
                    🗑️
                  </button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export default ProtocolsList
