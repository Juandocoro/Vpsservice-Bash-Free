import { useState, useEffect } from 'react'
import { useUsersStore } from '../store'

/**
 * Componente UserForm
 * 
 * Formulario para crear y editar usuarios SSH
 * 
 * Props:
 * - user: Usuario a editar (null si es crear nuevo)
 * - onSuccess: Callback cuando se guarda exitosamente
 * - onCancel: Callback para cancelar la edición
 */
interface UserFormProps {
  user?: any | null
  onSuccess: () => void
  onCancel: () => void
}

function UserForm({ user, onSuccess, onCancel }: UserFormProps) {
  // State del formulario
  const [formData, setFormData] = useState({
    username: '',
    password: '',
    confirm_password: '',
    max_connections: 2,
    expiry_date: '',
  })
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(false)

  // Store de usuarios
  const { createUser, updateUser } = useUsersStore()

  // Cargar datos del usuario si es edición
  useEffect(() => {
    if (user) {
      setFormData({
        username: user.username,
        password: '',
        confirm_password: '',
        max_connections: user.max_connections || 2,
        expiry_date: user.expiry_date || '',
      })
    }
  }, [user])

  // Validar formulario
  const validateForm = () => {
    const newErrors: Record<string, string> = {}

    if (!formData.username) {
      newErrors.username = 'Usuario es requerido'
    }
    if (!user && !formData.password) {
      newErrors.password = 'Contraseña es requerida'
    }
    if (formData.password && formData.password.length < 6) {
      newErrors.password = 'La contraseña debe tener al menos 6 caracteres'
    }
    if (user && formData.password && formData.password !== formData.confirm_password) {
      newErrors.confirm_password = 'Las contraseñas no coinciden'
    }
    if (!user && formData.password !== formData.confirm_password) {
      newErrors.confirm_password = 'Las contraseñas no coinciden'
    }
    if (formData.max_connections < 1) {
      newErrors.max_connections = 'Mínimo 1 conexión'
    }
    if (!formData.expiry_date) {
      newErrors.expiry_date = 'Fecha de expiración es requerida'
    }

    setErrors(newErrors)
    return Object.keys(newErrors).length === 0
  }

  // Manejar cambios en inputs
  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    const { name, value } = e.target
    setFormData(prev => ({
      ...prev,
      [name]: name === 'max_connections' ? parseInt(value) : value,
    }))
    // Limpiar error cuando el usuario empieza a escribir
    if (errors[name]) {
      setErrors(prev => ({
        ...prev,
        [name]: '',
      }))
    }
  }

  // Manejar submit
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    if (!validateForm()) return

    setLoading(true)
    try {
      if (user) {
        // Editar usuario existente
        await updateUser(user.id, {
          max_connections: formData.max_connections,
          expiry_date: formData.expiry_date,
          ...(formData.password && { password: formData.password }),
        })
        alert('Usuario actualizado correctamente')
      } else {
        // Crear nuevo usuario
        await createUser({
          username: formData.username,
          password: formData.password,
          confirm_password: formData.confirm_password,
          max_connections: formData.max_connections,
          expiry_date: formData.expiry_date,
        })
        alert('Usuario creado correctamente')
      }
      onSuccess()
    } catch (error) {
      console.error('Error saving user:', error)
      const message = error instanceof Error ? error.message : 'Error al guardar usuario'
      alert(message)
    } finally {
      setLoading(false)
    }
  }

  // Calcular fecha mínima (hoy)
  const today = new Date().toISOString().split('T')[0]

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {/* Usuario */}
      <div>
        <label className="block text-sm font-medium text-gray-300 mb-1">
          Usuario
        </label>
        <input
          type="text"
          name="username"
          value={formData.username}
          onChange={handleChange}
          placeholder="john_doe"
          className={`input-base ${errors.username ? 'ring-2 ring-red-500' : ''}`}
          disabled={loading || !!user}
        />
        {errors.username && (
          <p className="text-red-400 text-sm mt-1">{errors.username}</p>
        )}
      </div>

      {/* Contraseña */}
      <div>
        <label className="block text-sm font-medium text-gray-300 mb-1">
          Contraseña {user && '(dejar en blanco para no cambiar)'}
        </label>
        <input
          type="password"
          name="password"
          value={formData.password}
          onChange={handleChange}
          placeholder="••••••••"
          className={`input-base ${errors.password ? 'ring-2 ring-red-500' : ''}`}
          disabled={loading}
        />
        {errors.password && (
          <p className="text-red-400 text-sm mt-1">{errors.password}</p>
        )}
      </div>

      {/* Confirmar Contraseña */}
      <div>
        <label className="block text-sm font-medium text-gray-300 mb-1">
          Confirmar Contraseña
        </label>
        <input
          type="password"
          name="confirm_password"
          value={formData.confirm_password}
          onChange={handleChange}
          placeholder="••••••••"
          className={`input-base ${errors.confirm_password ? 'ring-2 ring-red-500' : ''}`}
          disabled={loading}
        />
        {errors.confirm_password && (
          <p className="text-red-400 text-sm mt-1">{errors.confirm_password}</p>
        )}
      </div>

      {/* Máximo de Conexiones */}
      <div>
        <label className="block text-sm font-medium text-gray-300 mb-1">
          Máximo de Conexiones Simultáneas
        </label>
        <select
          name="max_connections"
          value={formData.max_connections}
          onChange={handleChange}
          className="input-base"
          disabled={loading}
        >
          {[1, 2, 3, 4, 5, 10, 20].map(num => (
            <option key={num} value={num}>
              {num} conexión{num > 1 ? 'es' : ''}
            </option>
          ))}
        </select>
        {errors.max_connections && (
          <p className="text-red-400 text-sm mt-1">{errors.max_connections}</p>
        )}
      </div>

      {/* Fecha de Expiración */}
      <div>
        <label className="block text-sm font-medium text-gray-300 mb-1">
          Fecha de Expiración
        </label>
        <input
          type="date"
          name="expiry_date"
          value={formData.expiry_date}
          onChange={handleChange}
          min={today}
          className="input-base"
          disabled={loading}
        />
        {errors.expiry_date && (
          <p className="text-red-400 text-sm mt-1">{errors.expiry_date}</p>
        )}
      </div>

      {/* Botones */}
      <div className="flex gap-3 pt-4">
        <button
          type="button"
          onClick={onCancel}
          disabled={loading}
          className="btn-secondary flex-1"
        >
          Cancelar
        </button>
        <button
          type="submit"
          disabled={loading}
          className="btn-primary flex-1 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {loading ? 'Guardando...' : 'Guardar Usuario'}
        </button>
      </div>
    </form>
  )
}

export default UserForm
