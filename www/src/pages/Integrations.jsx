/**
 * DocMaster — Integrations Page (/integrations)
 * Connector cards, enable/disable, test connectivity, manual sync.
 * Powers GET/PATCH /dm/bridge/connectors
 */
import React, { useState, useEffect } from 'react'
import { apiRequest } from '../App.jsx'

export default function Integrations() {
  const [connectors, setConnectors] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchConnectors = async () => {
    try {
      const data = await apiRequest('/bridge/connectors')
      setConnectors(data.connectors || [])
    } catch (_) {}
    setLoading(false)
  }

  const toggleConnector = async (name, enabled) => {
    try {
      await apiRequest(`/bridge/connectors/${name}`, {
        method: 'PATCH',
        body: JSON.stringify({ is_enabled: enabled }),
      })
      fetchConnectors()
    } catch (err) {
      alert(`Failed: ${err.message}`)
    }
  }

  const triggerSync = async (name) => {
    try {
      await apiRequest(`/bridge/connectors/${name}/sync`, { method: 'POST' })
      alert(`Sync queued for ${name}`)
    } catch (err) {
      alert(`Sync failed: ${err.message}`)
    }
  }

  useEffect(() => { fetchConnectors() }, [])

  return (
    <div>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Integrations</h1>
        <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
          External connectors managed by dm-bridge.service
        </p>
      </div>

      {loading ? <div style={{ color: 'var(--color-text-secondary)' }}>Loading...</div> : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
          {connectors.map(c => (
            <div key={c.connector_name} style={{
              background: 'var(--color-bg-secondary)',
              border: '1px solid var(--color-border)',
              borderRadius: 'var(--radius-lg)',
              padding: 24,
              boxShadow: 'var(--shadow-xs)',
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 12 }}>
                <div style={{ fontWeight: 600, fontSize: 15 }}>{c.connector_name}</div>
                <span style={{
                  fontSize: 11, fontWeight: 600, padding: '2px 8px',
                  borderRadius: 'var(--radius-full)',
                  background: c.is_enabled ? 'rgba(16,185,129,0.1)' : 'rgba(100,116,139,0.1)',
                  color: c.is_enabled ? 'var(--color-success)' : 'var(--color-text-secondary)',
                }}>
                  {c.is_enabled ? 'Enabled' : 'Disabled'}
                </span>
              </div>
              {c.last_sync_at && (
                <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', marginBottom: 12 }}>
                  Last sync: {new Date(c.last_sync_at).toLocaleString()}
                  {c.last_sync_status && ` (${c.last_sync_status})`}
                </div>
              )}
              <div style={{ display: 'flex', gap: 8 }}>
                <button
                  onClick={() => toggleConnector(c.connector_name, !c.is_enabled)}
                  style={{
                    padding: '6px 12px', fontSize: 12, cursor: 'pointer',
                    background: 'var(--color-bg-primary)',
                    border: '1px solid var(--color-border)',
                    borderRadius: 'var(--radius-sm)',
                  }}
                >{c.is_enabled ? 'Disable' : 'Enable'}</button>
                {c.is_enabled && (
                  <button
                    onClick={() => triggerSync(c.connector_name)}
                    style={{
                      padding: '6px 12px', fontSize: 12, cursor: 'pointer',
                      background: 'var(--color-accent)', color: '#fff',
                      border: 'none', borderRadius: 'var(--radius-sm)',
                    }}
                  >Sync Now</button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
