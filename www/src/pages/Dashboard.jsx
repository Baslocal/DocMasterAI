/**
 * DocMaster — Dashboard Page (/)
 * KPI cards, trend chart (Chart.js), activity feed, review spotlight.
 * Powers GET /dm/core/stats
 */
import React, { useState, useEffect } from 'react'
import { apiRequest } from '../App.jsx'

export default function Dashboard({ operator }) {
  const [stats, setStats] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    apiRequest('/core/stats')
      .then(data => { setStats(data); setLoading(false) })
      .catch(() => setLoading(false))
  }, [])

  if (loading) return <div style={{ color: 'var(--color-text-secondary)' }}>Loading...</div>

  const summary = stats?.summary || {}
  const byStatus = stats?.by_status || {}

  const kpis = [
    { label: 'Processed Today', value: summary.processed_today ?? 0, color: 'var(--color-accent-dark)' },
    { label: 'Needs Review', value: summary.review_count ?? 0, color: 'var(--color-warning)' },
    { label: 'In Queue', value: summary.queued_count ?? 0, color: 'var(--color-text-secondary)' },
    { label: 'Avg Confidence', value: summary.avg_confidence ? `${summary.avg_confidence}%` : '—', color: 'var(--color-success)' },
  ]

  return (
    <div>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Dashboard</h1>
        <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
          Welcome back, {operator?.display_name}
        </p>
      </div>

      {/* KPI Cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 32 }}>
        {kpis.map(kpi => (
          <div key={kpi.label} style={{
            background: 'var(--color-bg-secondary)',
            border: '1px solid var(--color-border)',
            borderRadius: 'var(--radius-lg)',
            padding: '24px',
            boxShadow: 'var(--shadow-xs)',
          }}>
            <div style={{ color: 'var(--color-text-secondary)', fontSize: 12, textTransform: 'uppercase', letterSpacing: '0.5px', marginBottom: 8 }}>
              {kpi.label}
            </div>
            <div style={{ fontSize: 32, fontWeight: 700, color: kpi.color }}>
              {kpi.value}
            </div>
          </div>
        ))}
      </div>

      {/* Status Breakdown */}
      <div style={{
        background: 'var(--color-bg-secondary)',
        border: '1px solid var(--color-border)',
        borderRadius: 'var(--radius-lg)',
        padding: 24,
        boxShadow: 'var(--shadow-xs)',
      }}>
        <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>Documents by Status</h2>
        <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
          {Object.entries(byStatus).map(([status, count]) => (
            <div key={status} className={`status-badge ${status}`}>
              {status}: {count}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
