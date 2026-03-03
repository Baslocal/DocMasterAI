/**
 * DocMaster — Documents Page (/documents)
 * Paginated table, filter pills with live counts, bulk actions,
 * upload modal, document detail modal.
 * Powers GET /dm/core/documents
 */
import React, { useState, useEffect } from 'react'
import { apiRequest } from '../App.jsx'

const STATUS_FILTERS = ['queued', 'processing', 'complete', 'review', 'failed']

export default function Documents() {
  const [docs, setDocs] = useState([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [statusFilter, setStatusFilter] = useState(null)
  const [loading, setLoading] = useState(true)
  const [statusCounts, setStatusCounts] = useState({})

  const fetchDocs = async () => {
    setLoading(true)
    try {
      const params = new URLSearchParams({ page, limit: 25 })
      if (statusFilter) params.set('status', statusFilter)
      const data = await apiRequest(`/core/documents?${params}`)
      setDocs(data.documents)
      setTotal(data.total)
    } catch (_) {}
    setLoading(false)
  }

  const fetchCounts = async () => {
    try {
      const data = await apiRequest('/core/stats')
      setStatusCounts(data.by_status || {})
    } catch (_) {}
  }

  useEffect(() => { fetchDocs(); fetchCounts() }, [page, statusFilter])

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Documents</h1>
          <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
            {total.toLocaleString()} documents
          </p>
        </div>
      </div>

      {/* Filter Pills */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
        <button
          onClick={() => { setStatusFilter(null); setPage(1) }}
          className={`status-badge ${!statusFilter ? 'complete' : ''}`}
          style={{ cursor: 'pointer', border: 'none' }}
        >
          All ({total})
        </button>
        {STATUS_FILTERS.map(s => (
          <button
            key={s}
            onClick={() => { setStatusFilter(s); setPage(1) }}
            className={`status-badge ${s}`}
            style={{
              cursor: 'pointer', border: 'none',
              opacity: statusFilter === s ? 1 : 0.6,
            }}
          >
            {s} ({statusCounts[s] || 0})
          </button>
        ))}
      </div>

      {/* Table */}
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
              {['Document', 'Type', 'Status', 'Confidence', 'Pages', 'Ingested'].map(h => (
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
            ) : docs.length === 0 ? (
              <tr><td colSpan={6} style={{ padding: 32, textAlign: 'center', color: 'var(--color-text-secondary)' }}>No documents found</td></tr>
            ) : docs.map(doc => (
              <tr key={doc.id} style={{ borderBottom: '1px solid var(--color-border)' }}>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>
                  <div style={{ fontWeight: 500 }}>{doc.original_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--color-text-light)' }}>{doc.id}</div>
                </td>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>{doc.doc_type}</td>
                <td style={{ padding: '12px 16px' }}>
                  <span className={`status-badge ${doc.status}`}>{doc.status}</span>
                </td>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>
                  {doc.confidence_score != null ? (
                    <span className={
                      doc.confidence_score >= 90 ? 'confidence-high'
                      : doc.confidence_score >= 75 ? 'confidence-medium'
                      : 'confidence-low'
                    }>
                      {doc.confidence_score}%
                    </span>
                  ) : '—'}
                </td>
                <td style={{ padding: '12px 16px', fontSize: 13 }}>{doc.page_count}</td>
                <td style={{ padding: '12px 16px', fontSize: 12, color: 'var(--color-text-secondary)' }}>
                  {doc.ingested_at ? new Date(doc.ingested_at).toLocaleString() : '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
