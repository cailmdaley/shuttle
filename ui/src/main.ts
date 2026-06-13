import './app.css'
import { KanbanModal } from './board/KanbanModal.js'
import { showToast } from './board/utils.js'
import { openStash, openCapture } from './forms/mountForms.js'

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
  // A clicked card opens the real FiberDetailModal panel directly (KanbanModal
  // owns it; card-click → openDetail → panel). `onOpenFiber` was Portolan's
  // "drill out to the full vellum workspace" escalation; the standalone UI has
  // no such target — the panel is the fiber view — so this stays a no-op,
  // wired only to satisfy the board's option shape.
  onOpenFiber: () => {},
  // Stash (`+`) / Capture (`✶`) header buttons — providing these callbacks is
  // what surfaces the buttons. Each opens its React island (slice 2); the
  // result lands as a board toast. The board polls, so a new card appears on
  // its own once the daemon writes the fiber / the capture session claims it.
  onStashClick: () => {
    void openStash({ shuttleBase, onResult: (msg, ok) => showToast(msg, ok ? 'success' : 'error') })
  },
  onNewIdeaClick: () => {
    void openCapture({ shuttleBase, onResult: (msg, ok) => showToast(msg, ok ? 'success' : 'error') })
  },
})

// Loom-wide view (cityScope: null) — the standalone UI is not city-scoped.
board.mount(host, { cityScope: null })
