import { useState } from 'react'
import { useAuthStore } from '../store'

/**
 * Componente LoginForm
 * 
 * Formulario de autenticación JWT
 * Permite que los usuarios ingresen su nombre de usuario y contraseña
 * 
 * Funcionalidad:
 * - Validación de campos vacíos
 * - Llamada a API para autenticar
 * - Almacenamiento de tokens
 * - Manejo de errores
 */
function LoginForm() {
  // Estado del formulario
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Store de autenticación
  const { login } = useAuthStore()

  // Manejar submit del formulario
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    setLoading(true)

    // Validar campos
    if (!username || !password) {
      setError('Por favor completa todos los campos')
      setLoading(false)
      return
    }

    try {
      // Intentar login
      await login(username, password)
      // Si exitoso, el componente App se re-renderizará automaticamente
    } catch (err) {
      // Mostrar error
      const message =
        err instanceof Error ? err.message : 'Error de autenticación'
      setError(message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {/* Mostrar errores */}
      {error && (
        <div className="p-3 bg-red-900/50 border border-red-700 text-red-200 rounded-lg text-sm">
          {error}
        </div>
      )}

      {/* Input: Usuario */}
      <div>
        <label htmlFor="username" className="block text-sm font-medium text-gray-300 mb-2">
          Usuario
        </label>
        <input
          id="username"
          type="text"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder="admin"
          className="input-base"
          disabled={loading}
          autoFocus
        />
      </div>

      {/* Input: Contraseña */}
      <div>
        <label htmlFor="password" className="block text-sm font-medium text-gray-300 mb-2">
          Contraseña
        </label>
        <input
          id="password"
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="••••••••"
          className="input-base"
          disabled={loading}
        />
      </div>

      {/* Botón Submit */}
      <button
        type="submit"
        disabled={loading}
        className="w-full py-2 px-4 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed transition-colors duration-200"
      >
        {loading ? (
          <span className="flex items-center justify-center">
            {/* Spinner */}
            <svg
              className="animate-spin -ml-1 mr-3 h-5 w-5 text-white"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle
                className="opacity-25"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                strokeWidth="4"
              ></circle>
              <path
                className="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              ></path>
            </svg>
            Autenticando...
          </span>
        ) : (
          'Ingresar'
        )}
      </button>

      {/* Link para recuperar contraseña (futuro) */}
      <p className="text-center text-sm text-gray-400">
        ¿Olvidaste tu contraseña?{' '}
        <a href="#" className="text-blue-400 hover:text-blue-300">
          Restablecer
        </a>
      </p>
    </form>
  )
}

export default LoginForm
