/**
 * Offline visual-verification harness for the board's detail panel + chrome.
 *
 * WHY THIS EXISTS: the live daemon (:4000) is unreachable from any sandboxed
 * process (loopback is network-isolated; curl AND headless chromium both get
 * ECONNREFUSED). So the board can't be verified against the running daemon.
 * This harness builds a single self-contained IIFE bundle that mounts the real
 * components with MOCKED daemon responses, openable via `file://` and
 * screenshot-able with agent-browser. It is the verification surface for the
 * board-chrome-redesign constitution. Build: `npm run harness`. Open the
 * emitted harness-dist/index.html via file:// and screenshot.
 *
 * It stubs `window.fetch` for every daemon route the components touch, so what
 * you see is the real DOM/CSS the daemon would serve — only the data is mock.
 */
import { FiberDetailModal } from '../src/board/FiberDetailModal.js'
import type { KanbanCard } from '../src/board/KanbanTypes.js'

// ── Mock data ────────────────────────────────────────────────────────────────
const MOCK_UID = '01KVBR1F9BWBVKF97473PV67K8'
const MOCK_BODY = `The standalone Shuttle board is a lean web client the daemon serves at \`:4000\`.

## Desired State

This is mock fiber body markdown rendered by the lean \`marked\` renderer, styled
to read like a vellum page. It exists so the detail panel has realistic content
while we iterate on the **two-column file viewer** offline.

- A bulleted point about the chrome redesign.
- A second point with some \`inline code\`.
- A third, longer point so the prose column has enough text to show its measure
  and the manuscript typography at a real reading length.

### A subsection

More prose. The point of the harness is faithful CSS, not faithful data.`

const MOCK_SENT_FILES = [
  { fullPath: '/Users/cd280747/loom/.felt/loom/email/morning-post/report.html', basename: 'report.html', timestamp: 1781735408221, sessionId: '' },
  { fullPath: '/tmp/board-redesign-mockup.png', basename: 'board-redesign-mockup.png', timestamp: 1781732477899, sessionId: '' },
  { fullPath: '/Users/cd280747/loom/.felt/work/Tutorials/shapepipe-overview/shapepipe-overview.html', basename: 'shapepipe-overview.html', timestamp: 1781276942949, sessionId: '' },
]

const MOCK_CARD: KanbanCard = {
  id: 'ai-futures/portolan/standalone-kanban/board-chrome-redesign',
  uid: MOCK_UID,
  name: 'Board chrome + the fiber panel’s two-column file viewer',
  path: '/Users/cd280747/loom/.felt/ai-futures/portolan/standalone-kanban/board-chrome-redesign/board-chrome-redesign.md',
  fiberDir: '/Users/cd280747/loom/.felt/ai-futures/portolan/standalone-kanban/board-chrome-redesign',
  feltStore: '/Users/cd280747/loom',
  originId: 'local',
  status: 'active',
  outcome: 'BUILDING: chrome redesign + the new two-column multi-file viewer for the fiber panel. This lede shows the manuscript outcome treatment.',
  tags: ['constitution', 'kanban', 'portolan', 'design'],
  createdAt: '2026-06-17T23:33:19+02:00',
  dependsOnSatisfied: true,
}

// ── Fetch stub: stand in for the daemon ──────────────────────────────────────
const realFetch = window.fetch.bind(window)
window.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
  const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })

  // Fiber body
  if (url.includes('/api/v1/fibers/') && url.includes('body=true')) {
    return json({ fibers: [{ fiber: { body: MOCK_BODY } }] })
  }
  // Sent files (proper endpoint, once it exists)
  if (url.includes('/api/v1/sent-files')) return json({ files: MOCK_SENT_FILES })
  // Parent-picker index
  if (url.includes('/api/v1/fibers') && !url.includes('body=true')) return json({ fibers: [] })
  // Agent registry
  if (url.includes('/api/v1/agents')) return json({ agents: [] })
  // Legacy :4004 sent-files (current code path) — answer it too so the CURRENT
  // build shows files in the harness even before the repoint lands.
  if (url.includes('/sent-files')) return json({ files: MOCK_SENT_FILES })

  return realFetch(input as RequestInfo, init)
}) as typeof fetch

// ── Mount ────────────────────────────────────────────────────────────────────
const params = new URLSearchParams(location.search)
const modal = new FiberDetailModal(
  '', // shuttleBase relative
  () => {},
  () => {},
  undefined,
  undefined,
  undefined,
  undefined,
  {},
)
modal.open(MOCK_CARD)
// expose for agent-browser-driven interaction
;(window as unknown as { __harness: unknown }).__harness = { modal, MOCK_CARD, MOCK_SENT_FILES }
void params
