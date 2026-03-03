/**
 * DocMaster — System Health Page (/health)
 * Service cards, diagnostic suite, live log terminal, update panel.
 * Powers GET /dm/sentinel/health + POST /dm/sentinel/diagnostics
 */
import React, { useState, useEffect } from 'react'
import { apiRequest } from '../App.jsx'

const STATUS_COLOR = {
  ok: 'var(--color-success)',
  degraded: 'var(--color-warning)',
  critical: 'var(--color-error)',
  unavailable: 'var(--color-error)',
}

export default function Health() {
  const [health, setHealth] = useState(null)
  const [diagnostics, setDiagnostics] = useState(null)
  const [loading, setLoading] = useState(true)

  const fetchHealth = async () => {
    try {
      const resp = await fetch('/dm/sentinel/health')
      const data = await resp.json()
      setHealth(data)
    } catch (_) {}
    setLoading(false)
  }

  const runDiagnostics = async () => {
    try {
      const data = await apiRequest('/sentinel/diagnostics', { method: 'POST' })
      setDiagnostics(data)
    } catch (err) {
      alert(`Diagnostics failed: ${err.message}`)
    }
  }

  useEffect(() => {
    fetchHealth()
    const interval = setInterval(fetchHealth, 30000)
    return () => clearInterval(interval)
  }, [])

  if (loading) return <div style={{ color: 'var(--color-text-secondary)' }}>Loading...</div>

  const components = health?.components || {}

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>System Health</h1>
          <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
            Overall: <span style={{ fontWeight: 600, color: STATUS_COLOR[health?.status || 'unknown'] }}>
              {health?.status?.toUpperCase() || 'Unknown'}
            </span>
          </p>
        </div>
        <button
          onClick={runDiagnostics}
          style={{
            padding: '9px 18px', background: 'var(--color-accent)', color: '#fff',
            border: 'none', borderRadius: 'var(--radius-md)', cursor: 'pointer', fontSize: 13.5, fontWeight: 500,
          }}
        >Run Diagnostics</button>
      </div>

      {/* Component Cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))', gap: 16, marginBottom: 32 }}>
        {Object.entries(components).map(([name, comp]) => (
          <div key={name} style={{
            background: 'var(--color-bg-secondary)',
            border: '1px solid var(--color-border)',
            borderRadius: 'var(--radius-lg)',
            padding: 20,
            boxShadow: 'var(--shadow-xs)',
          }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div style={{ fontWeight: 600, fontSize: 14 }}>{name}</div>
              <div style={{
                width: 10, height: 10, borderRadius: '50%',
                background: STATUS_COLOR[comp.status] || 'var(--color-text-secondary)',
              }} />
            </div>
            <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', marginTop: 4 }}>
              {comp.status}
              {comp.error && ` — ${comp.error}`}
            </div>
          </div>
        ))}
      </div>

      {/* Diagnostics Output */}
      {diagnostics && (
        <div style={{
          background: 'var(--color-bg-secondary)',
          border: '1px solid var(--color-border)',
          borderRadius: 'var(--radius-lg)',
          padding: 24,
          boxShadow: 'var(--shadow-xs)',
        }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>Diagnostic Results</h2>
          <pre style={{
            background: 'var(--color-bg-primary)',
            borderRadius: 'var(--radius-md)',
            padding: 16,
            fontSize: 12,
            overflow: 'auto',
            maxHeight: 400,
          }}>
            {JSON.stringify(diagnostics, null, 2)}
          </pre>
        </div>
      )}
    </div>
  )
}
