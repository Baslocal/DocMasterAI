/**
 * DocMaster UI — Application Shell
 *
 * Layout: Left sidebar (240px fixed) + Top bar (56px) + Main content (fluid)
 * Auth: JWT in memory only — never localStorage. 401 triggers re-auth prompt.
 * Routes: /, /documents, /queue, /search, /integrations, /health, /settings
 */
import React, { useState, useEffect, useCallback } from 'react'
import Dashboard from './pages/Dashboard.jsx'
import Documents from './pages/Documents.jsx'
import Queue from './pages/Queue.jsx'
import Search from './pages/Search.jsx'
import Integrations from './pages/Integrations.jsx'
import Health from './pages/Health.jsx'
import Settings from './pages/Settings.jsx'
import LoginScreen from './components/LoginScreen.jsx'

// ── API Client ─────────────────────────────────────────────────────────────
// Token stored in module-level closure — never written to localStorage or DOM
let _authToken = null

export function setAuthToken(token) { _authToken = token }
export function clearAuthToken() { _authToken = null }

export async function apiRequest(path, options = {}) {
  const headers = {
    'Content-Type': 'application/json',
    ...(options.headers || {}),
  }
  if (_authToken) {
    headers['Authorization'] = `Bearer ${_authToken}`
  }

  const resp = await fetch(`/dm${path}`, { ...options, headers })

  if (resp.status === 401) {
    clearAuthToken()
    window.dispatchEvent(new Event('dm:unauthorized'))
    throw new Error('DM_4011: Session expired')
  }

  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}))
    throw new Error(err.message || `HTTP ${resp.status}`)
  }

  return resp.json()
}

// ── Navigation config ─────────────────────────────────────────────────────
const NAV_ITEMS = [
  { id: 'dashboard',     label: 'Dashboard',     icon: '◈',  route: '/'              },
  { id: 'documents',     label: 'Documents',     icon: '📄', route: '/documents'      },
  { id: 'queue',         label: 'Queue',         icon: '⟳',  route: '/queue'          },
  { id: 'search',        label: 'Search',        icon: '⌕',  route: '/search'         },
  { id: 'integrations',  label: 'Integrations',  icon: '⇌',  route: '/integrations'   },
  { id: 'health',        label: 'System Health', icon: '♥',  route: '/health'         },
  { id: 'settings',      label: 'Settings',      icon: '⚙',  route: '/settings'       },
]

const PAGE_MAP = {
  '/':             Dashboard,
  '/documents':    Documents,
  '/queue':        Queue,
  '/search':       Search,
  '/integrations': Integrations,
  '/health':       Health,
  '/settings':     Settings,
}

export default function App() {
  const [authenticated, setAuthenticated] = useState(false)
  const [operator, setOperator] = useState(null)
  const [currentRoute, setCurrentRoute] = useState('/')
  const [stats, setStats] = useState(null)

  // Handle 401 events — triggers re-auth prompt
  useEffect(() => {
    const handler = () => setAuthenticated(false)
    window.addEventListener('dm:unauthorized', handler)
    return () => window.removeEventListener('dm:unauthorized', handler)
  }, [])

  const handleLogin = useCallback((token, operatorData) => {
    setAuthToken(token)
    setOperator(operatorData)
    setAuthenticated(true)
  }, [])

  const handleLogout = useCallback(async () => {
    try {
      await apiRequest('/vault/auth/logout', { method: 'POST' })
    } catch (_) {}
    clearAuthToken()
    setOperator(null)
    setAuthenticated(false)
  }, [])

  // Fetch top-bar stats
  useEffect(() => {
    if (!authenticated) return
    const fetchStats = async () => {
      try {
        const data = await apiRequest('/core/stats')
        setStats(data)
      } catch (_) {}
    }
    fetchStats()
    const interval = setInterval(fetchStats, 30000)
    return () => clearInterval(interval)
  }, [authenticated])

  if (!authenticated) {
    return <LoginScreen onLogin={handleLogin} />
  }

  const ActivePage = PAGE_MAP[currentRoute] || Dashboard

  return (
    <div style={{ display: 'flex', height: '100vh', overflow: 'hidden' }}>
      {/* ── Sidebar ─────────────────────────────────────────────────────── */}
      <aside style={{
        width: 'var(--sidebar-width)',
        background: 'var(--color-bg-dark)',
        color: '#fff',
        display: 'flex',
        flexDirection: 'column',
        flexShrink: 0,
        overflowY: 'auto',
      }}>
        {/* Logo */}
        <div style={{
          padding: '20px 16px 16px',
          borderBottom: '1px solid rgba(255,255,255,0.08)',
          display: 'flex',
          alignItems: 'center',
          gap: 12,
        }}>
          <div style={{
            width: 40, height: 40,
            background: 'var(--color-accent)',
            borderRadius: 'var(--radius-md)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontWeight: 800, fontSize: 17,
            color: 'var(--color-bg-dark)',
          }}>DM</div>
          <div>
            <div style={{ fontWeight: 700, fontSize: 16, letterSpacing: '-0.02em' }}>DocMaster</div>
            <div style={{ fontSize: 10, color: 'rgba(255,255,255,0.35)', marginTop: 1 }}>v1.0</div>
          </div>
        </div>

        {/* Navigation */}
        <nav style={{ flex: 1, padding: '8px 0' }}>
          {NAV_ITEMS.map(item => (
            <button
              key={item.id}
              onClick={() => setCurrentRoute(item.route)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                padding: '10px 12px',
                margin: '1px 8px',
                borderRadius: 'var(--radius-md)',
                color: currentRoute === item.route ? 'var(--color-bg-dark)' : 'rgba(255,255,255,0.65)',
                background: currentRoute === item.route ? 'var(--color-accent)' : 'transparent',
                border: 'none',
                cursor: 'pointer',
                fontSize: 13.5,
                fontWeight: currentRoute === item.route ? 600 : 400,
                width: 'calc(100% - 16px)',
                textAlign: 'left',
                transition: 'all 0.15s',
              }}
            >
              <span style={{ fontSize: 15, width: 18, textAlign: 'center' }}>{item.icon}</span>
              {item.label}
            </button>
          ))}
        </nav>

        {/* Footer — operator info + license status */}
        <div style={{ padding: '12px 16px', borderTop: '1px solid rgba(255,255,255,0.08)' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '10px 12px',
            background: 'rgba(16,185,129,0.12)',
            borderRadius: 'var(--radius-md)',
            border: '1px solid rgba(16,185,129,0.2)',
          }}>
            <div style={{
              width: 7, height: 7, borderRadius: '50%',
              background: 'var(--color-success)',
              flexShrink: 0,
            }} />
            <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.65)' }}>
              <div style={{ color: '#fff', fontSize: 12, fontWeight: 600 }}>
                {operator?.display_name || operator?.username}
              </div>
              <div>{operator?.role}</div>
            </div>
          </div>
          <button
            onClick={handleLogout}
            style={{
              marginTop: 8, width: '100%', padding: '6px 0',
              background: 'transparent', border: 'none',
              color: 'rgba(255,255,255,0.4)', cursor: 'pointer', fontSize: 12,
            }}
          >Sign out</button>
        </div>
      </aside>

      {/* ── Main area ────────────────────────────────────────────────────── */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        {/* Top bar */}
        <header style={{
          height: 'var(--topbar-height)',
          background: 'var(--color-bg-secondary)',
          borderBottom: '1px solid var(--color-border)',
          padding: '0 24px',
          display: 'flex',
          alignItems: 'center',
          gap: 16,
          flexShrink: 0,
        }}>
          <div style={{ flex: 1 }} />
          {/* Stats pills */}
          {stats && (
            <div style={{ display: 'flex', gap: 10 }}>
              {[
                { label: 'Today', val: stats.summary?.processed_today ?? 0, cls: 'accent' },
                { label: 'Review', val: stats.summary?.review_count ?? 0, cls: 'warn' },
                { label: 'Queue', val: stats.summary?.queued_count ?? 0, cls: '' },
              ].map(pill => (
                <div key={pill.label} style={{
                  padding: '6px 14px',
                  background: 'var(--color-bg-primary)',
                  border: '1px solid var(--color-border)',
                  borderRadius: 'var(--radius-md)',
                  textAlign: 'center',
                }}>
                  <div style={{ fontSize: 10, color: 'var(--color-text-secondary)', textTransform: 'uppercase', letterSpacing: '0.4px' }}>
                    {pill.label}
                  </div>
                  <div style={{
                    fontSize: 16, fontWeight: 700,
                    color: pill.cls === 'accent' ? 'var(--color-accent-dark)'
                         : pill.cls === 'warn' ? 'var(--color-warning)'
                         : 'var(--color-text-primary)',
                  }}>{pill.val}</div>
                </div>
              ))}
            </div>
          )}
        </header>

        {/* Content area */}
        <main style={{
          flex: 1,
          overflowY: 'auto',
          padding: 'var(--content-padding)',
          background: 'var(--color-bg-primary)',
        }}>
          <ActivePage operator={operator} />
        </main>
      </div>
    </div>
  )
}
