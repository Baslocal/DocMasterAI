/**
 * DocMaster — Search Page (/search)
 * Semantic vector search + keyword fallback.
 * Powers POST /dm/core/search
 */
import React, { useState } from 'react'
import { apiRequest } from '../App.jsx'

export default function Search() {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState(null)
  const [loading, setLoading] = useState(false)

  const handleSearch = async (e) => {
    e.preventDefault()
    if (!query.trim()) return
    setLoading(true)
    try {
      const data = await apiRequest('/core/search', {
        method: 'POST',
        body: JSON.stringify({ query, limit: 10 }),
      })
      setResults(data.results)
    } catch (_) {}
    setLoading(false)
  }

  return (
    <div>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.02em' }}>Search</h1>
        <p style={{ color: 'var(--color-text-secondary)', marginTop: 4, fontSize: 13.5 }}>
          Semantic search across all indexed documents
        </p>
      </div>

      <form onSubmit={handleSearch} style={{ marginBottom: 32 }}>
        <div style={{ display: 'flex', gap: 12 }}>
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Search documents..."
            style={{
              flex: 1, padding: '10px 16px',
              border: '1px solid var(--color-border)',
              borderRadius: 'var(--radius-md)', fontSize: 14,
            }}
          />
          <button
            type="submit"
            disabled={loading}
            style={{
              padding: '10px 24px',
              background: 'var(--color-accent)', color: '#fff',
              border: 'none', borderRadius: 'var(--radius-md)',
              fontSize: 14, fontWeight: 500, cursor: 'pointer',
            }}
          >{loading ? 'Searching...' : 'Search'}</button>
        </div>
      </form>

      {results && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {results.length === 0 ? (
            <p style={{ color: 'var(--color-text-secondary)' }}>No results found.</p>
          ) : results.map((r, i) => (
            <div key={i} style={{
              background: 'var(--color-bg-secondary)',
              border: '1px solid var(--color-border)',
              borderRadius: 'var(--radius-lg)',
              padding: 20,
              boxShadow: 'var(--shadow-xs)',
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
                <div style={{ fontWeight: 600 }}>{r.original_name}</div>
                <span className={`status-badge ${r.status}`}>{r.status}</span>
              </div>
              {r.chunk_text && (
                <p style={{ fontSize: 13, color: 'var(--color-text-secondary)', marginBottom: 8 }}>
                  {r.chunk_text.slice(0, 200)}...
                </p>
              )}
              <div style={{ fontSize: 11, color: 'var(--color-text-light)' }}>
                {r.doc_type} • {r.similarity ? `${(r.similarity * 100).toFixed(1)}% match` : 'text match'}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
