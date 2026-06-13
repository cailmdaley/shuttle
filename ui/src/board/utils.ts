import { marked } from 'marked'
import markedKatex from 'marked-katex-extension'
import 'katex/dist/katex.min.css'

// Configure marked for safe rendering with KaTeX math support
marked.setOptions({
  gfm: true,        // GitHub Flavored Markdown
  breaks: true,     // Convert \n to <br>
})

// $..$ for inline math, $$...$$ for display math
marked.use(markedKatex({
  throwOnError: false,
  output: 'html',
  nonStandard: true, // allow $...$ after punctuation like hyphen (pseudo-$C_\ell$)
}))

// Custom renderer for code blocks to integrate with Prism
const renderer = new marked.Renderer()
renderer.code = ({ text, lang }: { text: string; lang?: string }) => {
  const language = lang || 'plaintext'
  // Prism will highlight after DOM insertion
  const escapedCode = escapeHtml(text)
  return `<pre class="md-code-block language-${language}"><code class="language-${language}">${escapedCode}</code></pre>`
}

renderer.codespan = ({ text }: { text: string }) => {
  return `<code class="md-inline-code">${escapeHtml(text)}</code>`
}

renderer.link = ({ href, text }: { href: string; text: string }) => {
  return `<a href="${escapeHtml(href)}" class="md-link" target="_blank" rel="noopener">${text}</a>`
}

// Strip KaTeX HTML from image alt text (marked-katex-extension processes $ inside alt)
renderer.image = ({ href, text: alt }: { href: string; text?: string }) => {
  const cleanAlt = (alt || '').replace(/<[^>]*>/g, '')
  return `<img src="${escapeHtml(href)}" alt="${escapeHtml(cleanAlt)}" loading="lazy" />`
}

marked.use({ renderer })

// GFM del rule matches ~text~ (single tilde) as well as ~~text~~ (double).
// Tilde is common as an approximation sign (~2 days), so escape lone tildes
// before parsing — but only outside code spans and fenced code blocks.
marked.use({
  hooks: {
    preprocess(src: string): string {
      // Split on code regions (fenced blocks or backtick spans) and only
      // process the non-code segments.
      const CODE_REGION = /(```[\s\S]*?```|`[^`]*`)/g
      const parts = src.split(CODE_REGION)
      return parts.map((part, i) => {
        // Odd indices are the captured code regions — leave untouched
        if (i % 2 === 1) return part
        // Even indices are plain text — escape lone tildes
        return part.replace(/~+/g, (m) => {
          const pairs = Math.floor(m.length / 2)
          const rem = m.length % 2
          return '~~'.repeat(pairs) + (rem ? '&#126;' : '')
        })
      }).join('')
    },
  },
})

/**
 * Escape HTML to prevent XSS
 */
export function escapeHtml(text: string): string {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

// Local/relative image paths in rendered markdown resolve through the Shuttle
// daemon's owner-routed file route (GET /api/v1/file?path=&origin=). Relative,
// so both the daemon-served bundle and the dev proxy reach :4000 without CORS.
// The kanban board renders outcomes without a basePath, so this branch is
// dormant for the board today; the file route itself lands with the backend
// slice. (Portolan's :4004 /file-content service is eliminated per the
// Shuttle-UI constitution.)
const FILE_ROUTE = `/api/v1/file`

interface RenderMarkdownOptions {
  /** Base directory for resolving relative image paths (e.g. city path) */
  basePath?: string
  /** Origin ID for remote (owner-routed) file access */
  originId?: string
}

/**
 * Render markdown to HTML with syntax highlighting.
 * Relative image paths resolve through the Shuttle /file route when basePath is provided.
 */
export function renderMarkdown(text: string, opts?: RenderMarkdownOptions): string {
  try {
    // Use a per-call renderer to handle image path resolution
    if (opts?.basePath) {
      const localRenderer = new marked.Renderer()
      // Inherit code/codespan/link from the global renderer
      localRenderer.code = renderer.code
      localRenderer.codespan = renderer.codespan
      localRenderer.link = renderer.link
      localRenderer.image = ({ href, text: alt }: { href: string; text?: string }) => {
        let src = href
        // Resolve relative paths through the file-content API
        if (!/^https?:\/\//.test(href) && !/^data:/.test(href)) {
          const fullPath = href.startsWith('/') ? href : `${opts.basePath}/${href}`
          src = `${FILE_ROUTE}?path=${encodeURIComponent(fullPath)}`
          if (opts.originId && opts.originId !== 'local') {
            src += `&origin=${encodeURIComponent(opts.originId)}`
          }
        }
        const cleanAlt = (alt || '').replace(/<[^>]*>/g, '')
        return `<img src="${escapeHtml(src)}" alt="${escapeHtml(cleanAlt)}" loading="lazy" />`
      }
      return marked.parse(text, { renderer: localRenderer }) as string
    }
    return marked.parse(text) as string
  } catch (e) {
    console.error('Markdown render error:', e)
    return escapeHtml(text)
  }
}

/**
 * Resolve config[key] / config.x.y / config.yaml: x.y references in rendered markdown.
 * Appends " = value" annotations to matching inline code elements.
 */
export function interpolateConfig(container: HTMLElement, config: Record<string, string>): void {
  container.querySelectorAll<HTMLElement>('p code, td code, li code, h1 code, h2 code, h3 code').forEach(code => {
    const text = code.textContent?.trim() || ''
    const key = text
      .replace(/^config\.yaml:\s*/, '')
      .replace(/^config\[["']?/, '').replace(/["']?\]$/, '')
      .replace(/["']?\]\[["']?/g, '.')
      .replace(/^config\./, '')
    const value = config[key]
    if (value !== undefined) {
      const display = value.length > 60 ? value.slice(0, 57) + '...' : value
      code.textContent = display
      code.classList.add('config-resolved')
      code.title = key  // hover shows original key
    }
  })
}

// Matches inline code that looks like a file path, e.g. server/src/index.ts or ./foo/bar.py:42
// Also accepts :L42 or :L42-55 (GitHub-style line range) — both colon-digit and colon-L-digit forms work.
const INLINE_PATH_RE = /^(?:\.{0,2}\/)?[\w.\-/]+\/[\w.\-]+\.[a-zA-Z]{1,10}(?::L?\d+(?:-\d+)?)?$|^\.\/[\w.\-/]+\.[a-zA-Z]{1,10}(?::L?\d+(?:-\d+)?)?$/

function parsePathReference(value: string): { path: string; line?: number } | null {
  const text = value.trim()
  const m = text.match(/^(.*?)(?::L?(\d+)(?:-\d+)?)?$/)
  if (!m || !INLINE_PATH_RE.test(text)) return null
  return {
    path: m[1],
    line: m[2] ? parseInt(m[2], 10) : undefined,
  }
}

/**
 * Find inline <code> elements whose text looks like a file path and make them clickable.
 * `openFile(path, line)` is called with the resolved relative path and optional line number.
 */
export function attachInlinePathListeners(
  container: HTMLElement,
  openFile: (path: string, line?: number) => void,
): void {
  container.querySelectorAll<HTMLElement>('code.md-inline-code').forEach(code => {
    const parsed = parsePathReference(code.textContent || '')
    if (!parsed) return
    const { path, line } = parsed
    code.style.cursor = 'pointer'
    code.title = line ? `Open ${path} at line ${line}` : `Open ${path}`
    code.addEventListener('click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      openFile(path, line)
    })
  })
}

export function attachMarkdownPathLinkListeners(
  container: HTMLElement,
  openFile: (path: string, line?: number) => void,
): void {
  container.querySelectorAll<HTMLAnchorElement>('a.md-link').forEach(link => {
    const href = link.getAttribute('href') || ''
    const parsed = parsePathReference(href)
    if (!parsed) return
    const { path, line } = parsed
    link.target = ''
    link.rel = ''
    link.title = line ? `Open ${path} at line ${line}` : `Open ${path}`
    link.addEventListener('click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      openFile(path, line)
    })
  })
}

/**
 * Apply Prism syntax highlighting to code blocks in a container
 * Call after inserting markdown HTML into the DOM
 */
export function highlightCodeBlocks(container: HTMLElement): void {
  if (typeof window !== 'undefined' && (window as unknown as { Prism?: { highlightAllUnder: (el: HTMLElement) => void } }).Prism) {
    (window as unknown as { Prism: { highlightAllUnder: (el: HTMLElement) => void } }).Prism.highlightAllUnder(container)
  }
}

/**
 * Format a timestamp as relative time (e.g., "5m ago", "2h ago")
 * Returns empty string for invalid timestamps
 */
export function formatTimeAgo(timestamp: number): string {
  // Handle NaN/invalid timestamps (e.g., from malformed date strings)
  if (!Number.isFinite(timestamp)) return ''

  const diffMs = Date.now() - timestamp
  const diffMins = Math.floor(diffMs / 60000)

  if (diffMins < 1) return 'just now'
  if (diffMins < 60) return `${diffMins}m ago`

  const diffHours = Math.floor(diffMins / 60)
  if (diffHours < 24) return `${diffHours}h ago`

  const diffDays = Math.floor(diffHours / 24)
  if (diffDays < 7) return `${diffDays}d ago`

  return new Date(timestamp).toLocaleDateString()
}

/**
 * Format an ISO date string as "20 Feb 2026".
 */
export function formatFiberDate(iso: string | null | undefined): string {
  if (!iso) return ''
  try {
    return new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
  } catch { return iso }
}


/**
 * Map fiber status to a compact icon glyph.
 * active = half-filled, open = hollow, closed = filled, statusless = diamond
 * (structural container, not a task state).
 */
export function fiberStatusIcon(status: string): string {
  if (status === 'active') return '◐'
  if (status === 'closed') return '●'
  if (status === 'open') return '○'
  return '◇'
}

/**
 * Show a toast notification
 */
export function showToast(message: string, type: 'success' | 'error' = 'success', duration = 3000): void {
  // Remove existing toasts
  const existing = document.querySelector('.portolan-toast')
  if (existing) existing.remove()

  const toast = document.createElement('div')
  toast.className = 'portolan-toast'
  toast.innerHTML = `
    <span class="toast-icon">${type === 'success' ? '✓' : '✕'}</span>
    <span class="toast-message">${escapeHtml(message)}</span>
  `

  // Inject styles if not present
  if (!document.getElementById('portolan-toast-styles')) {
    const style = document.createElement('style')
    style.id = 'portolan-toast-styles'
    style.textContent = `
      .portolan-toast {
        position: fixed;
        bottom: 24px;
        left: 50%;
        transform: translateX(-50%) translateY(100px);
        background: #1a1a1a;
        color: #f5f5f0;
        padding: 12px 20px;
        border-radius: 8px;
        display: flex;
        align-items: center;
        gap: 10px;
        font-family: 'EB Garamond', Garamond, serif;
        font-size: 14px;
        box-shadow: 0 4px 20px rgba(0,0,0,0.4);
        z-index: 10000;
        opacity: 0;
        animation: toast-in 0.3s ease forwards;
      }
      .portolan-toast.toast-out {
        animation: toast-out 0.3s ease forwards;
      }
      .portolan-toast .toast-icon {
        font-size: 16px;
        font-weight: bold;
      }
      .portolan-toast.success .toast-icon { color: #c9a959; }
      .portolan-toast.error .toast-icon { color: #d9534f; }
      @keyframes toast-in {
        from { opacity: 0; transform: translateX(-50%) translateY(100px); }
        to { opacity: 1; transform: translateX(-50%) translateY(0); }
      }
      @keyframes toast-out {
        from { opacity: 1; transform: translateX(-50%) translateY(0); }
        to { opacity: 0; transform: translateX(-50%) translateY(100px); }
      }
    `
    document.head.appendChild(style)
  }

  toast.classList.add(type)
  document.body.appendChild(toast)

  setTimeout(() => {
    toast.classList.add('toast-out')
    setTimeout(() => toast.remove(), 300)
  }, duration)
}
