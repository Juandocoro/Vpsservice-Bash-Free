import { useEffect } from 'react'
import { useAuthStore } from './store'
import LoginForm from './components/LoginForm'
import Dashboard from './pages/Dashboard'

/**
 * Componente raíz de la aplicación
 * 
 * Este componente:
 * - Verifica si el usuario está autenticado
 * - Muestra login si no está autenticado
 * - Muestra dashboard si está autenticado
 * - Gestiona el estado global de autenticación
 */
function App() {
  const { isAuthenticated } = useAuthStore()

  // Cargar token del localStorage al iniciar
  useEffect(() => {
    const token = localStorage.getItem('accessToken')
    if (token) {
      // El APIService ya carga tokens del localStorage.
      // Este efecto se deja solo como “sanity check” visual.
      console.log('Sesión detectada desde token')
    }
  }, [])

  return (
    <div className="min-h-screen bg-gray-900">
      {isAuthenticated ? (
        // Usuario autenticado: mostrar dashboard
        <Dashboard />
      ) : (
        // Usuario no autenticado: mostrar login
        <div className="flex items-center justify-center min-h-screen">
          <div className="w-full max-w-md">
            <div className="bg-gray-800 rounded-lg shadow-lg p-8">
              <h1 className="text-3xl font-bold text-white mb-2 text-center">
                VPSService
              </h1>
              <p className="text-gray-400 text-center mb-6">
                Panel de Control Web
              </p>
              <LoginForm />
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default App
