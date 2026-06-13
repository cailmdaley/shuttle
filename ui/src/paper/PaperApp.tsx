import { useCallback, useEffect, useMemo, useState } from 'react'
import { Theme } from '@myst-theme/common'
import { ThemeProvider, mergeRenderers } from '@myst-theme/providers'
import { DEFAULT_RENDERERS } from 'myst-to-react'
import { LIGHTCONE_OVERRIDES, PaperView } from '@lightcone/renderer'
import { THEME_ATTRIBUTE } from '@lightcone/styles'
import { loadPaper, type BakedPaper, type LoadPaperArgs } from './content'

/**
 * The ASTRA paper view, standalone. Mirrors lightcone-ui's theme-paper
 * `root.tsx`: a ThemeProvider exposing the merged renderer set (upstream
 * `DEFAULT_RENDERERS` first, `LIGHTCONE_OVERRIDES` composed on top so the
 * finding-/decision-/figure/table selectors slot in alongside the base), then
 * `PaperView` rendering the baked mdast.
 *
 * Runs in its own document (the fiber panel mounts paper.html in an <iframe>),
 * so Tailwind's preflight + the parchment html/body base stay isolated from the
 * kanban board.
 */
export function PaperApp(args: LoadPaperArgs) {
  const [theme, setTheme] = useState<Theme>(Theme.light)
  const [paper, setPaper] = useState<BakedPaper | null>(null)
  const [error, setError] = useState<string | null>(null)

  const renderers = useMemo(
    () => mergeRenderers([DEFAULT_RENDERERS, LIGHTCONE_OVERRIDES]),
    [],
  )

  useEffect(() => {
    document.documentElement.setAttribute(THEME_ATTRIBUTE, theme)
  }, [theme])

  const setThemeAndPersist = useCallback((next: Theme) => setTheme(next), [])

  useEffect(() => {
    let live = true
    setError(null)
    setPaper(null)
    loadPaper(args)
      .then((p) => live && setPaper(p))
      .catch((e) => live && setError(String(e?.message ?? e)))
    return () => {
      live = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [args.path, args.origin, args.universe, args.fixture])

  if (error) {
    return (
      <main style={{ maxWidth: 720, margin: '0 auto', padding: '4rem 1.5rem' }}>
        <p style={{ fontFamily: 'var(--font-technical, monospace)', color: 'var(--color-mauve, #a87070)' }}>
          Could not render this astra.yaml: {error}
        </p>
      </main>
    )
  }

  if (!paper) {
    return (
      <main style={{ maxWidth: 720, margin: '0 auto', padding: '4rem 1.5rem' }}>
        <p style={{ fontFamily: 'var(--font-technical, monospace)', color: 'var(--color-muted, #7a7368)' }}>
          baking…
        </p>
      </main>
    )
  }

  // The root analysis is the index page; sub-analysis navigation (the scope
  // sidebar from MySTRA's config.json) is a later refinement.
  const page = paper.pages.find((p) => p.slug === 'index') ?? paper.pages[0]
  if (!page) {
    return (
      <main style={{ maxWidth: 720, margin: '0 auto', padding: '4rem 1.5rem' }}>
        <p>No pages baked from this astra.yaml.</p>
      </main>
    )
  }

  return (
    <ThemeProvider theme={theme} setTheme={setThemeAndPersist} renderers={renderers}>
      <PaperView
        article={{ slug: page.slug, mdast: page.ast, frontmatter: page.frontmatter }}
        astra={null}
      />
    </ThemeProvider>
  )
}
