import './app.css'
import { KanbanModal } from './board/KanbanModal.js'
import { showToast } from './board/utils.js'

/**
 * Entry point — mounts the kanban board against the Shuttle daemon.
 *
 * The board is a vanilla-TS/DOM widget (no React); Stash/Capture and the
 * viewer arrive as React islands in later slices. `shuttleBase` defaults to
 * empty (relative) so fetches are same-origin: the served bundle hits its own
 * daemon at :4000 with no CORS, and `npm run dev` reaches :4000 through the
 * Vite proxy. Override with `VITE_SHUTTLE_BASE` to target an absolute daemon.
 */
const shuttleBase =
  (import.meta.env.VITE_SHUTTLE_BASE as string | undefined) ?? ''

const host = document.getElementById('app')
if (!host) throw new Error('#app host element is missing')

const board = new KanbanModal({
  shuttleBase,
  // Viewer seam (slice 3): a clicked card opens the fiber in the
  // @lightcone/renderer viewer ("opening a fiber = opening a file"). Until
  // that island lands, the FiberDetailModal shim routes here — surface intent.
  onOpenFiber: (card) => {
    showToast(`Viewer coming soon — ${card.id}`, 'success')
  },
  // Stash (`+`) / Capture (`✶`) header buttons stay hidden until their React
  // islands are wired (slice 2) — omitting the callbacks hides the buttons.
})

// Loom-wide view (cityScope: null) — the standalone UI is not city-scoped.
board.mount(host, { cityScope: null })
