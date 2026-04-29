// ===================================================================
// VPSService Web Panel - API Service
// Gestiona todas las peticiones HTTP a la API Django
// Maneja autenticación, errores y request/response
// ===================================================================

import axios, { AxiosInstance, AxiosError } from 'axios';

// ===================================================================
// INTERFAZ: Respuesta de Token JWT
// ===================================================================
interface TokenResponse {
  access: string;
  refresh: string;
}

// ===================================================================
// INTERFAZ: Usuario SSH
// ===================================================================
export interface SSHUser {
  id: number;
  username: string;
  max_connections: number;
  created_date: string;
  expiry_date: string;
  is_active: boolean;
  is_expired: boolean;
  days_until_expiry: number;
  created_by: string;
  notes: string;
}

// ===================================================================
// INTERFAZ: Protocolo
// ===================================================================
export interface Protocol {
  id: number;
  name: string;
  port: number;
  protocol_type: 'tcp' | 'udp';
  is_installed: boolean;
  is_active: boolean;
  description: string;
  configuration: Record<string, any>;
}

// ===================================================================
// CLASE: API Service
// ===================================================================
class APIService {
  // URL base del backend Django
  private baseURL: string = import.meta.env.VITE_API_URL || 'http://localhost:8000/api';

  // Instancia de Axios configurada
  private client: AxiosInstance;

  // Tokens JWT
  private accessToken: string | null = null;
  private refreshToken: string | null = null;

  constructor() {
    // ===== CREAR INSTANCIA DE AXIOS =====
    this.client = axios.create({
      baseURL: this.baseURL,
      headers: {
        'Content-Type': 'application/json',
      },
    });

    // ===== INTERCEPTOR: Agregar token a cada request =====
    this.client.interceptors.request.use(
      (config) => {
        if (this.accessToken) {
          config.headers.Authorization = `Bearer ${this.accessToken}`;
        }
        return config;
      },
      (error) => Promise.reject(error)
    );

    // ===== INTERCEPTOR: Manejar errores y refresh de token =====
    this.client.interceptors.response.use(
      (response) => response,
      async (error) => {
        const originalRequest = error.config;

        // Si error es 401 (No autenticado) y aún no hemos intentado refresh
        if (error.response?.status === 401 && !originalRequest._retry) {
          originalRequest._retry = true;

          try {
            // Intentar refrescar el token
            await this.refreshAccessToken();
            // Reintentar la petición original con el nuevo token
            return this.client(originalRequest);
          } catch (refreshError) {
            // Si falla refresh, limpiar tokens y redirigir a login
            this.logout();
            return Promise.reject(refreshError);
          }
        }

        return Promise.reject(error);
      }
    );

    // ===== CARGAR TOKENS DEL LOCAL STORAGE =====
    this.loadTokens();
  }

  // ===================================================================
  // AUTENTICACIÓN
  // ===================================================================

  /**
   * Login: Obtener tokens JWT
   * @param username - Nombre de usuario
   * @param password - Contraseña
   */
  async login(username: string, password: string): Promise<TokenResponse> {
    try {
      const response = await this.client.post<TokenResponse>('/auth/token/', {
        username,
        password,
      });

      this.accessToken = response.data.access;
      this.refreshToken = response.data.refresh;

      // Guardar tokens en local storage
      this.saveTokens();

      return response.data;
    } catch (error) {
      console.error('Error en login:', error);
      throw error;
    }
  }

  /**
   * Logout: Limpiar tokens locales
   */
  logout(): void {
    this.accessToken = null;
    this.refreshToken = null;
    localStorage.removeItem('accessToken');
    localStorage.removeItem('refreshToken');
  }

  /**
   * Refrescar token de acceso usando refresh token
   */
  private async refreshAccessToken(): Promise<void> {
    if (!this.refreshToken) {
      throw new Error('No refresh token disponible');
    }

    try {
      const response = await this.client.post<TokenResponse>('/auth/token/refresh/', {
        refresh: this.refreshToken,
      });

      this.accessToken = response.data.access;
      this.saveTokens();
    } catch (error) {
      console.error('Error refrescando token:', error);
      this.logout();
      throw error;
    }
  }

  /**
   * Guardar tokens en local storage
   */
  private saveTokens(): void {
    if (this.accessToken) {
      localStorage.setItem('accessToken', this.accessToken);
    }
    if (this.refreshToken) {
      localStorage.setItem('refreshToken', this.refreshToken);
    }
  }

  /**
   * Cargar tokens del local storage
   */
  private loadTokens(): void {
    this.accessToken = localStorage.getItem('accessToken') || null;
    this.refreshToken = localStorage.getItem('refreshToken') || null;
  }

  /**
   * Verificar si el usuario está autenticado
   */
  isAuthenticated(): boolean {
    return !!this.accessToken;
  }

  // ===================================================================
  // USUARIOS
  // ===================================================================

  /**
   * Listar usuarios SSH
   */
  async getUsers(): Promise<SSHUser[]> {
    const response = await this.client.get<{ results: SSHUser[] }>('/users/');
    return response.data.results;
  }

  /**
   * Obtener usuario por ID
   */
  async getUser(id: number): Promise<SSHUser> {
    const response = await this.client.get<SSHUser>(`/users/${id}/`);
    return response.data;
  }

  /**
   * Crear nuevo usuario
   */
  async createUser(userData: {
    username: string;
    password: string;
    confirm_password: string;
    max_connections: number;
    expiry_date: string;
    notes?: string;
  }): Promise<SSHUser> {
    const response = await this.client.post<SSHUser>('/users/', userData);
    return response.data;
  }

  /**
   * Actualizar usuario
   */
  async updateUser(id: number, userData: Partial<SSHUser>): Promise<SSHUser> {
    const response = await this.client.put<SSHUser>(`/users/${id}/`, userData);
    return response.data;
  }

  /**
   * Eliminar usuario
   */
  async deleteUser(id: number): Promise<void> {
    await this.client.delete(`/users/${id}/`);
  }

  /**
   * Activar/Desactivar usuario
   */
  async toggleUserActive(id: number): Promise<SSHUser> {
    const response = await this.client.post<SSHUser>(`/users/${id}/toggle_active/`);
    return response.data;
  }

  /**
   * Cambiar contraseña de usuario
   */
  async changeUserPassword(id: number, newPassword: string): Promise<any> {
    const response = await this.client.post(`/users/${id}/change_password/`, {
      new_password: newPassword,
    });
    return response.data;
  }

  /**
   * Obtener logs de acceso de usuario
   */
  async getUserAccessLogs(id: number): Promise<any[]> {
    const response = await this.client.get<{ results: any[] }>(`/users/${id}/access-logs/`);
    return response.data.results;
  }

  /**
   * Obtener estadísticas de usuarios
   */
  async getUserStats(): Promise<{
    total_users: number;
    active_users: number;
    expired_users: number;
    soon_to_expire: number;
  }> {
    const response = await this.client.get('/users/stats/');
    return response.data;
  }

  // ===================================================================
  // PROTOCOLOS
  // ===================================================================

  /**
   * Listar protocolos
   */
  async getProtocols(): Promise<Protocol[]> {
    const response = await this.client.get<{ results: Protocol[] }>('/protocols/');
    return response.data.results;
  }

  /**
   * Obtener protocolo por ID
   */
  async getProtocol(id: number): Promise<Protocol> {
    const response = await this.client.get<Protocol>(`/protocols/${id}/`);
    return response.data;
  }

  /**
   * Instalar protocolo
   */
  async installProtocol(protocolData: Partial<Protocol>): Promise<Protocol> {
    const response = await this.client.post<Protocol>('/protocols/', protocolData);
    return response.data;
  }

  /**
   * Actualizar protocolo
   */
  async updateProtocol(id: number, protocolData: Partial<Protocol>): Promise<Protocol> {
    const response = await this.client.put<Protocol>(`/protocols/${id}/`, protocolData);
    return response.data;
  }

  /**
   * Desinstalar protocolo
   */
  async uninstallProtocol(id: number): Promise<void> {
    await this.client.delete(`/protocols/${id}/`);
  }

  // ===================================================================
  // MANEJO DE ERRORES
  // ===================================================================

  /**
   * Extraer mensaje de error de una excepción Axios
   */
  getErrorMessage(error: any): string {
    if (error.response?.data?.detail) {
      return error.response.data.detail;
    }
    if (error.response?.data?.error) {
      return error.response.data.error;
    }
    if (error.message) {
      return error.message;
    }
    return 'Error desconocido';
  }
}

// ===================================================================
// EXPORTAR INSTANCIA SINGLETON
// ===================================================================
export default new APIService();
