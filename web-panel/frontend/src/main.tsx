import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './index.css'

// Renderizar la aplicación React en el elemento #root del HTML
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
