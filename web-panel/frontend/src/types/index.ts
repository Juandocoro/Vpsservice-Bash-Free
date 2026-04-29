/**
 * Tipos e interfaces TypeScript compartidas
 */

/**
 * Modelo de Usuario SSH
 */
export interface User {
  id: number
  username: string
  password_hash?: string
  expiration_date: string
  connection_limit: number
  date_created: string
  date_modified: string
}

/**
 * Modelo de Protocolo/Servicio
 */
export interface Protocol {
  id: number
  name: string
  service_name: string
  port: number
  status: 'running' | 'stopped' | 'error'
  config_data?: Record<string, any>
  date_installed: string
}

/**
 * Respuesta de autenticación JWT
 */
export interface AuthResponse {
  access_token: string
  refresh_token: string
  user: User
}

/**
 * Notificación del sistema
 */
export interface Notification {
  type: 'success' | 'error' | 'info' | 'warning'
  message: string
  duration?: number // ms, default 5000
}

/**
 * Respuesta paginada de la API
 */
export interface PaginatedResponse<T> {
  count: number
  next: string | null
  previous: string | null
  results: T[]
}

/**
 * Errores de validación
 */
export interface ValidationError {
  field: string
  message: string
}

/**
 * Respuesta de error de API
 */
export interface ApiError {
  detail?: string
  error?: string
  errors?: Record<string, string[]>
}
