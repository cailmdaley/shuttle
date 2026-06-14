import { useCallback, useEffect, useMemo, useState } from 'react'
import { Theme } from '@myst-theme/common'
import { ArticleProvider, ThemeProvider, mergeRenderers } from '@myst-theme/providers'
import { DEFAULT_RENDERERS } from 'myst-to-react'
import { SourceFileKind } from 'myst-spec-ext'
import type { References } from 'myst-common'
import {
  AstraDataProvider,
  DecisionsView,
  FindingsView,
  InputsList,
  LIGHTCONE_OVERRIDES,
  Masthead,
  OutputsGallery,
  PaperSidebar,
  PaperView,
  ThemeToggle,
} from '@lightcone/renderer'
import { THEME_ATTRIBUTE } from '@lightcone/styles'
import {
  loadPaper,
  type AstraPageData,
  type BakedPage,
  type BakedPaper,
  type LoadPaperArgs,
} from './content'

/**
 * The ASTRA paper view, standalone. Mirrors lightcone-ui's theme-paper
 * `root.tsx`: a ThemeProvider exposing the merged renderer set (upstream
 * `DEFAULT_RENDERERS` first, `LIGHTCONE_OVERRIDES` composed on top so the
 * finding-/decision-/figure/table selectors slot in alongside the base), then
 * the active surface — the `PaperView` narrative, or one of the
 * decisions/outputs/inputs/findings SURFACES.
 *
 * Surface routing is in-app. lightcone-ui's app gives each surface a real route
 * (`/findings`, `/outputs`, …) under React Router; we have no router and the
 * paper is mounted at `paper.html?path=…`, so those sidebar links would
 * navigate the iframe off the entry into a blank page. Instead we intercept the
 * nav clicks (`onClickInterceptNav`) and swap an in-memory `surface` — same
 * sidebar, same components, no navigation.
 *
 * Runs in its own document (the fiber panel mounts paper.html in an <iframe>),
 * so Tailwind's preflight + the parchment html/body base stay isolated from the
 * kanban board.
 */

type Surface = 'narrative' | 'findings' | 'outputs' | 'decisions' | 'inputs'

const SURFACE_LABELS: Record<Exclude<Surface, 'narrative'>, string> = {
  findings: 'Findings',
  outputs: 'Outputs',
  decisions: 'Decisions',
  inputs: 'Inputs',
}

/**
 * Classify a clicked link's href. A recognised surface route switches the
 * in-app surface; any *other* internal (`/…`) link is still swallowed so a
 * sub-analysis / supporting-docs link can't blank the iframe; `#`-anchors and
 * external links keep their native behavior (in-page scroll / new tab).
 */
function classifyHref(
  href: string,
): { kind: 'surface'; surface: Surface } | { kind: 'internal' } | { kind: 'external' } {
  if (!href.startsWith('/')) return { kind: 'external' }
  const path = href.split(/[?#]/)[0]
  if (path === '/') return { kind: 'surface', surface: 'narrative' }
  const m = path.match(/\/(findings|outputs|decisions|inputs)(?:\/|$)/)
  if (m) return { kind: 'surface', surface: m[1] as Surface }
  return { kind: 'internal' }
}

export function PaperApp(args: LoadPaperArgs) {
  const [theme, setTheme] = useState<Theme>(Theme.light)
  const [paper, setPaper] = useState<BakedPaper | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [surface, setSurface] = useState<Surface>('narrative')

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
    setSurface('narrative')
    loadPaper(args)
      .then((p) => live && setPaper(p))
      .catch((e) => live && setError(String(e?.message ?? e)))
    return () => {
      live = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [args.path, args.origin, args.universe, args.fixture])

  // Surface nav: a sidebar link to a surface route swaps the in-app surface;
  // other internal links are swallowed (no blank iframe). Scroll to top so the
  // new surface reads from its head, not the narrative's scroll position.
  const onClickInterceptNav = useCallback((e: React.MouseEvent) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return
    const anchor = (e.target as HTMLElement | null)?.closest?.('a')
    const href = anchor?.getAttribute('href')
    if (!href) return
    const c = classifyHref(href)
    if (c.kind === 'external') return
    e.preventDefault()
    if (c.kind === 'surface') {
      setSurface(c.surface)
      window.scrollTo({ top: 0 })
    }
  }, [])

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

  const astra: AstraPageData | null =
    paper.astra?.[page.slug] ?? paper.astra?.index ?? null

  return (
    <ThemeProvider theme={theme} setTheme={setThemeAndPersist} renderers={renderers}>
      <div onClick={onClickInterceptNav}>
        {surface === 'narrative' ? (
          <PaperView
            article={{ slug: page.slug, mdast: page.ast, frontmatter: page.frontmatter }}
            astra={astra}
          />
        ) : (
          <SurfaceView surface={surface} page={page} astra={astra} />
        )}
      </div>
    </ThemeProvider>
  )
}

/**
 * A non-narrative surface — the same shell lightcone-ui's `SurfacePage` builds
 * (`ArticleProvider` + `AstraDataProvider`, masthead, section label, the
 * surface view, then the sidebar). Findings/Decisions walk the page mdast;
 * Outputs/Inputs read the structured `{outputs, inputs}` from the bake.
 */
function SurfaceView({
  surface,
  page,
  astra,
}: {
  surface: Exclude<Surface, 'narrative'>
  page: BakedPage
  astra: AstraPageData | null
}) {
  const references = { article: page.ast } as References
  const nodes = (page.ast.children ?? []) as never
  const outputs = astra?.outputs ?? []
  const inputs = astra?.inputs ?? []

  return (
    <ArticleProvider
      kind={SourceFileKind.Article}
      references={references}
      frontmatter={page.frontmatter as never}
    >
      <AstraDataProvider value={{ inputs, outputs }}>
        <ThemeToggle />
        <main className="lc-page">
          <Masthead frontmatter={page.frontmatter} fallbackTitle={page.slug} />
          <div className="lc-page-label" aria-label="Section">
            <span className="lc-page-label__name">{SURFACE_LABELS[surface]}</span>
            <span className="lc-page-label__rule" />
          </div>
          {surface === 'findings' && <FindingsView nodes={nodes} />}
          {surface === 'outputs' && <OutputsGallery outputs={outputs} baseSlug="" />}
          {surface === 'decisions' && (
            <DecisionsView nodes={nodes} astraOutputs={outputs} scopeLabel="parent" />
          )}
          {surface === 'inputs' && <InputsList inputs={inputs} />}
        </main>
        <PaperSidebar
          mdast={page.ast}
          activeSurface={surface}
          outputs={outputs}
          includeSupportingDocuments={false}
        />
      </AstraDataProvider>
    </ArticleProvider>
  )
}
