/**
 * DocMaster — Settings Page (/settings)
 * 8 sub-sections: General, OCR, Extraction, Storage, Security, License, Notifications, Advanced
 * Powers GET/PATCH /dm/vault/settings
 */
import React, { useState, useEffect } from 'react'
import { apiRequest } from '../App.jsx'

const SECTIONS = ['General', 'OCR', 'Extraction', 'Storage', 'Security', 'License', 'Notifications', 'Advanced']

export default function Settings() {
  const [activeSection, setActiveSection] = useState('General')
  const [settings, setSettings] = useState([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [changes, setChanges] = useState({})

  useEffect(() => {
    apiRequest('/vault/settings')
      .then(data => { setSettings(data); setLoading(false) })
      .catch(() => setLoading(false))
  }, [])

  const handleSave = async () => {
    setSaving(true)
    try {
      const updates = Object.entries(changes).map(([key, value]) => ({ key, value }))
      await apiRequest('/vault/settings', {
        method: 'PATCH',
        body: JSON.stringify(updates),
      })
      setChanges({})
      alert('Settings saved')
    } catch (err) {
      alert(`Save failed: ${err.message}`)
    }
    setSaving(false)
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Settings</h1>
          <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
            System configuration managed in dm_vault.system_config
          </p>
        </div>
        {Object.keys(changes).length > 0 && (
          <button
            onClick={handleSave}
            disabled={saving}
            style={{
              padding: '9px 18px', background: 'var(--color-accent)', color: '#fff',
              border: 'none', borderRadius: 'var(--radius-md)', cursor: 'pointer', fontSize: 13.5, fontWeight: 500,
            }}
          >{saving ? 'Saving...' : `Save ${Object.keys(changes).length} change(s)`}</button>
        )}
      </div>

      <div style={{ display: 'flex', gap: 24 }}>
        {/* Section Nav */}
        <div style={{ width: 200, flexShrink: 0 }}>
          {SECTIONS.map(s => (
            <button
              key={s}
              onClick={() => setActiveSection(s)}
              style={{
                display: 'block', width: '100%', textAlign: 'left',
                padding: '8px 12px', marginBottom: 2,
                background: activeSection === s ? 'rgba(56,189,248,0.1)' : 'transparent',
                color: activeSection === s ? 'var(--color-accent-dark)' : 'var(--color-text-primary)',
                border: 'none', borderRadius: 'var(--radius-md)',
                cursor: 'pointer', fontSize: 13.5, fontWeight: activeSection === s ? 600 : 400,
              }}
            >{s}</button>
          ))}
        </div>

        {/* Settings List */}
        <div style={{ flex: 1 }}>
          <div style={{
            background: 'var(--color-bg-secondary)',
            border: '1px solid var(--color-border)',
            borderRadius: 'var(--radius-lg)',
            overflow: 'hidden',
            boxShadow: 'var(--shadow-xs)',
          }}>
            {loading ? (
              <div style={{ padding: 32, color: 'var(--color-text-secondary)' }}>Loading...</div>
            ) : settings.map(s => (
              <div key={s.key} style={{
                padding: '16px 20px',
                borderBottom: '1px solid var(--color-border)',
                display: 'flex', alignItems: 'center', gap: 16,
              }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 500, fontSize: 13 }}>{s.key}</div>
                  {s.description && (
                    <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', marginTop: 2 }}>
                      {s.description}
                    </div>
                  )}
                </div>
                {s.is_encrypted ? (
                  <div style={{ fontSize: 12, color: 'var(--color-text-light)', fontStyle: 'italic' }}>
                    [encrypted]
                  </div>
                ) : (
                  <input
                    value={changes[s.key] ?? s.value}
                    onChange={e => setChanges(c => ({ ...c, [s.key]: e.target.value }))}
                    style={{
                      width: 240, padding: '6px 10px',
                      border: changes[s.key] !== undefined ? '1px solid var(--color-accent)' : '1px solid var(--color-border)',
                      borderRadius: 'var(--radius-sm)',
                      fontSize: 13,
                    }}
                  />
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}
