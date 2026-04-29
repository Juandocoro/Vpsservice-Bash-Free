import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

// https://vitejs.dev/config/
export default defineConfig({
  // Plugins: React Fast Refresh para desarrollo rápido
  plugins: [react()],

  // Resolver: Alias para imports más limpios
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@components': path.resolve(__dirname, './src/components'),
      '@services': path.resolve(__dirname, './src/services'),
      '@store': path.resolve(__dirname, './src/store'),
      '@hooks': path.resolve(__dirname, './src/hooks'),
      '@types': path.resolve(__dirname, './src/types'),
      '@pages': path.resolve(__dirname, './src/pages'),
    },
  },

  // Server: Configuración para desarrollo
  server: {
    port: 5173,
    host: 'localhost',
    // Proxy para requests a /api hacia backend
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, '/api'),
      },
    },
  },

  // Build: Configuración para producción
  build: {
    outDir: 'dist',
    // Comprimir con Brotli
    rollupOptions: {
      output: {
        manualChunks: {
          // Separar vendor code
          'react': ['react', 'react-dom'],
          'zustand': ['zustand'],
          'axios': ['axios'],
        },
      },
    },
  },

  // Environment variables: Prefijo para variables accesibles desde cliente
  define: {
    'process.env.VITE_API_URL': JSON.stringify(
      process.env.VITE_API_URL || 'http://localhost:8000/api'
    ),
  },
})
