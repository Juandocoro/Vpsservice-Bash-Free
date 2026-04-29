// ===================================================================
// VPSService Web Panel - Global State Store (Zustand)
// Gestiona el estado global de la aplicación
// Autenticación, usuarios, protocolos, etc.
// ===================================================================

import { create } from 'zustand';
import APIService, { SSHUser, Protocol } from '../services/api';

// ===================================================================
// INTERFAZ: Estado de Autenticación
// ===================================================================
interface AuthState {
  isAuthenticated: boolean;
  user: any | null;
  loading: boolean;
  error: string | null;
  login: (username: string, password: string) => Promise<void>;
  logout: () => void;
  clearError: () => void;
}

// ===================================================================
// INTERFAZ: Estado de Usuarios
// ===================================================================
interface UsersState {
  users: SSHUser[];
  selectedUser: SSHUser | null;
  loading: boolean;
  error: string | null;

  // Acciones
  fetchUsers: () => Promise<void>;
  selectUser: (user: SSHUser | null) => void;
  createUser: (userData: any) => Promise<void>;
  updateUser: (id: number, userData: Partial<SSHUser>) => Promise<void>;
  deleteUser: (id: number) => Promise<void>;
  toggleUserActive: (id: number) => Promise<void>;
  changeUserPassword: (id: number, newPassword: string) => Promise<void>;
  clearError: () => void;
}

// ===================================================================
// INTERFAZ: Estado de Protocolos
// ===================================================================
interface ProtocolsState {
  protocols: Protocol[];
  selectedProtocol: Protocol | null;
  loading: boolean;
  error: string | null;

  // Acciones
  fetchProtocols: () => Promise<void>;
  selectProtocol: (protocol: Protocol | null) => void;
  installProtocol: (protocolData: any) => Promise<void>;
  uninstallProtocol: (id: number) => Promise<void>;
  updateProtocol: (id: number, protocolData: Partial<Protocol>) => Promise<void>;
  clearError: () => void;
}

// ===================================================================
// STORE: Autenticación
// ===================================================================
export const useAuthStore = create<AuthState>((set) => ({
  isAuthenticated: APIService.isAuthenticated(),
  user: null,
  loading: false,
  error: null,

  // Acción: Login
  login: async (username: string, password: string) => {
    set({ loading: true, error: null });
    try {
      await APIService.login(username, password);
      set({
        isAuthenticated: true,
        user: { username },
        loading: false,
      });
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        isAuthenticated: false,
        loading: false,
        error: errorMessage,
      });
    }
  },

  // Acción: Logout
  logout: () => {
    APIService.logout();
    set({
      isAuthenticated: false,
      user: null,
      error: null,
    });
  },

  // Acción: Limpiar error
  clearError: () => set({ error: null }),
}));

// ===================================================================
// STORE: Usuarios
// ===================================================================
export const useUsersStore = create<UsersState>((set) => ({
  users: [],
  selectedUser: null,
  loading: false,
  error: null,

  // ===== ACCIÓN: Obtener usuarios =====
  fetchUsers: async () => {
    set({ loading: true, error: null });
    try {
      const users = await APIService.getUsers();
      set({ users, loading: false });
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
    }
  },

  // ===== ACCIÓN: Seleccionar usuario =====
  selectUser: (user: SSHUser | null) => {
    set({ selectedUser: user });
  },

  // ===== ACCIÓN: Crear usuario =====
  createUser: async (userData: any) => {
    set({ loading: true, error: null });
    try {
      const newUser = await APIService.createUser(userData);
      set((state) => ({
        users: [...state.users, newUser],
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Actualizar usuario =====
  updateUser: async (id: number, userData: Partial<SSHUser>) => {
    set({ loading: true, error: null });
    try {
      const updatedUser = await APIService.updateUser(id, userData);
      set((state) => ({
        users: state.users.map((u) => (u.id === id ? updatedUser : u)),
        selectedUser:
          state.selectedUser?.id === id ? updatedUser : state.selectedUser,
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Eliminar usuario =====
  deleteUser: async (id: number) => {
    set({ loading: true, error: null });
    try {
      await APIService.deleteUser(id);
      set((state) => ({
        users: state.users.filter((u) => u.id !== id),
        selectedUser:
          state.selectedUser?.id === id ? null : state.selectedUser,
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Activar/Desactivar usuario =====
  toggleUserActive: async (id: number) => {
    set({ loading: true, error: null });
    try {
      const updatedUser = await APIService.toggleUserActive(id);
      set((state) => ({
        users: state.users.map((u) => (u.id === id ? updatedUser : u)),
        selectedUser:
          state.selectedUser?.id === id ? updatedUser : state.selectedUser,
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Cambiar contraseña =====
  changeUserPassword: async (id: number, newPassword: string) => {
    set({ loading: true, error: null });
    try {
      await APIService.changeUserPassword(id, newPassword);
      set({ loading: false });
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Limpiar error =====
  clearError: () => set({ error: null }),
}));

// ===================================================================
// STORE: Protocolos
// ===================================================================
export const useProtocolsStore = create<ProtocolsState>((set) => ({
  protocols: [],
  selectedProtocol: null,
  loading: false,
  error: null,

  // ===== ACCIÓN: Obtener protocolos =====
  fetchProtocols: async () => {
    set({ loading: true, error: null });
    try {
      const protocols = await APIService.getProtocols();
      set({ protocols, loading: false });
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
    }
  },

  // ===== ACCIÓN: Seleccionar protocolo =====
  selectProtocol: (protocol: Protocol | null) => {
    set({ selectedProtocol: protocol });
  },

  // ===== ACCIÓN: Instalar protocolo =====
  installProtocol: async (protocolData: any) => {
    set({ loading: true, error: null });
    try {
      const newProtocol = await APIService.installProtocol(protocolData);
      set((state) => ({
        protocols: [...state.protocols, newProtocol],
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Desinstalar protocolo =====
  uninstallProtocol: async (id: number) => {
    set({ loading: true, error: null });
    try {
      await APIService.uninstallProtocol(id);
      set((state) => ({
        protocols: state.protocols.filter((p) => p.id !== id),
        selectedProtocol:
          state.selectedProtocol?.id === id
            ? null
            : state.selectedProtocol,
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Actualizar protocolo =====
  updateProtocol: async (id: number, protocolData: Partial<Protocol>) => {
    set({ loading: true, error: null });
    try {
      const updatedProtocol = await APIService.updateProtocol(
        id,
        protocolData
      );
      set((state) => ({
        protocols: state.protocols.map((p) =>
          p.id === id ? updatedProtocol : p
        ),
        selectedProtocol:
          state.selectedProtocol?.id === id
            ? updatedProtocol
            : state.selectedProtocol,
        loading: false,
      }));
    } catch (error: any) {
      const errorMessage = APIService.getErrorMessage(error);
      set({
        loading: false,
        error: errorMessage,
      });
      throw error;
    }
  },

  // ===== ACCIÓN: Limpiar error =====
  clearError: () => set({ error: null }),
}));
