import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// DocMaster UI — Vite configuration
// Output: www/dist/ → deployed to /opt/docmaster/www/
// STRICT RULE: Zero CDN dependency — all assets vendored
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    // Ensure no external CDN references survive the build
    rollupOptions: {
      output: {
        manualChunks: undefined,
      },
    },
  },
  server: {
    port: 3000,
    proxy: {
      '/dm': {
        target: 'https://localhost:8443',
        secure: false,
        changeOrigin: true,
      },
    },
  },
})
