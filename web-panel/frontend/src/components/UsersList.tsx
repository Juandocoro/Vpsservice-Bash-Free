// ===================================================================
// VPSService Web Panel - Componente: Lista de Usuarios
// Muestra tabla con todos los usuarios SSH y opciones de acción
// ===================================================================

import React from 'react';
import { useUsersStore } from '@/store';
import { SSHUser } from '@/services/api';

interface UsersListProps {
  onSelectUser?: (user: SSHUser) => void;
}

/**
 * Componente UsersLlist
 *
 * Propiedades:
 * - onSelectUser: Callback cuando se selecciona un usuario
 *
 * Estado:
 * - users: Lista de usuarios desde Zustand store
 * - loading: Indica si se están cargando datos
 * - error: Mensaje de error si hay
 */
export const UsersList: React.FC<UsersListProps> = ({ onSelectUser }) => {
  // ===== OBTENER ESTADO DEL STORE =====
  const {
    users,
    loading,
    error,
    fetchUsers,
    selectUser,
    toggleUserActive,
    deleteUser,
  } = useUsersStore();

  // El componente padre (UsersPage) ya se encarga de llamar a fetchUsers()
  // No lo llamamos aquí para evitar un bucle infinito de re-renderizado.

  // ===== MANEJADOR: Clic en usuario =====
  const handleSelectUser = (user: SSHUser) => {
    selectUser(user);
    onSelectUser?.(user);
  };

  // ===== MANEJADOR: Activar/Desactivar usuario =====
  const handleToggleActive = async (
    e: React.MouseEvent,
    userId: number
  ) => {
    e.stopPropagation(); // Prevenir propagación del click
    try {
      await toggleUserActive(userId);
    } catch (err) {
      console.error('Error toggling user:', err);
    }
  };

  // ===== MANEJADOR: Eliminar usuario =====
  const handleDeleteUser = async (
    e: React.MouseEvent,
    userId: number
  ) => {
    e.stopPropagation();
    if (window.confirm('¿Estás seguro de que deseas eliminar este usuario?')) {
      try {
        await deleteUser(userId);
      } catch (err) {
        console.error('Error deleting user:', err);
      }
    }
  };

  // ===== RENDER: Mostrar error =====
  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4">
        <p className="text-red-800">Error: {error}</p>
      </div>
    );
  }

  // ===== RENDER: Mostrar loading =====
  if (loading) {
    return (
      <div className="text-center py-8">
        <div className="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500"></div>
        <p className="mt-2 text-gray-600">Cargando usuarios...</p>
      </div>
    );
  }

  // ===== RENDER: Tabla de usuarios =====
  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-100 border-b">
          <tr>
            <th className="px-4 py-2 text-left text-sm font-semibold">
              Usuario
            </th>
            <th className="px-4 py-2 text-left text-sm font-semibold">
              Conexiones
            </th>
            <th className="px-4 py-2 text-left text-sm font-semibold">
              Vence
            </th>
            <th className="px-4 py-2 text-left text-sm font-semibold">
              Estado
            </th>
            <th className="px-4 py-2 text-left text-sm font-semibold">
              Acciones
            </th>
          </tr>
        </thead>
        <tbody>
          {users.map((user) => (
            <tr
              key={user.id}
              onClick={() => handleSelectUser(user)}
              className="border-b hover:bg-gray-50 cursor-pointer transition"
            >
              {/* Columna: Usuario */}
              <td className="px-4 py-2">
                <div>
                  <p className="font-medium text-gray-900">
                    {user.username}
                  </p>
                  <p className="text-sm text-gray-600">
                    Creado: {new Date(user.created_date).toLocaleDateString()}
                  </p>
                </div>
              </td>

              {/* Columna: Conexiones */}
              <td className="px-4 py-2 text-sm">
                Máx: {user.max_connections}
              </td>

              {/* Columna: Vence */}
              <td className="px-4 py-2 text-sm">
                <span
                  className={`inline-block px-2 py-1 rounded text-white text-xs font-semibold ${
                    user.is_expired
                      ? 'bg-red-500'
                      : user.days_until_expiry <= 7
                      ? 'bg-yellow-500'
                      : 'bg-green-500'
                  }`}
                >
                  {user.expiry_date}
                  <br />
                  ({user.days_until_expiry} días)
                </span>
              </td>

              {/* Columna: Estado */}
              <td className="px-4 py-2 text-sm">
                <span
                  className={`inline-block px-2 py-1 rounded text-white text-xs font-semibold ${
                    user.is_active ? 'bg-blue-500' : 'bg-gray-400'
                  }`}
                >
                  {user.is_active ? 'Activo' : 'Inactivo'}
                </span>
              </td>

              {/* Columna: Acciones */}
              <td className="px-4 py-2 text-sm space-x-2">
                {/* Botón: Activar/Desactivar */}
                <button
                  onClick={(e) => handleToggleActive(e, user.id)}
                  className={`px-3 py-1 rounded text-white text-xs font-semibold transition ${
                    user.is_active
                      ? 'bg-yellow-500 hover:bg-yellow-600'
                      : 'bg-green-500 hover:bg-green-600'
                  }`}
                >
                  {user.is_active ? 'Desactivar' : 'Activar'}
                </button>

                {/* Botón: Eliminar */}
                <button
                  onClick={(e) => handleDeleteUser(e, user.id)}
                  className="px-3 py-1 rounded bg-red-500 hover:bg-red-600 text-white text-xs font-semibold transition"
                >
                  Eliminar
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {/* Si no hay usuarios */}
      {users.length === 0 && (
        <div className="text-center py-8 text-gray-600">
          No hay usuarios creados. Crea uno nuevo para comenzar.
        </div>
      )}
    </div>
  );
};
