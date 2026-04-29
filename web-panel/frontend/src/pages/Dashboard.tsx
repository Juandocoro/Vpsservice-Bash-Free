import { useState } from 'react'
import { useAuthStore } from '../store'
import UsersPage from './UsersPage'
import ProtocolsPage from './ProtocolsPage'

/**
 * Componente Dashboard
 * 
 * Página principal después del login.
 * 
 * Funcionalidad:
 * - Menú lateral con navegación
 * - Área de contenido principal
 * - Perfil del usuario
 * - Logout
 * - Cambio entre páginas (Usuarios, Protocolos, etc)
 */
function Dashboard() {
  // State para controlar qué página mostrar
  const [currentPage, setCurrentPage] = useState<'users' | 'protocols' | 'logs'>('users')
  const [sidebarOpen, setSidebarOpen] = useState(true)

  // Store de autenticación
  const { user, logout } = useAuthStore()

  // Manejar logout
  const handleLogout = () => {
    if (confirm('¿Estás seguro de que deseas cerrar sesión?')) {
      logout()
    }
  }

  return (
    <div className="flex h-screen bg-gray-900">
      {/* ========== SIDEBAR ========== */}
      <div
        className={`${
          sidebarOpen ? 'w-64' : 'w-20'
        } bg-gray-800 border-r border-gray-700 transition-all duration-300 flex flex-col`}
      >
        {/* Logo/Header */}
        <div className="p-4 border-b border-gray-700">
          <div className="flex items-center justify-between">
            {sidebarOpen && (
              <h1 className="text-xl font-bold text-white">VPSService</h1>
            )}
            <button
              onClick={() => setSidebarOpen(!sidebarOpen)}
              className="p-1 hover:bg-gray-700 rounded transition-colors"
            >
              <svg
                className="w-6 h-6 text-gray-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M4 6h16M4 12h16M4 18h16"
                />
              </svg>
            </button>
          </div>
        </div>

        {/* Menú de navegación */}
        <nav className="flex-1 px-2 py-4 space-y-2 overflow-y-auto">
          {/* Usuarios */}
          <NavButton
            icon="👥"
            label="Usuarios"
            active={currentPage === 'users'}
            onClick={() => setCurrentPage('users')}
            sidebarOpen={sidebarOpen}
          />

          {/* Protocolos */}
          <NavButton
            icon="🔌"
            label="Protocolos"
            active={currentPage === 'protocols'}
            onClick={() => setCurrentPage('protocols')}
            sidebarOpen={sidebarOpen}
          />

          {/* Logs */}
          <NavButton
            icon="📋"
            label="Logs"
            active={currentPage === 'logs'}
            onClick={() => setCurrentPage('logs')}
            sidebarOpen={sidebarOpen}
          />
        </nav>

        {/* Usuario y Logout */}
        <div className="p-4 border-t border-gray-700 space-y-3">
          {/* Info del usuario */}
          {sidebarOpen && (
            <div className="bg-gray-700 p-3 rounded-lg">
              <p className="text-xs text-gray-400">Conectado como</p>
              <p className="font-medium text-white truncate">{user?.username || '—'}</p>
            </div>
          )}

          {/* Botón logout */}
          <button
            onClick={handleLogout}
            className="w-full flex items-center justify-center gap-2 px-3 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors text-sm font-medium"
          >
            <span>🚪</span>
            {sidebarOpen && 'Logout'}
          </button>
        </div>
      </div>

      {/* ========== CONTENIDO PRINCIPAL ========== */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {/* Header */}
        <div className="bg-gray-800 border-b border-gray-700 px-6 py-4 flex items-center justify-between">
          <h2 className="text-2xl font-bold text-white">
            {currentPage === 'users' && '👥 Gestión de Usuarios'}
            {currentPage === 'protocols' && '🔌 Gestión de Protocolos'}
            {currentPage === 'logs' && '📋 Logs del Sistema'}
          </h2>
        </div>

        {/* Área de contenido */}
        <div className="flex-1 overflow-y-auto bg-gray-900 p-6">
          {currentPage === 'users' && <UsersPage />}
          {currentPage === 'protocols' && <ProtocolsPage />}
          {currentPage === 'logs' && (
            <div className="card">
              <h3 className="text-lg font-bold mb-4">📋 Logs del Sistema</h3>
              <p className="text-gray-400">Página en construcción...</p>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

/**
 * Componente NavButton
 * Botón de navegación reutilizable para el sidebar
 */
interface NavButtonProps {
  icon: string
  label: string
  active: boolean
  onClick: () => void
  sidebarOpen: boolean
}

function NavButton({ icon, label, active, onClick, sidebarOpen }: NavButtonProps) {
  return (
    <button
      onClick={onClick}
      className={`w-full flex items-center gap-3 px-3 py-2 rounded-lg transition-colors ${
        active
          ? 'bg-blue-600 text-white'
          : 'text-gray-400 hover:bg-gray-700 hover:text-white'
      }`}
      title={label}
    >
      <span className="text-xl">{icon}</span>
      {sidebarOpen && <span className="font-medium">{label}</span>}
    </button>
  )
}

export default Dashboard
