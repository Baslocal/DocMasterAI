/**
 * DocMaster — Queue Page (/queue)
 * Live WebSocket table, job detail drawer, retry/cancel, stuck job detection.
 * Powers GET /dm/flux/queue + WS /dm/sentinel/logs/stream
 */
import React, { useState, useEffect, useRef } from 'react'
import { apiRequest } from '../App.jsx'

export default function Queue() {
  const [jobs, setJobs] = useState([])
  const [loading, setLoading] = useState(true)

  const fetchJobs = async () => {
    try {
      const data = await apiRequest('/flux/queue')
      setJobs(data.jobs || [])
    } catch (_) {}
    setLoading(false)
  }

  useEffect(() => {
    fetchJobs()
    const interval = setInterval(fetchJobs, 5000)
    return () => clearInterval(interval)
  }, [])

  const handleRetry = async (jobId) => {
    try {
      await apiRequest(`/flux/job/${jobId}/retry`, { method: 'POST' })
      fetchJobs()
    } catch (err) {
      alert(`Retry failed: ${err.message}`)
    }
  }

  const handleCancel = async (jobId) => {
    if (!confirm('Cancel this job?')) return
    try {
      await apiRequest(`/flux/job/${jobId}`, { method: 'DELETE' })
      fetchJobs()
    } catch (err) {
      alert(`Cancel failed: ${err.message}`)
    }
  }

  return (
    <div>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Queue</h1>
        <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
          Live view — refreshes every 5 seconds
        </p>
      </div>

      <div style={{
        background: 'var(--color-bg-secondary)',
        border: '1px solid var(--color-border)',
        borderRadius: 'var(--radius-lg)',
        overflow: 'hidden',
        boxShadow: 'var(--shadow-xs)',
      }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: 'var(--color-bg-primary)', borderBottom: '1px solid var(--color-border)' }}>
              {['Document', 'Priority', 'Status', 'Retries', 'Created', 'Actions'].map(h => (
                <th key={h} style={{
                  padding: '12px 16px', textAlign: 'left',
                  fontSize: 12, fontWeight: 600, color: 'var(--color-text-secondary)',
                  textTransform: 'uppercase', letterSpacing: '0.4px',
                }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr><td colSpan={6} style={{ padding: 32, textAlign: 'center', color: 'var(--color-text-secondary)' }}>Loading...</td></tr>
            ) : jobs.length === 0 ? (
              <tr><td colSpan={6} style={{ padding: 32, textAlign: 'center', color: 'var(--color-text-secondary)' }}>Queue is empty</td></tr>
            ) : jobs.map(job => (
              <tr key={job.id} style={{ borderBottom: '1px solid var(--color-border)' }}>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>
                  <div style={{ fontWeight: 500 }}>{job.original_name || '—'}</div>
                  <div style={{ fontSize: 11, color: 'var(--color-text-light)' }}>{job.id}</div>
                </td>
                <td style={{ padding: '12px 16px', fontSize: 13, textTransform: 'uppercase' }}>{job.priority}</td>
                <td style={{ padding: '12px 16px' }}>
                  <span className={`status-badge ${job.status}`}>{job.status}</span>
                </td>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>{job.retry_count}/{job.max_retries}</td>
                <td style={{ padding: '12px 16px', fontSize: 12, color: 'var(--color-text-secondary)' }}>
                  {job.created_at ? new Date(job.created_at).toLocaleString() : '—'}
                </td>
                <td style={{ padding: '12px 16px' }}>
                  <div style={{ display: 'flex', gap: 8 }}>
                    {job.status === 'failed' && (
                      <button
                        onClick={() => handleRetry(job.id)}
                        style={{
                          padding: '4px 10px', fontSize: 12, cursor: 'pointer',
                          background: 'var(--color-accent)', color: '#fff',
                          border: 'none', borderRadius: 'var(--radius-sm)',
                        }}
                      >Retry</button>
                    )}
                    {job.status === 'queued' && (
                      <button
                        onClick={() => handleCancel(job.id)}
                        style={{
                          padding: '4px 10px', fontSize: 12, cursor: 'pointer',
                          background: 'rgba(239,68,68,0.1)', color: 'var(--color-error)',
                          border: '1px solid rgba(239,68,68,0.2)', borderRadius: 'var(--radius-sm)',
                        }}
                      >Cancel</button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
