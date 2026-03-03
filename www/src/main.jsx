/**
 * DocMaster UI — Entry Point
 * React 18, compiled static bundle, zero CDN dependency.
 * JWT stored in memory only — NEVER localStorage.
 */
import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import './styles/tokens.css'

const root = createRoot(document.getElementById('root'))
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
