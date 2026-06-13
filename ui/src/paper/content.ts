import type { GenericParent } from 'myst-common'
import type { MastheadFrontmatter } from '@lightcone/renderer'

/**
 * One baked page, as MySTRA's `buildAllPages` emits it (see priv/mystra/bake.mjs).
 * `ast` is the mdast root the renderer consumes; the root analysis is slug
 * `index`, sub-analyses get their own slugs.
 */
export interface BakedPage {
  slug: string
  title: string
  level: number
  ast: GenericParent
  frontmatter?: MastheadFrontmatter
  identifiers?: string[]
  dependencies?: unknown
  dois?: unknown
}

export interface BakedPaper {
  pages: BakedPage[]
}

export interface LoadPaperArgs {
  /** Absolute path to the astra.yaml's project dir (owner-routed via origin). */
  path?: string | null
  /** Origin id; omitted/empty/local → the local daemon bakes it. */
  origin?: string | null
  /** Optional universe selection. */
  universe?: string | null
  /** Dev-only: load a static baked fixture from /fixtures/<name>.json. */
  fixture?: string | null
}

/**
 * Fetch the baked paper. Production path: the daemon's owner-routed
 * `GET /api/v1/astra?path=&origin=&universe=` shells out to bake.mjs and
 * returns `{ pages }`. Dev path: `?fixture=iris` loads a locally-baked,
 * gitignored fixture (regenerate via priv/mystra/bake.mjs) so the render is
 * verifiable without a running daemon or MySTRA. Dead-code-eliminated in a
 * production build (`import.meta.env.DEV` is statically false).
 */
export async function loadPaper(args: LoadPaperArgs): Promise<BakedPaper> {
  if (import.meta.env.DEV && args.fixture) {
    const res = await fetch(`/fixtures/${encodeURIComponent(args.fixture)}.json`)
    if (!res.ok) throw new Error(`fixture ${args.fixture} not found (${res.status})`)
    return (await res.json()) as BakedPaper
  }

  if (!args.path) throw new Error('no astra.yaml path given')

  const params = new URLSearchParams({ path: args.path })
  if (args.origin) params.set('origin', args.origin)
  if (args.universe) params.set('universe', args.universe)

  const res = await fetch(`/api/v1/astra?${params.toString()}`)
  if (!res.ok) {
    const detail = await res.text().catch(() => '')
    throw new Error(detail || `astra bake failed (${res.status})`)
  }
  return (await res.json()) as BakedPaper
}
