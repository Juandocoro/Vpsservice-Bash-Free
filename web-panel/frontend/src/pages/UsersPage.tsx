import { useEffect, useState } from 'react'
import { useUsersStore } from '../store'
import { UsersList } from '../components/UsersList'
import UserForm from '../components/UserForm'

/**
 * Página UsersPage
 * 
 * Gestión de usuarios SSH
 * 
 * Funcionalidad:
 * - Listar usuarios existentes
 * - Crear nuevos usuarios
 * - Editar usuarios existentes
 * - Eliminar usuarios
 * - Mostrar detalles (expiración, límite de conexiones)
 */
function UsersPage() {
  // State para mostrar/ocultar modal de crear usuario
  const [showForm, setShowForm] = useState(false)
  const [editingUser, setEditingUser] = useState<any | null>(null)

  // Store de usuarios
  const { users, fetchUsers, loading } = useUsersStore()

  // Cargar usuarios al montar el componente
  useEffect(() => {
    fetchUsers().catch((error) => {
      console.error('Error loading users:', error)
    })
  }, [fetchUsers])

  // Manejar crear nuevo usuario
  const handleNewUser = () => {
    setEditingUser(null)
    setShowForm(true)
  }

  // Manejar editar usuario
  const handleEditUser = (user: any) => {
    setEditingUser(user)
    setShowForm(true)
  }

  // Manejar cerrar formulario
  const handleCloseForm = () => {
    setShowForm(false)
    setEditingUser(null)
  }

  return (
    <div className="space-y-6">
      {/* Header con botón crear usuario */}
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold text-white">Gestión de Usuarios</h1>
        <button
          onClick={handleNewUser}
          className="btn-primary flex items-center gap-2"
        >
          <span>➕</span>
          Crear Usuario
        </button>
      </div>

      {/* Modal para crear/editar usuario */}
      {showForm && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-gray-800 rounded-lg shadow-2xl p-8 w-full max-w-md">
            <h2 className="text-2xl font-bold text-white mb-4">
              {editingUser ? '✏️ Editar Usuario' : '➕ Nuevo Usuario'}
            </h2>
            <UserForm
              user={editingUser}
              onSuccess={handleCloseForm}
              onCancel={handleCloseForm}
            />
          </div>
        </div>
      )}

      {/* Lista de usuarios */}
      {loading ? (
        <div className="card flex items-center justify-center py-12">
          <div className="text-center">
            <div className="animate-spin mb-4">
              <svg
                className="w-12 h-12 text-blue-500 mx-auto"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </div>
            <p className="text-gray-400">Cargando usuarios...</p>
          </div>
        </div>
      ) : users.length === 0 ? (
        <div className="card text-center py-12">
          <p className="text-gray-400 mb-4">No hay usuarios creados</p>
          <button
            onClick={handleNewUser}
            className="btn-primary"
          >
            Crear el primer usuario
          </button>
        </div>
      ) : (
        <UsersList onSelectUser={handleEditUser} />
      )}

      {/* Estadísticas */}
      {users.length > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="card">
            <div className="text-gray-400 text-sm mb-1">Total de Usuarios</div>
            <div className="text-3xl font-bold text-blue-400">{users.length}</div>
          </div>
          <div className="card">
            <div className="text-gray-400 text-sm mb-1">Activos</div>
            <div className="text-3xl font-bold text-green-400">
              {users.filter(u => new Date(u.expiry_date) > new Date()).length}
            </div>
          </div>
          <div className="card">
            <div className="text-gray-400 text-sm mb-1">Expirados</div>
            <div className="text-3xl font-bold text-red-400">
              {users.filter(u => new Date(u.expiry_date) <= new Date()).length}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default UsersPage
