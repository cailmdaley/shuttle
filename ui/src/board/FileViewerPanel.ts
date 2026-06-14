/**
 * FileViewerPanel — a sent deliverable opened as a floating page.
 *
 * Same species as the fiber-detail panel: a draggable, edge-and-corner-
 * resizable, non-modal overlay (no scrim; the board and the detail panel
 * behind stay interactive). Clicking a file in the card's sent-files strip
 * opens it here, *next to* the card, instead of mode-switching the whole
 * workspace into vellum's file viewer — "glance at the deliverable without
 * leaving the board." The header's ↗ is the escalation path to the full
 * file workspace when a glance isn't enough.
 *
 * Rendering is by extension, mirroring vellum's ArtifactEmbed dispatch:
 * images get an <img>, audio an <audio controls>, everything else an
 * <iframe> onto `/project-file/{originId}{path}?standalone=1` — the route
 * streams HTML (palette-injected, natively scrolling), PDF, and text with
 * the right Content-Type, and owner-routes remote origins.
 */

import './FileViewerPanel.css'
import {
  attachPanelDrag,
  attachPanelResize,
  readPanelGeometry,
  type PanelGeometry,
} from './FloatingPanelChrome.js'
import { paperUrl } from './utils.js'

const MIN_WIDTH = 320
const MIN_HEIGHT = 240

const IMAGE_EXTS = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'avif'])
const AUDIO_EXTS = new Set(['wav', 'mp3', 'm4a', 'ogg', 'flac', 'aac'])

/** Remembered across opens within a session (module-level, like the
 *  detail panel's) so the viewer reopens where the user left it. */
let lastGeometry: PanelGeometry | null = null

export class FileViewerPanel {
  private overlay: HTMLElement | null = null
  private escapeHandler: ((e: KeyboardEvent) => void) | null = null
  private readonly portolanBase: string
  /** Escalation to the full vellum file workspace (header ↗). Optional;
   *  absent → the glyph isn't rendered. */
  private readonly onOpenInWorkspace?: (fullPath: string, originId: string) => void
  /** Fires whenever the viewer actually closes (×, Escape, ↗, re-open).
   *  The detail panel uses it to slide back out of split view. */
  private readonly onClosed?: () => void

  constructor(opts: {
    portolanBase: string
    onOpenInWorkspace?: (fullPath: string, originId: string) => void
    onClosed?: () => void
  }) {
    this.portolanBase = opts.portolanBase
    this.onOpenInWorkspace = opts.onOpenInWorkspace
    this.onClosed = opts.onClosed
  }

  /** `opts.geometry` pins the spawn position (the detail panel passes the
   *  right half of its split); without it the viewer falls back to its
   *  remembered-then-default placement. */
  open(fullPath: string, originId: string, opts?: { geometry?: PanelGeometry }): void {
    // Replacing the current file is a swap, not a close — no onClosed, so
    // a split-view host doesn't glide back mid-split.
    this.teardown()

    const overlay = document.createElement('div')
    overlay.className = 'kbn-fileview-overlay'
    overlay.setAttribute('role', 'dialog')
    overlay.setAttribute('aria-label', basenameOf(fullPath))

    // ── Header (drag handle) ────────────────────────────────────────────
    const header = document.createElement('div')
    header.className = 'kbn-fileview-header'

    const title = document.createElement('span')
    title.className = 'kbn-fileview-title'
    title.textContent = basenameOf(fullPath)
    title.title = fullPath

    const spacer = document.createElement('span')
    spacer.className = 'kbn-fileview-spacer'

    header.append(title, spacer)

    // ⤓ Save a copy into ~/Downloads — server-side copy through the same
    // origin-routed read funnel as the viewer itself, so remote files save
    // identically (and it works inside the Tauri webview, where anchor
    // downloads don't).
    const save = document.createElement('button')
    save.type = 'button'
    save.className = 'kbn-fileview-btn'
    save.textContent = '⤓'
    save.title = 'Save to Downloads'
    save.addEventListener('click', () => {
      save.disabled = true
      void fetch(`${this.portolanBase}/save-to-downloads`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: fullPath, originId }),
      })
        .then(async (r) => {
          const body = (await r.json().catch(() => ({}))) as { savedPath?: string; error?: string }
          if (!r.ok) throw new Error(body.error ?? `HTTP ${r.status}`)
          save.textContent = '✓'
          save.title = `Saved to ${body.savedPath ?? 'Downloads'}`
        })
        .catch((err: Error) => {
          save.textContent = '⚠'
          save.title = err.message
        })
        .finally(() => {
          save.disabled = false
          window.setTimeout(() => {
            save.textContent = '⤓'
            save.title = 'Save to Downloads'
          }, 2500)
        })
    })
    header.append(save)

    if (this.onOpenInWorkspace) {
      const expand = document.createElement('button')
      expand.type = 'button'
      expand.className = 'kbn-fileview-btn'
      expand.textContent = '↗'
      expand.title = 'Open in file workspace'
      expand.addEventListener('click', () => {
        this.close()
        this.onOpenInWorkspace?.(fullPath, originId)
      })
      header.append(expand)
    }

    const closeBtn = document.createElement('button')
    closeBtn.type = 'button'
    closeBtn.className = 'kbn-fileview-btn'
    closeBtn.textContent = '×'
    closeBtn.title = 'Close'
    closeBtn.addEventListener('click', () => this.close())
    header.append(closeBtn)

    // ── Body — renderer by extension ────────────────────────────────────
    const body = document.createElement('div')
    body.className = 'kbn-fileview-body'
    body.append(this.buildViewer(fullPath, originId))

    overlay.append(header, body)
    document.body.appendChild(overlay)
    this.overlay = overlay

    this.applyGeometry(overlay, opts?.geometry, isAstraYaml(fullPath))
    attachPanelDrag(overlay, header, {
      draggingClass: 'kbn-fileview-dragging',
      onSettle: () => this.rememberGeometry(),
    })
    attachPanelResize(overlay, {
      handleClassPrefix: 'kbn-fileview-rh',
      resizingClass: 'kbn-fileview-resizing',
      minWidth: MIN_WIDTH,
      minHeight: MIN_HEIGHT,
      onSettle: () => this.rememberGeometry(),
    })

    // Escape closes the viewer first, before any panel/modal underneath —
    // capture phase + stopImmediatePropagation keeps the detail panel (and
    // the workspace modal under it) open.
    this.escapeHandler = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      // Overlay removed out from under us (tests, hot reload): detach
      // quietly without swallowing the event from whoever's underneath.
      if (!this.overlay?.isConnected) {
        this.close()
        return
      }
      e.stopImmediatePropagation()
      e.preventDefault()
      this.close()
    }
    window.addEventListener('keydown', this.escapeHandler, true)
  }

  close(): void {
    const wasOpen = this.overlay !== null
    this.teardown()
    if (wasOpen) this.onClosed?.()
  }

  private teardown(): void {
    if (this.escapeHandler) {
      window.removeEventListener('keydown', this.escapeHandler, true)
      this.escapeHandler = null
    }
    this.overlay?.remove()
    this.overlay = null
  }

  isOpen(): boolean {
    return this.overlay !== null
  }

  // ── Private ──────────────────────────────────────────────────────────

  private buildViewer(fullPath: string, originId: string): HTMLElement {
    const ext = extOf(fullPath)
    // An astra.yaml deliverable renders as the full Lightcone paper, not raw
    // YAML — the paper entry (served by the Shuttle daemon, owner-routed by
    // origin) bakes the astra.yaml's project dir, the same treatment a
    // `:::{embed} astra.yaml` gets in a fiber body. Falls back to the raw
    // bytes if the path can't resolve to a dir.
    const isAstra = isAstraYaml(fullPath)
    const src = isAstra
      ? (paperUrl(fullPath, { originId }) ?? this.projectFileUrl(fullPath, originId))
      : this.projectFileUrl(fullPath, originId)

    if (IMAGE_EXTS.has(ext)) {
      const img = document.createElement('img')
      img.className = 'kbn-fileview-image'
      img.src = src
      img.alt = basenameOf(fullPath)
      return img
    }

    if (AUDIO_EXTS.has(ext)) {
      const wrap = document.createElement('div')
      wrap.className = 'kbn-fileview-audio'
      const audio = document.createElement('audio')
      audio.controls = true
      audio.src = src
      wrap.append(audio)
      return wrap
    }

    // HTML (and any iframe-rendered) deliverable. A remote `report.html`
    // can be multi-MB and pulled over a slow link (cineca takes tens of
    // seconds), so the iframe stays blank for a while — show a loading veil
    // that lifts on `load` and flips to an error note on `error`, otherwise
    // a working-but-slow fetch reads as a broken render.
    const wrap = document.createElement('div')
    wrap.className = 'kbn-fileview-frame-wrap'

    const veil = document.createElement('div')
    veil.className = 'kbn-fileview-loading'
    veil.textContent = `Loading ${basenameOf(fullPath)}…`

    const iframe = document.createElement('iframe')
    iframe.className = 'kbn-fileview-frame'
    iframe.src = src
    iframe.title = basenameOf(fullPath)
    iframe.addEventListener('load', () => veil.remove())
    iframe.addEventListener('error', () => {
      veil.classList.add('kbn-fileview-loading-error')
      veil.textContent = `Couldn't load ${basenameOf(fullPath)}`
    })

    wrap.append(iframe, veil)
    return wrap
  }

  /** Mirrors vellum's buildRawFileUrl: /project-file/{originId}{absPath}
   *  streams html/pdf/image/audio/text with the right Content-Type and
   *  owner-routes remote origins; `standalone=1` keeps HTML natively
   *  scrollable (no height-handshake runtime). */
  private projectFileUrl(fullPath: string, originId: string): string {
    const origin = originId || 'local'
    const absPath = fullPath.startsWith('/') ? fullPath : `/${fullPath}`
    const encodedPath = absPath
      .split('/')
      .map((seg) => (seg ? encodeURIComponent(seg) : seg))
      .join('/')
    return `${this.portolanBase}/project-file/${encodeURIComponent(origin)}${encodedPath}?standalone=1`
  }

  private applyGeometry(overlay: HTMLElement, pinned?: PanelGeometry, wide = false): void {
    const vw = window.innerWidth
    const vh = window.innerHeight
    let g = pinned ?? lastGeometry
    if (g && (g.left > vw - 80 || g.top > vh - 80)) g = null
    // Default: a reading-width column hugging the right edge, so it lands
    // beside (not on top of) a centered detail panel. A paper render (astra)
    // gets a wider default — the full Lightcone chrome (two sidebars) needs
    // room — though a remembered/pinned geometry still wins.
    const width =
      g?.width ?? (wide ? Math.min(1180, Math.round(vw * 0.74)) : Math.min(720, Math.round(vw * 0.45)))
    const height = g?.height ?? vh - 48
    const left = g?.left ?? Math.max(0, vw - width - 16)
    const top = g?.top ?? Math.round((vh - height) / 2)
    overlay.style.left = `${Math.max(0, left)}px`
    overlay.style.top = `${Math.max(0, top)}px`
    overlay.style.width = `${width}px`
    overlay.style.height = `${height}px`
  }

  private rememberGeometry(): void {
    if (this.overlay) lastGeometry = readPanelGeometry(this.overlay)
  }
}

function basenameOf(path: string): string {
  return path.split('/').filter(Boolean).pop() ?? path
}

function extOf(path: string): string {
  const base = basenameOf(path)
  const dot = base.lastIndexOf('.')
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : ''
}

function isAstraYaml(path: string): boolean {
  return basenameOf(path) === 'astra.yaml'
}
