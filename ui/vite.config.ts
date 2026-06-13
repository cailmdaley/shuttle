import { defineConfig } from 'vite'

/**
 * The Shuttle UI build.
 *
 * The board fetches the daemon with a *relative* base (`/api/v1/...`), so:
 *
 * Prod (`npm run build`): the daemon serves the bundle at :4000 (Plug.Static,
 * backend slice), so relative fetches are same-origin — zero CORS, zero
 * config. `base: ''` keeps asset URLs relative too, so the bundle works from
 * the daemon root or a subpath.
 *
 * Dev (`npm run dev`): this proxy forwards `/api` → the local daemon, so the
 * board's relative fetches reach :4000 without CORS regardless of dev port.
 * Point at a remote/non-default daemon with `VITE_SHUTTLE_API` (proxy target)
 * or `VITE_SHUTTLE_BASE` (absolute base, bypasses the proxy).
 */
const apiTarget = process.env.VITE_SHUTTLE_API ?? 'http://localhost:4000'

export default defineConfig({
  base: '',
  server: {
    port: 5174,
    proxy: {
      '/api': { target: apiTarget, changeOrigin: true },
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
})
