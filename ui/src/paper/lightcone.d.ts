/**
 * Type boundary for the `@lightcone/*` packages.
 *
 * They ship no dist and no `.d.ts` — we consume their TS *source* through a
 * Vite `resolve.alias` (see vite.config.ts). Without these ambient
 * declarations, `tsc` would follow the alias into another repo's source and
 * typecheck it under *our* strict config. Declaring the surface we use keeps
 * the renderer an opaque external boundary for `tsc`; Vite/esbuild still
 * bundles the real source. The myst-ecosystem peers (`myst-to-react`,
 * `@myst-theme/*`, `myst-common`, `myst-spec-ext`) DO ship types, so they need
 * no declaration here.
 */

declare module '@lightcone/renderer' {
  import type { ComponentType } from 'react'
  import type { GenericParent, References } from 'myst-common'
  import type { NodeRenderers } from '@myst-theme/providers'

  export interface MastheadFrontmatter {
    title?: string
    subtitle?: string
    authors?: unknown
    doi?: string
    date?: string
    [key: string]: unknown
  }

  export interface PaperArticle {
    slug: string
    mdast: GenericParent
    frontmatter?: MastheadFrontmatter
    references?: References
    kind?: unknown
  }

  export const PaperView: ComponentType<{
    article: PaperArticle
    crumbs?: unknown[]
    scopeNav?: unknown
    mastheadFrontmatter?: MastheadFrontmatter
    astra?: { inputs: unknown[]; outputs?: unknown[] } | null
    projectLabel?: string
  }>

  export const LIGHTCONE_OVERRIDES: NodeRenderers

  // Other layout/override exports exist but aren't part of our surface yet.
}

declare module '@lightcone/styles' {
  export const THEME_ATTRIBUTE: string
  // The package also exports a `Theme` string-union, but we use `@myst-theme/
  // common`'s `Theme` (a real typed peer) — not re-declared here to avoid two
  // `Theme` types in scope.
}
