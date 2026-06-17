import { renderMarkdown, renderEmbeds } from './utils.js'
import type { ColumnKind, KanbanCard } from './KanbanTypes.js'
import { dispatchIneligibleReason, errorMessageFromResponse, isAgentCard } from './KanbanModalShared.js'
import { fetchFiberIndex, filterParentCandidates, type FiberSearchResult } from './fiberSearch.js'
import {
  animatePanelGeometry,
  attachPanelDrag,
  attachPanelResize,
  readPanelGeometry,
  type PanelGeometry,
} from './FloatingPanelChrome.js'
import { FileViewerPanel } from './FileViewerPanel.js'
import './FiberDetailModal.css'

/**
 * Panel geometry remembered across opens within a session — the reader who
 * dragged the page to the right edge to watch a fiber while working the
 * board gets the same placement on the next card. Cleared on reload.
 */
let lastGeometry: { left: number; top: number; width: number; height: number } | null = null

const MIN_WIDTH = 380
const MIN_HEIGHT = 320

/**
 * One entry of the daemon's `GET /api/v1/agents` registry. The axis metadata
 * (`effort_levels`, `default_effort`, `chrome_capable`) populates the agent
 * picker's effort options and chrome toggle without any hardcoded option list
 * in the frontend — the registry is the single source of truth. `alias_of` is
 * set on convenience records (e.g. `claude-opus-chrome`) that the base-agent
 * select filters out.
 */
interface AgentRecord {
  id: string
  model?: string
  default?: boolean
  effort_levels?: string[]
  default_effort?: string | null
  chrome_capable?: boolean
  cost_class?: string | null
  alias_of?: string | null
}

/**
 * FiberDetailModal — one click on a kanban card opens the fiber itself.
 *
 * A floating, draggable, edge-and-corner-resizable panel whose body is a
 * single-column page: outcome lede, then the markdown body. The standalone
 * UI emulates the vellum look in CSS rather than importing vellum's
 * `NarrativeView`/PretextProse stack — the body is rendered by the lean
 * `marked` renderer (`utils.renderMarkdown`) and styled to read like a
 * vellum page (`.kbn-detail-prose` in FiberDetailModal.css). The markdown
 * comes from the daemon's `GET /api/v1/fibers/<id>?body=true`; a fiber whose
 * body the local daemon can't read (remote origin — owner-routed body is a
 * later slice) degrades to its outcome, which the composite feed always
 * carries. `:::{embed}` artifacts and relative images render through the
 * daemon's owner-routed `/file` route, anchored on the fiber's own dir.
 *
 * Every card action lives in one dropdown directly under the title,
 * collapsed by default: directive box + "wait for me", New session /
 * Resume, Temper / Compost, agent / kind / schedule, tags, parent fiber,
 * and the drill-out to the full workspace.
 *
 * Deliberately NOT a Radix AppDialog and NOT background-locked: the panel
 * is non-modal by design — "drag it aside to keep an eye on one fiber
 * while working the board" requires the kanban behind it to stay
 * interactive, so there is no scrim, no focus trap, no body-inert. This is
 * the documented exception to the new-modal invariant. Escape still
 * closes; only one instance is open at a time. The root keeps the
 * `.kbn-detail-overlay` class so Camera's wheel-exemption `closest()`
 * list keeps routing wheel events to the panel instead of zooming the map.
 *
 * Lifecycle: `open(card)` mounts the panel; `close()` tears it down
 * (including the React root inside the page pane).
 */
export class FiberDetailModal {
  private overlay: HTMLElement | null = null
  private escapeHandler: ((e: KeyboardEvent) => void) | null = null
  private outsideHandler: ((e: PointerEvent) => void) | null = null
  private searchDebounce: number | null = null
  /** ResizeObservers watching full-length HTML embeds so they re-fit their
   *  height when the panel reflows their content (see autosizeEmbeds).
   *  Disconnected on close so a re-opened panel never leaks observers. */
  private embedObservers: ResizeObserver[] = []
  /** Shuttle daemon base (`:4000`). Every verb routes here — transition,
   *  dispatch, felt-edit, felt-history, lifecycle, felt-nest — owner-routed
   *  by the card's `originId` carried as `origin` in the body. Reads (agent
   *  registry, parent-picker fiber index) hit the daemon's GET routes.
   *  Portolan's `:4004` no longer serves the kanban at all. */
  private readonly shuttleBase: string
  /** Map a card's `cityId` to the city's project directory — the
   *  `project_dir` a shuttle install needs (worker cwd). Wired from the
   *  parent kanban's pinned-city roots; absent in tests/embeds, where
   *  promotion installs without a project dir (valid for paused drafts). */
  private readonly resolveCityProjectPath?: (cityId: string) => string | undefined
  /** Parent-picker index: one `GET /api/v1/fibers` per panel-open, filtered
   *  client-side per keystroke. Cleared on close. */
  private fiberIndex: Promise<Array<{ id: string; name: string }>> | null = null
  /** Monotonic guard so only the latest searchParents call renders the
   *  dropdown — see the comment inside searchParents. */
  private searchRenderToken = 0
  private readonly onSaved: () => void
  private readonly onAttachFreshTmux?: (tmuxSessionName: string) => void
  /** Focus an already-running worker's kitty tab. Wired from the parent
   *  kanban's onOpenWorker; drives the status pill's double-click. */
  private readonly onOpenWorker?: (tmuxSessionName: string, shuttleHost?: string) => void
  /**
   * Terminal-move delegate. When wired, Temper / Compost close the panel
   * immediately and hand the move to the parent kanban's optimistic
   * transition path (instant card relocation + background commit + banner
   * on failure) instead of blocking on an in-panel fetch. Absent → the
   * legacy in-panel `runTransition` fetch runs.
   */
  private readonly onTransition?: (card: KanbanCard, target: ColumnKind) => void
  /** Escalate a sent deliverable to vellum's full file workspace (the
   *  viewer panel's ↗). Wired from the parent kanban's onOpenFile
   *  (→ mountContext.openFile → portolan's openFile helper); absent in
   *  tests/embeds, where the viewer panel just omits the glyph. */
  private readonly onOpenFile?: (fullPath: string, originId: string) => void
  /** Portolan backend base (`:4004`) — the sent-files trail lives there
   *  (it's activity-stream data, not fiber state), unlike every shuttle-
   *  routed verb on `shuttleBase`. Overridable for tests. */
  private readonly portolanBase: string
  /** Floating sent-file viewer — a sibling panel, so clicking a deliverable
   *  shows it *beside* the card instead of mode-switching the workspace. */
  private readonly fileViewer: FileViewerPanel
  /** Where this panel sat before sliding into split view — restored (with
   *  the same glide) when the viewer closes. Null when not in split. */
  private preSplitGeometry: PanelGeometry | null = null

  constructor(
    shuttleBase: string,
    // Accepted for positional signature compatibility with KanbanModal's call
    // (and Portolan's panel), but unused in the standalone UI: there's no full
    // workspace to "open elsewhere" — the panel itself is the fiber view.
    _onOpenFiber: (card: KanbanCard, options?: { openInNewWindow?: boolean }) => void,
    onSaved: () => void,
    onAttachFreshTmux?: (tmuxSessionName: string) => void,
    onTransition?: (card: KanbanCard, target: ColumnKind) => void,
    onOpenWorker?: (tmuxSessionName: string, shuttleHost?: string) => void,
    resolveCityProjectPath?: (cityId: string) => string | undefined,
    opts?: { onOpenFile?: (fullPath: string, originId: string) => void; portolanBase?: string },
  ) {
    this.shuttleBase = shuttleBase
    this.resolveCityProjectPath = resolveCityProjectPath
    this.onSaved = onSaved
    this.onAttachFreshTmux = onAttachFreshTmux
    this.onTransition = onTransition
    this.onOpenWorker = onOpenWorker
    this.onOpenFile = opts?.onOpenFile
    this.portolanBase = opts?.portolanBase ?? 'http://localhost:4004'
    this.fileViewer = new FileViewerPanel({
      portolanBase: this.portolanBase,
      onOpenInWorkspace: this.onOpenFile
        ? (fullPath, originId) => {
            // Escalating to the full file workspace: clear both panels so
            // the workspace's file mode isn't hidden behind them.
            this.close()
            this.onOpenFile?.(fullPath, originId)
          }
        : undefined,
      onClosed: () => this.exitSplitView(),
    })
  }

  /**
   * @param card the card the user clicked
   * @param scopeCityId  the cityId the parent kanban view is scoped to
   *   (`undefined` for the global kanban). Drives the vellum content fetch
   *   only — card ids are loom-relative everywhere (the composite feed),
   *   and every write is owner-routed by `card.originId`, so no endpoint
   *   needs city-scoped URL routing anymore.
   */
  open(card: KanbanCard, scopeCityId?: string | null, _columnKind?: ColumnKind): void {
    // Tear down any existing open panel first (rapid re-click).
    this.close()

    // ── Panel root ──────────────────────────────────────────────────────────
    // Non-modal floating panel (see class docstring). role="dialog" without
    // aria-modal: the board behind stays in the a11y tree on purpose.
    const overlay = document.createElement('div')
    overlay.className = 'kbn-detail-overlay'
    overlay.setAttribute('role', 'dialog')
    overlay.setAttribute('aria-label', `Fiber: ${card.name}`)
    this.applyGeometry(overlay)

    // ── Header (drag handle) ────────────────────────────────────────────────
    const header = document.createElement('div')
    header.className = 'kbn-detail-header'

    // The title is plain identification text + the drag handle. In the
    // standalone UI the panel *is* the fiber view, so there is no "drill out
    // to the full workspace" target — the click-to-open-elsewhere affordance
    // Portolan's title carried is dropped.
    const title = document.createElement('div')
    title.className = 'kbn-detail-title'
    title.textContent = card.name

    const pill = document.createElement('span')
    pill.className = `kbn-pill kbn-pill-${card.status === 'closed' ? 'closed' : card.status === 'active' ? 'active' : 'open'}`
    pill.textContent = card.status || 'open'

    // Worker aloft → the same teal ▸ aloft pill the grid card wears, same
    // class, same gesture: click opens the worker's tmux session in kitty.
    let aloftPill: HTMLButtonElement | null = null
    if (card.runningWorker && this.onOpenWorker) {
      const tmuxName = card.runningWorker
      aloftPill = document.createElement('button')
      aloftPill.type = 'button'
      aloftPill.className = 'kbn-card-worker kbn-detail-aloft'
      aloftPill.setAttribute('aria-label', `Open worker terminal: ${tmuxName}`)
      aloftPill.title = `Worker aloft — click to open ${tmuxName} in kitty`
      aloftPill.textContent = '▸ aloft'
      aloftPill.addEventListener('click', (e) => {
        e.stopPropagation()
        this.onOpenWorker?.(tmuxName, card.shuttleHost)
      })
    }

    const closeBtn = document.createElement('button')
    closeBtn.type = 'button'
    closeBtn.className = 'kbn-detail-close'
    closeBtn.setAttribute('aria-label', 'Close fiber detail')
    closeBtn.textContent = '×'
    closeBtn.addEventListener('click', () => this.close())

    // ID breadcrumb under the title — plain identification text; the title
    // above carries the click-to-vellum affordance.
    const idEl = document.createElement('div')
    idEl.className = 'kbn-detail-id'
    idEl.textContent = card.id

    const titleStack = document.createElement('div')
    titleStack.className = 'kbn-detail-title-stack'
    titleStack.append(title, idEl)
    if (aloftPill) header.append(titleStack, aloftPill, pill, closeBtn)
    else header.append(titleStack, pill, closeBtn)
    this.attachDrag(overlay, header)

    // ── Controls dropdown ───────────────────────────────────────────────────
    // One cluster, directly under the title, collapsed by default. Expanded
    // it holds the directive entry and every action the card supports.
    const scope = scopeCityId ?? undefined
    const shuttleManaged = isAgentCard(card)
    const controls = this.buildControls(card, scope, shuttleManaged)

    // ── Fiber body pane ─────────────────────────────────────────────────────
    // The fiber itself: outcome lede, then the markdown body, rendered by the
    // lean `marked` renderer and styled to read like a vellum page (see the
    // class docstring). Fetched async so the grid path pays nothing until a
    // card is opened; a remote fiber (whose body the local daemon can't read)
    // degrades to its outcome.
    const page = document.createElement('div')
    page.className = 'kbn-detail-page kbn-detail-page-headerless'
    const prose = document.createElement('article')
    prose.className = 'kbn-detail-prose'
    prose.innerHTML = '<p class="kbn-detail-prose-loading">Loading…</p>'
    page.append(prose)
    void this.renderFiberBody(prose, card, overlay)

    // ── Sent files strip ────────────────────────────────────────────────────
    // The deliverable trail: files the card's worker sessions pushed via
    // SendUserFile, newest first, served by portolan's /sent-files keyed on
    // the Claude session UUID the card carries (shuttle.session.id). Empty
    // or unresolvable → the strip never mounts; the panel looks unchanged.
    const sentFiles = this.buildSentFiles(card)

    // ── Assemble ────────────────────────────────────────────────────────────
    overlay.append(header, controls, sentFiles, page)
    this.attachResizeHandles(overlay)
    document.body.append(overlay)
    this.overlay = overlay

    // Escape to close the panel. When the parent-fiber dropdown is open and
    // focus is inside it, yield to the dropdown's own keydown listener so it
    // can close just the dropdown (not the whole panel).
    this.escapeHandler = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      if (document.activeElement?.closest('.kbn-detail-parent-dropdown')) return
      this.close()
    }
    document.addEventListener('keydown', this.escapeHandler, true)

    // Click-away closes the panel. pointerdown (not click) so the gesture
    // that opened the panel — whose pointerdown happened before this
    // listener existed — can never self-close it. The event is left to
    // propagate, so the outside click still does its own work (open a
    // different card, drag on the board, …).
    this.outsideHandler = (e: PointerEvent) => {
      const target = e.target as Node | null
      if (target && overlay.contains(target)) return
      // The floating sent-file viewer is a sibling panel spawned from this
      // one — interacting with it isn't "away".
      if (target instanceof Element && target.closest('.kbn-fileview-overlay')) return
      this.close()
    }
    document.addEventListener('pointerdown', this.outsideHandler, true)
  }

  close(): void {
    if (this.escapeHandler) {
      document.removeEventListener('keydown', this.escapeHandler, true)
      this.escapeHandler = null
    }
    if (this.outsideHandler) {
      document.removeEventListener('pointerdown', this.outsideHandler, true)
      this.outsideHandler = null
    }
    if (this.searchDebounce !== null) {
      window.clearTimeout(this.searchDebounce)
      this.searchDebounce = null
    }
    this.fiberIndex = null
    for (const ro of this.embedObservers) ro.disconnect()
    this.embedObservers = []
    this.overlay?.remove()
    this.overlay = null
    // The split is an arrangement between this panel and its viewer —
    // closing the card dissolves it. Otherwise the orphaned viewer's later
    // close would glide the *next* card to this card's stale pre-split
    // spot. Clear the stash first: the viewer's onClosed → exitSplitView
    // fires synchronously inside close() and must find nothing to restore.
    this.preSplitGeometry = null
    this.fileViewer.close()
  }

  /**
   * Fetch the fiber's markdown body from the daemon and render it into the
   * page pane, styled to read like a vellum page. The body endpoint
   * (`GET /api/v1/fibers/<id>?body=true`) is local-only — a remote fiber's
   * body can't be read from here, so it degrades to the outcome, which the
   * composite feed always carries. `:::{embed}` artifacts and relative images
   * resolve through the daemon's `/file` route, anchored on the fiber's dir
   * (`card.fiberDir`); an unresolvable path falls back to a placeholder.
   */
  private async renderFiberBody(
    prose: HTMLElement,
    card: KanbanCard,
    overlay: HTMLElement,
  ): Promise<void> {
    // Render the outcome (the card already carries it) IMMEDIATELY, so the
    // panel is never blank: the daemon's body read (`?body=true`) can take
    // several seconds under poll-load, and a bare "Loading…" reads as broken.
    // The body then fills in below the lede, or degrades to a clear note.
    const outcome = (card.outcome ?? '').trim()
    const lede = outcome
      ? `<div class="kbn-detail-lede">${renderMarkdown(outcome)}</div>`
      : ''
    prose.innerHTML = lede + '<p class="kbn-detail-body-status">loading body…</p>'

    let body = ''
    let reached = false
    try {
      const idPath = card.id.split('/').map(encodeURIComponent).join('/')
      const ctrl = new AbortController()
      const timer = window.setTimeout(() => ctrl.abort(), 25000)
      const res = await fetch(`${this.shuttleBase}/api/v1/fibers/${idPath}?body=true`, {
        signal: ctrl.signal,
      })
      window.clearTimeout(timer)
      if (res.ok) {
        const data = (await res.json()) as {
          fibers?: Array<{ fiber?: { body?: string } }>
        }
        body = (data.fibers?.[0]?.fiber?.body ?? '').trim()
        reached = true
      }
    } catch {
      // abort / timeout / network — `reached` stays false.
    }
    // The panel may have closed (or been replaced) while we awaited.
    if (this.overlay !== overlay) return

    if (body) {
      // Resolve a relative `:::{embed}` / image against the fiber's own dir
      // (carried on the card from the composite feed) and route the bytes
      // through `/file`. A fiber whose dir didn't resolve degrades to embed
      // placeholders + un-rewritten images, but the prose still reads.
      const bodyOpts = { basePath: card.fiberDir, originId: card.originId }
      prose.innerHTML = lede + renderMarkdown(renderEmbeds(body, bodyOpts), bodyOpts)
      this.autosizeEmbeds(prose)
      return
    }
    if (!outcome && reached) {
      prose.classList.add('kbn-detail-prose-empty')
      prose.textContent = 'No body or outcome yet.'
      return
    }
    // No body: either the daemon answered but had nothing local (remote-origin
    // fiber) or the read failed/timed out. Keep the outcome; explain + (on
    // failure) offer a retry.
    const note = reached
      ? 'Body lives on the owning host — cross-host body rendering is a later slice; the outcome above is the headline.'
      : 'Couldn’t load the body — the daemon was slow to respond. <button type="button" class="kbn-detail-body-retry">retry</button>'
    prose.innerHTML = lede + `<p class="kbn-detail-prose-note">${note}</p>`
    if (!reached) {
      prose.querySelector('.kbn-detail-body-retry')?.addEventListener('click', () => {
        void this.renderFiberBody(prose, card, overlay)
      })
    }
  }

  /**
   * Grow full-length HTML embeds (`iframe[data-autosize]`, emitted by
   * utils.embedHtml for a `:::{embed} report.html` with no pinned `:height:`)
   * to their own content height, so the artifact reads as part of the page —
   * one scroll column, no nested scrollbar. The iframe is served from the same
   * origin (the daemon's `/file` route on :4000), so its document is readable:
   * on load we size to the content's scrollHeight, and a ResizeObserver on its
   * body re-fits whenever a panel resize reflows the content. A cross-origin or
   * unreadable doc silently keeps the CSS min-height.
   */
  private autosizeEmbeds(prose: HTMLElement): void {
    const frames = prose.querySelectorAll<HTMLIFrameElement>('iframe[data-autosize]')
    frames.forEach((iframe) => {
      const fit = () => {
        try {
          const doc = iframe.contentDocument
          if (!doc) return
          const h = Math.max(
            doc.documentElement?.scrollHeight ?? 0,
            doc.body?.scrollHeight ?? 0,
          )
          if (h > 0) iframe.style.height = `${h}px`
        } catch {
          /* cross-origin / unreadable — leave the CSS min-height in place */
        }
      }
      iframe.addEventListener('load', () => {
        fit()
        try {
          const doc = iframe.contentDocument
          if (doc?.body && typeof ResizeObserver !== 'undefined') {
            const ro = new ResizeObserver(() => fit())
            ro.observe(doc.body)
            this.embedObservers.push(ro)
          }
        } catch {
          /* ignore — observation is best-effort */
        }
      })
      // A cached doc may have finished loading before the listener attached.
      try {
        if (iframe.contentDocument?.readyState === 'complete') fit()
      } catch {
        /* ignore */
      }
    })
  }

  // ── Panel geometry: default + remembered, drag, resize ────────────────────

  /** Default size: a reading column at nearly full viewport height — the
   *  page wants vertical room; width stays a comfortable measure.
   *  Remembered geometry wins when it still fits the viewport. */
  private applyGeometry(overlay: HTMLElement): void {
    const vw = window.innerWidth
    const vh = window.innerHeight
    let g = lastGeometry
    if (g && (g.left > vw - 80 || g.top > vh - 80)) g = null
    const width = g?.width ?? Math.min(950, Math.round(vw * 0.92))
    const height = g?.height ?? vh - 24
    const left = g?.left ?? Math.round((vw - width) / 2)
    const top = g?.top ?? Math.round((vh - height) / 2)
    overlay.style.left = `${Math.max(0, left)}px`
    overlay.style.top = `${Math.max(0, top)}px`
    overlay.style.width = `${width}px`
    overlay.style.height = `${height}px`
  }

  private rememberGeometry(overlay: HTMLElement): void {
    lastGeometry = readPanelGeometry(overlay)
  }

  // ── Split view: card left, sent-file viewer right ──────────────────────

  /** Glide this panel to the left half of the viewport and open the viewer
   *  on the right half. The pre-split position is stashed once (a second
   *  file clicked mid-split keeps the original restore target) and *not*
   *  written to `lastGeometry` — the split is a temporary arrangement, not
   *  the user's chosen card position. */
  private openInSplitView(fullPath: string, originId: string): void {
    const overlay = this.overlay
    if (!overlay) {
      this.fileViewer.open(fullPath, originId)
      return
    }
    const GUTTER = 12
    const vw = window.innerWidth
    const vh = window.innerHeight
    const half = Math.floor((vw - 3 * GUTTER) / 2)
    const top = GUTTER
    const height = vh - 2 * GUTTER

    if (!this.fileViewer.isOpen()) {
      this.preSplitGeometry = readPanelGeometry(overlay)
    }
    animatePanelGeometry(overlay, { left: GUTTER, top, width: half, height })
    this.fileViewer.open(fullPath, originId, {
      geometry: { left: 2 * GUTTER + half, top, width: half, height },
    })
  }

  /** Viewer closed (×, Escape, ↗, or replaced): glide the panel back to
   *  where it sat before the split. No-ops when the panel itself is gone
   *  or was never split. */
  private exitSplitView(): void {
    if (this.overlay && this.preSplitGeometry) {
      animatePanelGeometry(this.overlay, this.preSplitGeometry)
    }
    this.preSplitGeometry = null
  }

  /** Header-strip drag. Plain pointer drag — the header is dedicated chrome,
   *  so no modifier gate is needed (the Cmd-gate lesson from the pin-card
   *  prototype applies to chrome-less surfaces where drag fights text
   *  selection; a title bar doesn't). Buttons and form fields opt out. */
  private attachDrag(overlay: HTMLElement, handle: HTMLElement): void {
    attachPanelDrag(overlay, handle, {
      draggingClass: 'kbn-detail-dragging',
      onSettle: () => this.rememberGeometry(overlay),
    })
  }

  /** Eight invisible resize zones on the edges and corners. Pointer-based,
   *  same lifecycle as drag; min size keeps the header + dropdown usable. */
  private attachResizeHandles(overlay: HTMLElement): void {
    attachPanelResize(overlay, {
      handleClassPrefix: 'kbn-detail-rh',
      resizingClass: 'kbn-detail-resizing',
      minWidth: MIN_WIDTH,
      minHeight: MIN_HEIGHT,
      onSettle: () => this.rememberGeometry(overlay),
    })
  }

  // ── Controls dropdown ───────────────────────────────────────────────────

  /**
   * The one cluster holding every card action. Collapsed: a slim toggle row
   * with at-a-glance worker chips. Expanded: directive + dispatch actions,
   * review moves, worker config (agent / kind / schedule), tags, parent,
   * and the drill-out to the full workspace.
   */
  private buildControls(
    card: KanbanCard,
    scope: string | undefined,
    shuttleManaged: boolean,
  ): HTMLElement {
    const wrap = document.createElement('div')
    wrap.className = 'kbn-detail-controls'

    const toggle = document.createElement('button')
    toggle.type = 'button'
    toggle.className = 'kbn-detail-controls-toggle'
    toggle.setAttribute('aria-expanded', 'false')

    const chevron = document.createElement('span')
    chevron.className = 'kbn-detail-controls-chevron'
    chevron.setAttribute('aria-hidden', 'true')
    chevron.textContent = '▸'

    const toggleLabel = document.createElement('span')
    toggleLabel.className = 'kbn-detail-controls-label'
    toggleLabel.textContent = 'Actions'

    const summary = document.createElement('span')
    summary.className = 'kbn-detail-controls-summary'
    const chips: string[] = []
    if (card.shuttleAgent) chips.push(card.shuttleAgent)
    if (card.shuttleKind === 'standing' && card.shuttleSchedule) chips.push(card.shuttleSchedule)
    else if (card.shuttleKind) chips.push(card.shuttleKind)
    if (card.shuttleHost) chips.push(card.shuttleHost)
    summary.textContent = chips.join(' · ')

    toggle.append(chevron, toggleLabel, summary)

    const body = document.createElement('div')
    body.className = 'kbn-detail-controls-body'
    body.hidden = true

    toggle.addEventListener('click', (e) => {
      e.stopPropagation()
      const expanded = body.hidden
      body.hidden = !expanded
      toggle.setAttribute('aria-expanded', expanded ? 'true' : 'false')
      chevron.textContent = expanded ? '▾' : '▸'
      wrap.classList.toggle('kbn-detail-controls-open', expanded)
    })

    wrap.append(toggle, body)
    this.buildControlsBody(body, card, scope, shuttleManaged)
    return wrap
  }

  private buildControlsBody(
    body: HTMLElement,
    card: KanbanCard,
    scope: string | undefined,
    shuttleManaged: boolean,
  ): void {
    // ── Next dispatch (message + action buttons) ──────────────────────────
    // One canonical surface for "what happens when this fiber dispatches
    // next." The message textarea is the optional payload; "talk to me
    // first" intent rides the directive text as a felt review-comment,
    // prepended via the one-click "Wait for me" affordance.
    const actionsSec = this.buildSection(shuttleManaged ? 'Next dispatch' : 'Actions')
    const actionsErr = document.createElement('div')
    actionsErr.className = 'kbn-detail-error'
    actionsErr.style.display = 'none'

    const messageTa = document.createElement('textarea')
    messageTa.className = 'kbn-detail-directive'
    messageTa.placeholder = 'Message for the next worker (optional)…'
    messageTa.rows = 3
    messageTa.setAttribute('aria-label', 'Message for next worker')
    messageTa.addEventListener('mousedown', (e) => e.stopPropagation())
    messageTa.addEventListener('click', (e) => e.stopPropagation())

    const WAIT_FOR_ME_LINE = "Wait for me before doing anything heavy — let's talk first.\n\n"
    const waitBtn = document.createElement('button')
    waitBtn.type = 'button'
    waitBtn.className = 'kbn-detail-wait-btn'
    waitBtn.textContent = '⏸ Wait for me'
    waitBtn.title = 'Prepend a "talk first" line to the message so the worker checks in before doing heavy work.'
    waitBtn.addEventListener('click', (e) => {
      e.stopPropagation()
      if (!messageTa.value.startsWith(WAIT_FOR_ME_LINE)) {
        messageTa.value = WAIT_FOR_ME_LINE + messageTa.value
      }
      messageTa.focus()
    })

    const actionsRow = document.createElement('div')
    actionsRow.className = 'kbn-detail-actions-row'

    const temperBtn = this.buildActionBtn('Temper', 'tempered')
    temperBtn.title = 'Close as tempered (human-accepted)'

    const compostBtn = this.buildActionBtn('Compost', 'composted')
    compostBtn.title = 'Close as composted (human-rejected)'

    if (shuttleManaged) {
      const requeueBtn = this.buildActionBtn('New session ▸', 'primary')
      requeueBtn.title = 'Dispatch a fresh worker; outcome preserved'

      const resumeBtn = this.buildActionBtn('Resume ▸', 'primary')
      resumeBtn.title = 'Resume the previous worker session (claude --resume); outcome preserved'
      // Resume is always offered for a shuttle-managed card — never gated on a
      // card-visible session id. The Claude session id lives only in felt
      // history now: shuttle retired the `shuttle.session.id` frontmatter write
      // (slice 6), so `card.sessionId` is always absent and the frontend cannot
      // see what to resume. Shuttle resolves the real session from felt history
      // at dispatch time (force + ad_hoc overrides the run-window filter) and
      // surfaces a precise error if there is genuinely nothing to resume.
      // Gating on `card.sessionId` is exactly what grayed Resume out for EVERY
      // card once that frontmatter write went away — it had already grayed
      // standing roles, which never persisted one.
      // See gotcha-standing-role-resume-button-grayed.

      actionsRow.append(requeueBtn, resumeBtn, temperBtn, compostBtn)

      requeueBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        void this.runRequeue(card, messageTa.value.trim(), 'fresh', scope, requeueBtn, actionsErr)
      })
      resumeBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        void this.runRequeue(card, messageTa.value.trim(), 'previous', scope, resumeBtn, actionsErr)
      })
    } else {
      actionsRow.append(temperBtn, compostBtn)
    }

    temperBtn.addEventListener('click', (e) => {
      e.stopPropagation()
      if (this.onTransition) { this.close(); this.onTransition(card, 'tempered'); return }
      void this.runTransition(card, 'tempered', scope, temperBtn, actionsErr)
    })
    compostBtn.addEventListener('click', (e) => {
      e.stopPropagation()
      if (this.onTransition) { this.close(); this.onTransition(card, 'composted'); return }
      void this.runTransition(card, 'composted', scope, compostBtn, actionsErr)
    })

    // One storyline row under the directive: set intent (⏸), dispatch
    // (New session / Resume), then the review verdicts pushed to the right
    // edge (Temper carries margin-left:auto in CSS) so the two families
    // read as distinct clusters without a second row.
    if (shuttleManaged) {
      actionsRow.prepend(waitBtn)
      actionsSec.append(messageTa, actionsRow, actionsErr)
    } else {
      actionsSec.append(actionsRow, actionsErr)
    }

    // ── Tags ──────────────────────────────────────────────────────────────
    // Chip editor matching the kanban grid card's inline tag editor. Adding
    // a tag commits immediately on Enter; removing via the × chip button
    // does the same. Chips reflect server state, edits atomic.
    const tagsSec = this.buildSection('Tags')
    const tagsErr = document.createElement('div')
    tagsErr.className = 'kbn-detail-error'
    tagsErr.style.display = 'none'

    const tagsRow = document.createElement('div')
    tagsRow.className = 'kbn-detail-tags-row'
    const tagsState: { current: string[] } = {
      current: (card.tags ?? []).filter((t) => t !== 'constitution'),
    }
    const tagInput = document.createElement('input')
    tagInput.type = 'text'
    tagInput.className = 'kbn-detail-tag-input'
    tagInput.placeholder = 'add tag…'
    tagInput.setAttribute('aria-label', 'Add a tag')
    tagInput.addEventListener('mousedown', (e) => e.stopPropagation())
    tagInput.addEventListener('click', (e) => e.stopPropagation())
    tagInput.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return
      e.preventDefault()
      const val = tagInput.value.trim()
      if (!val || tagsState.current.includes(val)) {
        tagInput.value = ''
        return
      }
      const next = [...tagsState.current, val]
      void this.runTagsSave(card, next, scope, tagsState, tagsRow, tagInput, tagsErr)
    })

    const renderTags = (): void => {
      Array.from(tagsRow.querySelectorAll('.kbn-detail-tag-chip')).forEach((n) => n.remove())
      for (const t of tagsState.current) {
        const chip = document.createElement('span')
        chip.className = 'kbn-detail-tag-chip'
        const lbl = document.createElement('span')
        lbl.textContent = t
        const rm = document.createElement('button')
        rm.type = 'button'
        rm.className = 'kbn-detail-tag-remove'
        rm.textContent = '×'
        rm.setAttribute('aria-label', `Remove tag ${t}`)
        rm.addEventListener('click', (e) => {
          e.stopPropagation()
          const next = tagsState.current.filter((x) => x !== t)
          void this.runTagsSave(card, next, scope, tagsState, tagsRow, tagInput, tagsErr)
        })
        chip.append(lbl, rm)
        tagsRow.insertBefore(chip, tagInput)
      }
    }
    tagsRow.append(tagInput)
    renderTags()
    // Cache the renderer on the row so runTagsSave can re-render after success.
    ;(tagsRow as unknown as { _renderTags: () => void })._renderTags = renderTags
    tagsSec.append(tagsRow, tagsErr)

    // ── Worker (shuttle options) ──────────────────────────────────────────
    // Console-style editor for the fiber's shuttle frontmatter block: agent,
    // kind, schedule cadence. Server-side, agent-only changes route through
    // `shuttle-ctl set-model` (preserves session.id + review history);
    // kind/schedule/tz changes trigger a full uninstall + install/repeat.
    let agentSelect: HTMLSelectElement | null = null
    const originalAgent = card.shuttleAgent ?? ''
    // The kind editor toggles oneshot↔standing only; `pinned` is a CLI-managed
    // kind (`shuttle pin <fiber>`), surfaced read-only via the kind chip above.
    // Coerce it to oneshot for the editor's baseline so the toggle stays sound;
    // an agent-only edit on a pinned card never triggers a reshape, so the
    // baseline is never written back unless the human deliberately toggles kind.
    const originalKind: 'oneshot' | 'standing' = card.shuttleKind === 'standing' ? 'standing' : 'oneshot'
    const originalSchedule = card.shuttleSchedule ?? ''
    const originalTz = card.shuttleTz ?? 'Europe/Paris'

    let selectedKind: 'oneshot' | 'standing' = originalKind
    let selectedSchedule = originalSchedule
    let selectedTz = originalTz

    const dispatchSec = this.buildSection(shuttleManaged ? 'Worker' : 'Promote to shuttle')
    const promoteBtn = shuttleManaged ? null : this.buildActionBtn('Promote to shuttle', 'primary')
    const promoteErr = document.createElement('div')
    promoteErr.className = 'kbn-detail-error'
    promoteErr.style.display = 'none'

    // Row 1: agent — base agent select × effort select × chrome toggle. The
    // three orthogonal axes compose into one validated `set-agent` write; the
    // effort options and chrome availability are populated from the selected
    // agent's registry constraint metadata (no hardcoded lists here).
    const agentRow = document.createElement('div')
    agentRow.className = 'kbn-detail-field-row'

    const agentLabel = document.createElement('label')
    agentLabel.className = 'kbn-detail-label'
    agentLabel.textContent = 'Agent'

    agentSelect = document.createElement('select')
    agentSelect.className = 'kbn-detail-select'

    const loadingOpt = document.createElement('option')
    loadingOpt.value = ''
    loadingOpt.textContent = 'Loading agents…'
    agentSelect.append(loadingOpt)

    agentLabel.setAttribute('for', 'kbn-detail-agent')
    agentSelect.id = 'kbn-detail-agent'

    // Effort select — its <option>s are the selected agent's concrete
    // `effort_levels`. There is deliberately no synthetic "default" option:
    // an omitted fiber value resolves to the registry's `default_effort`, so
    // the control always names the level dispatch will actually use.
    const effortSelect = document.createElement('select')
    effortSelect.className = 'kbn-detail-select kbn-detail-select-effort'
    effortSelect.id = 'kbn-detail-effort'
    effortSelect.setAttribute('aria-label', 'Reasoning effort')
    effortSelect.title = 'Reasoning effort used for this fiber'

    // Chrome toggle — enabled only for chrome-capable (claude) agents.
    const chromeWrap = document.createElement('label')
    chromeWrap.className = 'kbn-detail-chrome-toggle'
    chromeWrap.title = 'Run the worker with Claude --chrome (claude harness only)'
    const chromeToggle = document.createElement('input')
    chromeToggle.type = 'checkbox'
    chromeToggle.id = 'kbn-detail-chrome'
    const chromeText = document.createElement('span')
    chromeText.textContent = 'chrome'
    chromeWrap.append(chromeToggle, chromeText)

    // Effort + chrome compose onto an existing shuttle block via set-agent;
    // a not-yet-promoted human card has no block to mutate, so the axes only
    // appear once the card is shuttle-managed. (Promotion's install path takes
    // base model only; the axes are then editable on the installed block.)
    effortSelect.style.display = shuttleManaged ? '' : 'none'
    chromeWrap.style.display = shuttleManaged ? '' : 'none'

    agentRow.append(agentLabel, agentSelect, effortSelect, chromeWrap)
    dispatchSec.append(agentRow)
    // Data-load + listener wiring is deferred until livePatch/statusEl exist
    // (below), since the axis commit posts through them.

    // Row 2: kind segmented control
    const kindRow = document.createElement('div')
    kindRow.className = 'kbn-detail-field-row'

    const kindLabel = document.createElement('span')
    kindLabel.className = 'kbn-detail-label'
    kindLabel.textContent = 'Kind'

    const kindSegmented = document.createElement('div')
    kindSegmented.className = 'kbn-detail-segmented'
    kindSegmented.setAttribute('role', 'radiogroup')
    kindSegmented.setAttribute('aria-label', 'Dispatch kind')

    // Schedule row declared up here so the kind buttons can toggle its
    // visibility; populated below.
    const scheduleRow = document.createElement('div')
    scheduleRow.className = 'kbn-detail-field-row kbn-detail-field-row-schedule'

    const buildKindBtn = (
      value: 'oneshot' | 'standing',
      label: string,
      hint: string,
    ): HTMLButtonElement => {
      const btn = document.createElement('button')
      btn.type = 'button'
      btn.className = 'kbn-detail-segment'
      btn.setAttribute('role', 'radio')
      btn.setAttribute('aria-checked', value === selectedKind ? 'true' : 'false')
      btn.dataset.kind = value
      if (value === selectedKind) btn.classList.add('kbn-detail-segment-active')
      btn.title = hint

      const name = document.createElement('span')
      name.className = 'kbn-detail-segment-name'
      name.textContent = label
      btn.append(name)

      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        if (selectedKind === value) return
        selectedKind = value
        for (const sibling of kindSegmented.querySelectorAll<HTMLButtonElement>('button')) {
          const isActive = sibling.dataset.kind === value
          sibling.classList.toggle('kbn-detail-segment-active', isActive)
          sibling.setAttribute('aria-checked', isActive ? 'true' : 'false')
        }
        scheduleRow.style.display = shuttleManaged && value === 'standing' ? '' : 'none'
        // Surface a sensible cron + tz default when promoting to standing
        // for the first time so the user edits rather than fighting an
        // empty input that fails validation on save.
        if (value === 'standing') {
          if (!selectedSchedule) {
            selectedSchedule = '0 9 * * 1-5'
            scheduleInput.value = selectedSchedule
          }
          if (!selectedTz) {
            selectedTz = 'Europe/Paris'
            tzInput.value = selectedTz
          }
        }
      })
      return btn
    }

    const oneshotBtn = buildKindBtn('oneshot', 'One-shot', 'Single dispatch on enable')
    const standingBtn = buildKindBtn('standing', 'Standing', 'Recurring cron-scheduled role')
    kindSegmented.append(oneshotBtn, standingBtn)
    kindRow.append(kindLabel, kindSegmented)
    kindRow.style.display = shuttleManaged ? '' : 'none'
    dispatchSec.append(kindRow)

    // Row 3: schedule + tz (visible only when kind=standing)
    const scheduleLabel = document.createElement('label')
    scheduleLabel.className = 'kbn-detail-label'
    scheduleLabel.textContent = 'Cron'
    scheduleLabel.setAttribute('for', 'kbn-detail-schedule')

    const scheduleInput = document.createElement('input')
    scheduleInput.type = 'text'
    scheduleInput.id = 'kbn-detail-schedule'
    scheduleInput.className = 'kbn-detail-input kbn-detail-input-mono'
    scheduleInput.placeholder = '0 9 * * 1-5'
    scheduleInput.value = selectedSchedule
    scheduleInput.title = '5-field cron · e.g. 0 9 * * 1-5 (weekdays 09:00)'
    scheduleInput.addEventListener('input', () => {
      selectedSchedule = scheduleInput.value
    })
    scheduleInput.addEventListener('mousedown', (e) => e.stopPropagation())
    scheduleInput.addEventListener('click', (e) => e.stopPropagation())

    const tzInput = document.createElement('input')
    tzInput.type = 'text'
    tzInput.className = 'kbn-detail-input kbn-detail-input-tz'
    tzInput.placeholder = 'Europe/Paris'
    tzInput.value = selectedTz
    tzInput.title = 'IANA timezone name'
    tzInput.setAttribute('aria-label', 'Timezone (IANA name)')
    tzInput.addEventListener('input', () => {
      selectedTz = tzInput.value
    })
    tzInput.addEventListener('mousedown', (e) => e.stopPropagation())
    tzInput.addEventListener('click', (e) => e.stopPropagation())

    scheduleRow.append(scheduleLabel, scheduleInput, tzInput)
    scheduleRow.style.display = shuttleManaged && selectedKind === 'standing' ? '' : 'none'
    dispatchSec.append(scheduleRow)
    if (promoteBtn) dispatchSec.append(promoteBtn, promoteErr)

    // ── Live-apply status pill ────────────────────────────────────────────
    // No Save button. Every field commits on its own event: agent on
    // `change`, kind on click, schedule/tz on `blur`/Enter, parent on
    // autocomplete pick. statusEl shows "Saving…" / "Saved"; errors surface
    // in errorEl. Originals advance after each successful PATCH.
    const statusEl = document.createElement('span')
    statusEl.className = 'kbn-detail-save-status'
    statusEl.setAttribute('aria-live', 'polite')

    const errorEl = document.createElement('div')
    errorEl.className = 'kbn-detail-error'
    errorEl.style.display = 'none'

    // ── Parent fiber ──────────────────────────────────────────────────────
    const parentSec = this.buildSection('Parent fiber')

    const idSegments = card.id.split('/')
    const currentParentId = idSegments.length > 1
      ? idSegments.slice(0, -1).join('/')
      : null

    let selectedParentId: string | null = currentParentId

    const currentParentEl = document.createElement('div')
    currentParentEl.className = 'kbn-detail-current-parent'
    currentParentEl.textContent = currentParentId
      ? `↳ ${currentParentId}`
      : '↳ top-level (no parent)'

    const parentSearchWrap = document.createElement('div')
    parentSearchWrap.className = 'kbn-detail-parent-wrap'

    const parentInput = document.createElement('input')
    parentInput.type = 'text'
    parentInput.className = 'kbn-detail-parent-input'
    parentInput.placeholder = 'Search for a new parent…'
    parentInput.setAttribute('aria-label', 'Search parent fiber')
    parentInput.setAttribute('autocomplete', 'off')
    parentInput.setAttribute('role', 'combobox')
    parentInput.setAttribute('aria-expanded', 'false')
    parentInput.setAttribute('aria-haspopup', 'listbox')
    parentInput.addEventListener('mousedown', (e) => e.stopPropagation())
    parentInput.addEventListener('click', (e) => e.stopPropagation())

    const parentDropdown = document.createElement('div')
    parentDropdown.className = 'kbn-detail-parent-dropdown'
    parentDropdown.style.display = 'none'
    parentDropdown.setAttribute('role', 'listbox')

    // Shared pick-handler in a closure-captured ref so the live-commit
    // wrapper below can replace it once `livePatch` is defined — every
    // caller (search debounce, keyboard Enter) goes through the same
    // indirection and picks up the live-apply behavior.
    const parentPickRef: { current: (result: FiberSearchResult) => void } = {
      current: (result) => {
        selectedParentId = result.id
        parentInput.value = result.name
        parentInput.setAttribute('aria-expanded', 'false')
        parentDropdown.style.display = 'none'
      },
    }
    const onPickParent = (result: FiberSearchResult) => parentPickRef.current(result)

    const openDropdown = () => {
      void this.searchParents(
        parentInput.value.trim(),
        card.id,
        parentDropdown,
        onPickParent,
      ).then(() => {
        if (parentDropdown.style.display !== 'none') {
          parentInput.setAttribute('aria-expanded', 'true')
        }
      })
    }

    parentInput.addEventListener('input', () => {
      if (this.searchDebounce !== null) window.clearTimeout(this.searchDebounce)
      this.searchDebounce = window.setTimeout(() => openDropdown(), 200)
    })
    parentInput.addEventListener('focus', () => openDropdown())
    parentInput.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') {
        const first = parentDropdown.querySelector<HTMLElement>('button')
        if (first) { e.preventDefault(); first.focus() }
      } else if (e.key === 'Escape') {
        e.preventDefault()
        parentDropdown.style.display = 'none'
        parentInput.setAttribute('aria-expanded', 'false')
      }
    })

    parentDropdown.addEventListener('keydown', (e) => {
      const opts = Array.from(
        parentDropdown.querySelectorAll<HTMLElement>('button:not(:disabled)'),
      )
      const idx = opts.indexOf(document.activeElement as HTMLElement)
      if (e.key === 'ArrowDown' && idx < opts.length - 1) {
        e.preventDefault()
        opts[idx + 1].focus()
      } else if (e.key === 'ArrowUp') {
        e.preventDefault()
        if (idx > 0) opts[idx - 1].focus()
        else parentInput.focus()
      } else if (e.key === 'Escape') {
        e.preventDefault()
        // Focus the input first — hiding a container that holds the focused
        // element drops focus to <body> before we can redirect it.
        parentInput.focus()
        parentDropdown.style.display = 'none'
        parentInput.setAttribute('aria-expanded', 'false')
      }
    })

    parentSearchWrap.addEventListener('focusout', () => {
      window.setTimeout(() => {
        if (!parentSearchWrap.contains(document.activeElement)) {
          parentDropdown.style.display = 'none'
          parentInput.setAttribute('aria-expanded', 'false')
        }
      }, 150)
    })

    parentSearchWrap.append(parentInput, parentDropdown)
    parentSec.append(currentParentEl, parentSearchWrap)

    // Track originals as a mutable closure so each successful PATCH can
    // advance the baseline.
    const baseline = {
      agent: originalAgent,
      kind: originalKind,
      schedule: originalSchedule,
      tz: originalTz,
      parentId: currentParentId,
    }

    const livePatch = (
      changes: {
        shuttleAgent?: string
        shuttleKind?: 'oneshot' | 'standing'
        shuttleSchedule?: string
        shuttleTz?: string
        parentId?: string | null
      },
      onCommitted?: () => void,
    ): void => {
      if (Object.keys(changes).length === 0) return
      void this.livePatch(card, changes, statusEl, errorEl).then((ok: boolean) => {
        if (ok && onCommitted) onCommitted()
      })
    }

    // Agent axes: base agent × effort × chrome compose into one validated
    // `set-agent` write (preserves session history, like the old set-model).
    // The picker repopulates effort options + chrome availability from the
    // selected agent's registry metadata and commits on any axis change.
    if (agentSelect) {
      // For a shuttle-managed card every axis change commits via set-agent;
      // for a human card the picker only populates the base-agent select the
      // promote button reads (no block to mutate yet → no-op commit).
      void this.loadAgentPicker(
        { agentSelect, effortSelect, chromeToggle },
        {
          agent: originalAgent,
          effort: card.shuttleEffort ?? '',
          chrome: card.shuttleChrome ?? false,
        },
        shuttleManaged
          ? (axes) => {
              this.commitAxes(card, axes, statusEl, errorEl, () => {
                baseline.agent = axes.agent
              })
            }
          : () => {},
      )
    }

    // Kind: fire on click. When promoting oneshot → standing, batch
    // schedule + tz alongside so the server's reshape path has the full
    // block. A bare standing → oneshot collapse just sends shuttleKind.
    const commitKind = (value: 'oneshot' | 'standing'): void => {
      if (value === baseline.kind) return
      const newSchedule = scheduleInput.value.trim()
      const newTz = tzInput.value.trim()
      if (value === 'standing') {
        if (!newSchedule) {
          errorEl.textContent = 'A cron expression is required for standing roles.'
          errorEl.style.display = ''
          for (const sibling of kindSegmented.querySelectorAll<HTMLButtonElement>('button')) {
            const isActive = sibling.dataset.kind === baseline.kind
            sibling.classList.toggle('kbn-detail-segment-active', isActive)
            sibling.setAttribute('aria-checked', isActive ? 'true' : 'false')
          }
          selectedKind = baseline.kind
          return
        }
        livePatch(
          {
            shuttleKind: 'standing',
            shuttleSchedule: newSchedule,
            shuttleTz: newTz || 'UTC',
          },
          () => {
            baseline.kind = 'standing'
            baseline.schedule = newSchedule
            baseline.tz = newTz || 'UTC'
          },
        )
      } else {
        livePatch({ shuttleKind: 'oneshot' }, () => {
          baseline.kind = 'oneshot'
        })
      }
    }
    for (const btn of kindSegmented.querySelectorAll<HTMLButtonElement>('button')) {
      btn.addEventListener('click', () => {
        const value = btn.dataset.kind as 'oneshot' | 'standing' | undefined
        if (value) commitKind(value)
      })
    }

    // Schedule + tz: fire on `blur` and Enter — `input` would generate
    // noisy patches from mid-typing cron fragments. The reshape path
    // requires kind=standing alongside, so always send all three.
    const commitScheduleTz = (): void => {
      if (baseline.kind !== 'standing') return
      const newSchedule = scheduleInput.value.trim()
      const newTz = tzInput.value.trim() || 'UTC'
      if (newSchedule === baseline.schedule && newTz === baseline.tz) return
      if (!newSchedule) {
        errorEl.textContent = 'A cron expression is required for standing roles.'
        errorEl.style.display = ''
        return
      }
      livePatch(
        {
          shuttleKind: 'standing',
          shuttleSchedule: newSchedule,
          shuttleTz: newTz,
        },
        () => {
          baseline.schedule = newSchedule
          baseline.tz = newTz
        },
      )
    }
    scheduleInput.addEventListener('blur', commitScheduleTz)
    scheduleInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        scheduleInput.blur()
      }
    })
    tzInput.addEventListener('blur', commitScheduleTz)
    tzInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        tzInput.blur()
      }
    })

    // Parent: redirect the autocomplete's pick callback into a live patch.
    const basePickParent = parentPickRef.current
    parentPickRef.current = (result) => {
      basePickParent(result)
      const targetParentId = selectedParentId
      if (targetParentId === baseline.parentId) return
      livePatch({ parentId: targetParentId }, () => {
        baseline.parentId = targetParentId
        currentParentEl.textContent = targetParentId
          ? `↳ ${targetParentId}`
          : '↳ top-level (no parent)'
      })
    }

    if (promoteBtn) {
      promoteBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        const agent = agentSelect?.value.trim() ?? ''
        if (!agent) {
          promoteErr.textContent = 'Choose an agent to promote this card.'
          promoteErr.style.display = ''
          return
        }
        promoteBtn.disabled = true
        promoteBtn.textContent = 'Promoting…'
        promoteErr.style.display = 'none'
        void this.promoteToShuttle(card, agent, promoteBtn, promoteErr)
      })
    }

    // ── Footer: drill-out + live-save status ──────────────────────────────
    const footer = document.createElement('div')
    footer.className = 'kbn-detail-footer'

    footer.append(errorEl, statusEl)

    // Worker config on the left, card metadata (tags + parent) on the
    // right — a shallow two-column cluster at comfortable widths, one
    // column on narrow panels (container query in FiberDetailModal.css).
    const grid = document.createElement('div')
    grid.className = 'kbn-detail-controls-grid'
    const metaCol = document.createElement('div')
    metaCol.className = 'kbn-detail-controls-grid-col'
    metaCol.append(tagsSec, parentSec)
    grid.append(dispatchSec, metaCol)

    body.append(actionsSec, this.buildRule(), grid, footer)
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  /**
   * Container for the sent-files strip. Mounts empty (display:none via the
   * `kbn-detail-sent-empty` class) and self-populates from
   * `GET /sent-files?uid=<card.uid>` — the fiber ULID is the durable key
   * the tracker files every shuttle worker's sends under; the legacy
   * `shuttle.session.id`, when frontmatter still carries one, rides along
   * as `sessionId`. Only reveals itself when the trail has entries, so
   * cards without deliverables pay zero visual cost. Each row click hands
   * the absolute path to `onOpenFile` (vellum file viewer, owner-routed by
   * the card's origin for remote paths).
   */
  private buildSentFiles(card: KanbanCard): HTMLElement {
    const wrap = document.createElement('div')
    wrap.className = 'kbn-detail-sent kbn-detail-sent-empty'
    const params = new URLSearchParams()
    const uid = typeof card.uid === 'string' ? card.uid.trim() : ''
    const sessionId = typeof card.sessionId === 'string' ? card.sessionId.trim() : ''
    if (uid) params.set('uid', uid)
    if (sessionId) params.set('sessionId', sessionId)
    if (!uid && !sessionId) return wrap

    const overlayAtBuild = () => this.overlay

    void fetch(`${this.portolanBase}/sent-files?${params.toString()}`)
      .then((r) => (r.ok ? r.json() : null))
      .then((data: { files?: Array<{ fullPath: string; basename: string; timestamp: number }> } | null) => {
        const files = data?.files ?? []
        // Panel may have closed/reopened while the fetch was in flight.
        if (files.length === 0 || !overlayAtBuild()?.contains(wrap)) return

        const heading = document.createElement('div')
        heading.className = 'kbn-detail-sent-heading'
        heading.textContent = 'Sent files'

        const list = document.createElement('div')
        list.className = 'kbn-detail-sent-list'
        list.setAttribute('role', 'list')
        for (const file of files) {
          const row = document.createElement('button')
          row.type = 'button'
          row.className = 'kbn-detail-sent-file'
          row.setAttribute('role', 'listitem')
          row.title = file.fullPath
          row.dataset.fullPath = file.fullPath

          const name = document.createElement('span')
          name.className = 'kbn-detail-sent-name'
          name.textContent = file.basename

          const when = document.createElement('span')
          when.className = 'kbn-detail-sent-when'
          when.textContent = relativeTime(file.timestamp)

          row.append(name, when)
          row.addEventListener('click', (e) => {
            e.stopPropagation()
            // Split view: this panel glides to the left half, the viewer
            // takes the right; closing the viewer glides the panel back.
            // Both stay non-modal. The viewer's ↗ escalates to the full
            // file workspace via onOpenFile.
            this.openInSplitView(file.fullPath, card.originId)
          })
          list.append(row)
        }

        wrap.append(heading, list)
        wrap.classList.remove('kbn-detail-sent-empty')
      })
      .catch(() => {
        // Backend unreachable (tests, embeds) — strip stays hidden.
      })

    return wrap
  }

  private buildSection(label: string): HTMLElement {
    const sec = document.createElement('div')
    sec.className = 'kbn-detail-section'
    sec.dataset.section = label.toLowerCase()
    const heading = document.createElement('div')
    heading.className = 'kbn-detail-section-heading'
    heading.textContent = label
    sec.append(heading)
    return sec
  }

  /**
   * Hairline printer's rule used to separate clusters in the dropdown.
   * Pure presentational element — no semantic role.
   */
  private buildRule(): HTMLElement {
    const rule = document.createElement('div')
    rule.className = 'kbn-detail-rule'
    rule.setAttribute('aria-hidden', 'true')
    return rule
  }

  /**
   * Build a button for the action cluster. Variants tint the button to
   * match the kanban grid's `kbn-action-*` palette (gold for primary
   * requeue/resume, teal for tempered, muted gray for composted).
   */
  private buildActionBtn(
    label: string,
    variant: 'primary' | 'tempered' | 'composted' | 'dispatch',
  ): HTMLButtonElement {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = `kbn-detail-action-btn kbn-detail-action-${variant}`
    btn.textContent = label
    return btn
  }

  /** Shuttle daemon transition endpoint. Owner-routed by `origin` in the
   *  body, so no `?cityId=` scoping — the daemon maps the column `target`
   *  to a lifecycle action itself. */
  private transitionUrl(): string {
    return `${this.shuttleBase}/api/v1/transition`
  }

  /** Shuttle daemon dispatch endpoint (force/ad-hoc launches), owner-routed
   *  by `origin`. */
  private dispatchUrl(): string {
    return `${this.shuttleBase}/api/v1/dispatch`
  }

  /** Shuttle daemon raw frontmatter writer (add/remove/set/unset/due diffs),
   *  owner-routed by `origin`. Drives tag add/remove. */
  private feltEditUrl(): string {
    return `${this.shuttleBase}/api/v1/felt-edit`
  }

  /** POST one `/api/v1/lifecycle` action; the daemon answers plain text, so
   *  a !ok body is the error message verbatim. */
  private async postLifecycle(body: Record<string, unknown>): Promise<void> {
    const res = await fetch(`${this.shuttleBase}/api/v1/lifecycle`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) {
      const errText = await res.text().catch(() => `${res.status}`)
      throw new Error(errText || `Save failed: ${res.status}`)
    }
  }

  /** The `project_dir` for a card's shuttle install: the block's own
   *  `project_dir` when present (reshape echo), else the owning city's
   *  project path. Undefined when neither resolves — valid for paused
   *  installs; an arming install without one fails loudly in shuttle-ctl. */
  private projectDirFor(card: KanbanCard): string | undefined {
    return (
      card.shuttleProjectDir ??
      (card.cityId ? this.resolveCityProjectPath?.(card.cityId) : undefined)
    )
  }

  /**
   * Unified manual requeue, orchestrated client-side against the Shuttle
   * daemon (the old single `/kanban/requeue` Portolan endpoint did this
   * server-side):
   *
   *   1. File a `review-comment` felt-history event carrying the user's
   *      directive (event summary) + resume intent (`resume_mode` field).
   *      The dispatcher reads the latest review-comment at dispatch time and
   *      honors its `resume_mode` — so `previous` resumes the prior session,
   *      `fresh` starts clean. The comment is filed even when the directive
   *      is empty, so the latest `resume_mode` stays aligned with the click.
   *   2. POST `/api/v1/dispatch` with `force: true, ad_hoc: true` to launch
   *      the worker on the owning host.
   *
   * Both steps are owner-routed by `card.originId` (`origin`). `mode='previous'`
   * only actually resumes when a previous session is resolvable; the daemon
   * falls back to fresh otherwise (oneshot with no `session.id`).
   */
  private async runRequeue(
    card: KanbanCard,
    directive: string,
    mode: 'fresh' | 'previous',
    _cityId: string | undefined,
    btn: HTMLButtonElement,
    errorEl: HTMLElement,
  ): Promise<void> {
    const original = btn.textContent ?? ''
    btn.disabled = true
    btn.textContent = mode === 'fresh' ? 'Starting…' : 'Resuming…'
    errorEl.style.display = 'none'

    // Step 1: file the review-comment (directive + resume_mode). Plain-text
    // body on !ok. Empty directive still files so `resume_mode` advances.
    try {
      const histRes = await fetch(`${this.shuttleBase}/api/v1/felt-history`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fiber_id: card.id,
          origin: card.originId,
          kind: 'review-comment',
          summary: directive,
          fields: { resume_mode: mode },
        }),
      })
      if (!histRes.ok) {
        const detail = await histRes.text().catch(() => `${histRes.status}`)
        this.showDispatchError(errorEl, btn, original, `Couldn't file directive: ${detail}`)
        return
      }
    } catch (err: unknown) {
      const detail = (err as { message?: string })?.message ?? String(err)
      this.showDispatchError(errorEl, btn, original, `Couldn't reach Shuttle: ${detail}`)
      return
    }

    // Step 2: force/ad-hoc dispatch.
    let res: Response
    try {
      res = await fetch(this.dispatchUrl(), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fiber_id: card.id,
          origin: card.originId,
          force: true,
          ad_hoc: true,
        }),
      })
    } catch (err: unknown) {
      const detail = (err as { message?: string })?.message ?? String(err)
      this.showDispatchError(errorEl, btn, original, `Couldn't reach Shuttle: ${detail}`)
      return
    }

    const body = (await res.json().catch(() => ({}))) as {
      dispatched?: boolean
      reason?: string
      detail?: string
      message?: string
      error?: string
      tmux_session?: string
    }

    if (res.status === 409) {
      btn.textContent = 'Already running'
      btn.disabled = true
      errorEl.textContent = 'A worker is already running for this fiber.'
      errorEl.style.display = ''
      return
    }

    if (!res.ok) {
      // Prefer the daemon's structured ineligibility copy (detail/message name
      // the actual host / project_dir); fall back to the generic error / status.
      const msg = (body.reason || body.detail || body.message)
        ? dispatchIneligibleReason(body)
        : (body.error ?? `Requeue failed (${res.status})`)
      this.showDispatchError(errorEl, btn, original, msg)
      return
    }

    this.close()
    this.onSaved()
    if (body.tmux_session) {
      this.onAttachFreshTmux?.(body.tmux_session)
    }
  }

  /**
   * Single-step transition (no directive). Used for Temper / Compost
   * buttons — those are terminal moves where a directive is moot.
   */
  private async runTransition(
    card: KanbanCard,
    target: string,
    _cityId: string | undefined,
    btn: HTMLButtonElement,
    errorEl: HTMLElement,
  ): Promise<void> {
    const original = btn.textContent ?? ''
    btn.disabled = true
    btn.textContent = '…'
    errorEl.style.display = 'none'
    try {
      const res = await fetch(this.transitionUrl(), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fiber_id: card.id, target, origin: card.originId }),
      })
      if (!res.ok) {
        throw new Error(await errorMessageFromResponse(res, 'Transition failed'))
      }
      this.close()
      this.onSaved()
    } catch (err: unknown) {
      const msg = (err as { message?: string })?.message ?? String(err)
      errorEl.textContent = msg
      errorEl.style.display = ''
      btn.disabled = false
      btn.textContent = original
    }
  }

  private showDispatchError(
    errorEl: HTMLElement,
    btn: HTMLButtonElement,
    originalBtnText: string,
    message: string,
  ): void {
    errorEl.textContent = message
    errorEl.style.display = ''
    btn.disabled = false
    btn.textContent = originalBtnText
  }

  /**
   * Persist the new tag set via the daemon's `/api/v1/felt-edit` and re-render
   * the chip row on success. Stays open — tags are an inline edit, not a final
   * gesture, so the panel doesn't close.
   *
   * felt-edit takes add/remove DIFFS, not a full set, so we diff the desired
   * full tag set against the card's current full set. `constitution` (if
   * present) sits in both, so it never lands in add or remove — it's preserved
   * untouched without needing to be re-sent.
   */
  private async runTagsSave(
    card: KanbanCard,
    tags: string[],
    _cityId: string | undefined,
    state: { current: string[] },
    _row: HTMLElement,
    input: HTMLInputElement,
    errorEl: HTMLElement,
  ): Promise<void> {
    errorEl.style.display = 'none'
    // The visible chips filter `constitution` out (it's not user-editable),
    // but it must survive the edit — so the desired full set re-includes it.
    const fullTags = (card.tags ?? []).includes('constitution')
      ? ['constitution', ...tags.filter((t) => t !== 'constitution')]
      : tags
    const current = card.tags ?? []
    const add = fullTags.filter((t) => !current.includes(t))
    const remove = current.filter((t) => !fullTags.includes(t))
    // Nothing changed (e.g. re-adding an existing tag) — skip the round-trip.
    if (add.length === 0 && remove.length === 0) {
      input.value = ''
      return
    }
    try {
      const res = await fetch(this.feltEditUrl(), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fiber_id: card.id, origin: card.originId, add, remove }),
      })
      if (!res.ok) {
        const detail = await res.text().catch(() => `${res.status}`)
        throw new Error(detail || `tags ${res.status}`)
      }
      // Mirror server state into local; clear input; re-render chips.
      state.current = tags.filter((t) => t !== 'constitution')
      // Update the card object so future reads of card.tags see the new set.
      card.tags = fullTags
      input.value = ''
      const ren = (_row as unknown as { _renderTags?: () => void })._renderTags
      if (typeof ren === 'function') ren()
      // Inform parent kanban so the grid card refreshes with the new tags.
      this.onSaved()
    } catch (err: unknown) {
      const msg = (err as { message?: string })?.message ?? String(err)
      errorEl.textContent = msg
      errorEl.style.display = ''
    }
  }

  /**
   * Load the agent registry and wire the composing picker: base agent select
   * (aliases filtered out), an effort select whose options come from the
   * selected agent's `effort_levels`, and a chrome toggle gated on
   * `chrome_capable`. Any axis change repopulates the dependent controls (a
   * new agent resets effort to its default and may disable chrome) and fires
   * `onCommit` with the current composition — which `commitAxes` writes
   * through the daemon's `set-agent` lifecycle action.
   */
  private async loadAgentPicker(
    controls: {
      agentSelect: HTMLSelectElement
      effortSelect: HTMLSelectElement
      chromeToggle: HTMLInputElement
    },
    current: { agent: string; effort: string; chrome: boolean },
    onCommit: (axes: { agent: string; effort: string; chrome: boolean }) => void,
  ): Promise<void> {
    const { agentSelect, effortSelect, chromeToggle } = controls
    let records: AgentRecord[]
    try {
      // The daemon's registry is a bare array; Portolan's retired proxy used
      // to wrap it as `{agents: [...]}`. Accept both for embed compatibility.
      const res = await fetch(`${this.shuttleBase}/api/v1/agents`)
      if (!res.ok) throw new Error(`${res.status}`)
      const raw = (await res.json()) as AgentRecord[] | { agents: AgentRecord[] }
      records = Array.isArray(raw) ? raw : raw.agents ?? []
    } catch {
      agentSelect.innerHTML = '<option value="">Failed to load agents</option>'
      effortSelect.innerHTML = ''
      effortSelect.disabled = true
      chromeToggle.disabled = true
      return
    }

    // Base agents only — alias records (e.g. claude-opus-chrome) are a
    // convenience that the composing picker supersedes; resolving one to its
    // base + axes belongs to the registry, not this list.
    const base = records.filter((a) => !a.alias_of)
    agentSelect.innerHTML = ''
    if (base.length === 0) {
      const opt = document.createElement('option')
      opt.value = ''
      opt.textContent = 'No agents available'
      agentSelect.append(opt)
      effortSelect.disabled = true
      chromeToggle.disabled = true
      return
    }

    const defaultAgent = current.agent
      ? undefined
      : base.find((a) => a.default)?.id
    for (const agent of base) {
      const opt = document.createElement('option')
      opt.value = agent.id
      opt.textContent = agent.model ? `${agent.id} (${agent.model})` : agent.id
      if (agent.id === current.agent || (!current.agent && agent.id === defaultAgent)) {
        opt.selected = true
      }
      agentSelect.append(opt)
    }
    // A current agent absent from the registry stays selectable as a custom
    // entry so an unknown id isn't silently rewritten on the next edit.
    if (current.agent && !base.some((a) => a.id === current.agent)) {
      const opt = document.createElement('option')
      opt.value = current.agent
      opt.textContent = `${current.agent} (custom)`
      opt.selected = true
      agentSelect.prepend(opt)
    }

    // Repopulate effort options + chrome availability from a given agent's
    // metadata. The selected value is always concrete: an omitted/invalid
    // fiber value resolves to the agent's registry default. An agent change
    // therefore writes that new agent's explicit effective effort.
    const syncDependents = (agentId: string, effort: string): void => {
      const rec = records.find((a) => a.id === agentId)
      const levels = rec?.effort_levels ?? []
      effortSelect.innerHTML = ''
      for (const lvl of levels) {
        const opt = document.createElement('option')
        opt.value = lvl
        opt.textContent = lvl
        effortSelect.append(opt)
      }
      effortSelect.disabled = levels.length === 0
      const effectiveEffort = levels.includes(effort)
        ? effort
        : rec?.default_effort && levels.includes(rec.default_effort)
          ? rec.default_effort
          : ''
      effortSelect.value = effectiveEffort

      const chromeOk = rec?.chrome_capable ?? false
      chromeToggle.disabled = !chromeOk
      if (!chromeOk) chromeToggle.checked = false
    }

    const selectedAgent = (): string => agentSelect.value
    syncDependents(selectedAgent() || current.agent, current.effort)
    chromeToggle.checked = current.chrome && !chromeToggle.disabled

    const commit = (): void =>
      onCommit({
        agent: selectedAgent(),
        effort: effortSelect.value,
        chrome: chromeToggle.checked,
      })

    agentSelect.addEventListener('change', () => {
      // New agent: select and persist its concrete default effort, then
      // re-gate chrome and write the fresh composition.
      syncDependents(selectedAgent(), '')
      chromeToggle.checked = chromeToggle.checked && !chromeToggle.disabled
      commit()
    })
    effortSelect.addEventListener('change', commit)
    chromeToggle.addEventListener('change', commit)
  }

  /**
   * Write the composed agent axes through the daemon's `set-agent` lifecycle
   * action — one validated write that sees base agent × effort × chrome
   * together. Effort is always a concrete registry token when the agent
   * supports that axis; chrome is always sent explicitly so a toggle-off is
   * unambiguous.
   */
  private async commitAxes(
    card: KanbanCard,
    axes: { agent: string; effort: string; chrome: boolean },
    statusEl: HTMLElement,
    errorEl: HTMLElement,
    onCommitted?: () => void,
  ): Promise<void> {
    if (!axes.agent) return
    errorEl.style.display = 'none'
    statusEl.textContent = 'Saving…'
    statusEl.classList.remove('kbn-detail-save-status-saved')
    statusEl.classList.add('kbn-detail-save-status-saving')
    try {
      await this.postLifecycle({
        action: 'set-agent',
        origin: card.originId,
        fiber: card.id,
        agent: axes.agent,
        effort: axes.effort,
        chrome: axes.chrome,
      })
      this.onSaved()
      statusEl.textContent = 'Saved'
      statusEl.classList.remove('kbn-detail-save-status-saving')
      statusEl.classList.add('kbn-detail-save-status-saved')
      window.setTimeout(() => {
        if (statusEl.textContent === 'Saved') {
          statusEl.textContent = ''
          statusEl.classList.remove('kbn-detail-save-status-saved')
        }
      }, 1500)
      onCommitted?.()
    } catch (err: unknown) {
      const msg = (err as { message?: string })?.message ?? String(err)
      errorEl.textContent = msg
      errorEl.style.display = ''
      statusEl.textContent = ''
      statusEl.classList.remove('kbn-detail-save-status-saving')
    }
  }

  /**
   * Fetch the daemon's full fiber index once per panel-open (`GET
   * /api/v1/fibers`, ids + names only). The parent picker filters it
   * client-side per keystroke — the index is a few hundred rows, so this
   * replaces the retired Portolan `/kanban/fiber-search` round trip per
   * keystroke with one fetch and pure filtering.
   */
  private loadFiberIndex(): Promise<Array<{ id: string; name: string }>> {
    this.fiberIndex ??= fetchFiberIndex(this.shuttleBase).catch((err: unknown) => {
      // Don't cache a failure — the next keystroke retries.
      this.fiberIndex = null
      throw err
    })
    return this.fiberIndex
  }

  /**
   * Parent-picker search: one daemon index fetch per panel-open, then the
   * shared `filterParentCandidates` rule (the retired backend
   * `/kanban/fiber-search` semantics) per keystroke.
   */
  private async searchParents(
    q: string,
    excludeId: string,
    dropdown: HTMLElement,
    onSelect: (result: FiberSearchResult) => void,
  ): Promise<void> {
    // Concurrent triggers (focus + debounced input) can resolve the shared
    // index promise in the same microtask batch — without a token the two
    // renders interleave (clear, clear, append, append) and every option
    // doubles. Only the latest call may render.
    const token = ++this.searchRenderToken
    try {
      const allFibers = await this.loadFiberIndex()
      if (token !== this.searchRenderToken) return
      const data = { fibers: filterParentCandidates(allFibers, q, excludeId) }

      dropdown.innerHTML = ''
      if (data.fibers.length === 0) {
        const empty = document.createElement('div')
        empty.className = 'kbn-detail-parent-option kbn-detail-parent-empty'
        empty.textContent = q ? 'No matches' : 'No fibers available'
        dropdown.append(empty)
        dropdown.style.display = ''
        return
      }

      for (const fiber of data.fibers) {
        const opt = document.createElement('button')
        opt.type = 'button'
        opt.className = 'kbn-detail-parent-option'
        opt.dataset.depth = String(fiber.depth)

        const nameSpan = document.createElement('span')
        nameSpan.className = 'kbn-detail-parent-option-name'
        nameSpan.textContent = fiber.name

        const idSpan = document.createElement('span')
        idSpan.className = 'kbn-detail-parent-option-id'
        idSpan.textContent = fiber.id

        opt.append(nameSpan, idSpan)
        opt.addEventListener('click', (e) => {
          e.stopPropagation()
          onSelect(fiber)
        })
        dropdown.append(opt)
      }
      dropdown.style.display = ''
    } catch {
      dropdown.innerHTML = '<div class="kbn-detail-parent-option kbn-detail-parent-empty">Search failed</div>'
      dropdown.style.display = ''
    }
  }

  /**
   * Promote a human card to a paused shuttle draft: `:4000/api/v1/lifecycle`
   * `install --disabled`, owner-routed by `origin`. `project_dir` (the
   * worker's cwd) comes from the card's owning city via
   * `resolveCityProjectPath`; a card with no resolvable city installs
   * without one, which a paused draft permits — arming it later supplies
   * the dir or fails loudly in shuttle-ctl.
   */
  private async promoteToShuttle(
    card: KanbanCard,
    agent: string,
    saveBtn: HTMLButtonElement,
    errorEl: HTMLElement,
  ): Promise<void> {
    try {
      const res = await fetch(`${this.shuttleBase}/api/v1/lifecycle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'install',
          origin: card.originId,
          fiber: card.id,
          model: agent,
          project_dir: this.projectDirFor(card),
          disabled: true,
        }),
      })
      if (!res.ok) {
        const errText = await res.text().catch(() => `${res.status}`)
        throw new Error(errText || `Promote failed: ${res.status}`)
      }
      this.close()
      this.onSaved()
    } catch (err: unknown) {
      const msg = (err as { message?: string })?.message ?? String(err)
      errorEl.textContent = msg
      errorEl.style.display = ''
      saveBtn.disabled = false
      saveBtn.textContent = 'Promote to shuttle'
    }
  }

  /**
   * Apply a single-field (or coupled-field) change to the fiber's shuttle
   * block / parent immediately on event. Updates the status pill in place:
   * "Saving…" while the PATCH is in flight, "Saved" briefly on success,
   * error text in `errorEl` on failure. The panel stays open through all
   * outcomes — live edits don't close the inspector.
   *
   * Returns true on success so the caller can advance its local baseline.
   */
  private async livePatch(
    card: KanbanCard,
    changes: {
      shuttleAgent?: string
      shuttleKind?: 'oneshot' | 'standing'
      shuttleSchedule?: string
      shuttleTz?: string
      parentId?: string | null
    },
    statusEl: HTMLElement,
    errorEl: HTMLElement,
  ): Promise<boolean> {
    errorEl.style.display = 'none'
    statusEl.textContent = 'Saving…'
    statusEl.classList.remove('kbn-detail-save-status-saved')
    statusEl.classList.add('kbn-detail-save-status-saving')
    try {
      const origin = card.originId
      const fiberId = card.id

      const wantsReshape =
        changes.shuttleKind !== undefined ||
        typeof changes.shuttleSchedule === 'string' ||
        typeof changes.shuttleTz === 'string'

      if (wantsReshape) {
        // Kind/schedule/tz is a full uninstall + install/repeat reshape —
        // the shuttle-ctl writers refuse to clobber an existing block, so
        // the daemon's `/lifecycle` verbs are composed client-side, exactly
        // as Portolan's retired `/kanban/fiber-patch` composed shuttle-ctl
        // server-side. Current block state comes from the card.
        const targetKind: 'oneshot' | 'standing' =
          changes.shuttleKind ?? (card.shuttleKind === 'standing' ? 'standing' : 'oneshot')
        const targetAgent = changes.shuttleAgent || card.shuttleAgent
        const projectDir = this.projectDirFor(card)
        // A paused draft must stay paused across the reshape (install
        // defaults to armed; status `open` means draft).
        const wasDisabled = card.status === 'open'

        let reinstall: Record<string, unknown>
        if (targetKind === 'standing') {
          const schedule =
            (typeof changes.shuttleSchedule === 'string' && changes.shuttleSchedule.trim()) ||
            card.shuttleSchedule
          const tz =
            (typeof changes.shuttleTz === 'string' && changes.shuttleTz.trim()) ||
            card.shuttleTz || 'UTC'
          if (!schedule) {
            throw new Error('standing-kind shuttle blocks require a schedule (cron expression)')
          }
          reinstall = {
            action: 'repeat', origin, fiber: fiberId,
            schedule, tz, model: targetAgent, project_dir: projectDir,
          }
        } else {
          reinstall = {
            action: 'install', origin, fiber: fiberId,
            model: targetAgent, project_dir: projectDir, disabled: wasDisabled,
          }
        }

        // Uninstall first — install/repeat refuse to clobber. Skip when no
        // block exists yet (the patch installs fresh).
        if (card.shuttleKind !== undefined) {
          await this.postLifecycle({ action: 'uninstall', origin, fiber: fiberId })
        }
        await this.postLifecycle(reinstall)
      } else if (typeof changes.shuttleAgent === 'string' && changes.shuttleAgent) {
        // Agent-only change is the daemon's `set-model` lifecycle action —
        // preserves session.id + review history and the rest of the block.
        await this.postLifecycle({
          action: 'set-model', origin, fiber: fiberId, agent: changes.shuttleAgent,
        })
      }

      // Reparent: the daemon's `/felt-nest` shells `felt nest`/`felt unnest`
      // on the owning host. The grid refetch reconciles the changed id.
      if ('parentId' in changes) {
        const res = await fetch(`${this.shuttleBase}/api/v1/felt-nest`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ fiber_id: fiberId, origin, parent: changes.parentId ?? null }),
        })
        if (!res.ok) {
          const errText = await res.text().catch(() => `${res.status}`)
          throw new Error(errText || `Save failed: ${res.status}`)
        }
      }

      // Refresh the kanban so the change shows up in the grid (and in any
      // other modal that's reading the same card). The detail modal stays
      // open — the user may want to keep editing.
      this.onSaved()
      statusEl.textContent = 'Saved'
      statusEl.classList.remove('kbn-detail-save-status-saving')
      statusEl.classList.add('kbn-detail-save-status-saved')
      window.setTimeout(() => {
        // Fade the "Saved" indicator after a beat if nothing else has
        // overwritten it in the meantime.
        if (statusEl.textContent === 'Saved') {
          statusEl.textContent = ''
          statusEl.classList.remove('kbn-detail-save-status-saved')
        }
      }, 1500)
      return true
    } catch (err: unknown) {
      const msg = (err as { message?: string })?.message ?? String(err)
      errorEl.textContent = msg
      errorEl.style.display = ''
      statusEl.textContent = ''
      statusEl.classList.remove('kbn-detail-save-status-saving')
      return false
    }
  }
}

/** Compact "2m / 3h / 5d ago" stamp for the sent-files strip. */
function relativeTime(timestamp: number): string {
  const deltaMs = Date.now() - timestamp
  if (deltaMs < 60_000) return 'just now'
  const minutes = Math.floor(deltaMs / 60_000)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}
