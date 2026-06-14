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
  import type { ComponentType, ReactNode } from 'react'
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

  /** A structured ASTRA output (from MySTRA's buildASTRADataMap). */
  export interface OutputEntry {
    id: string
    label?: string
    type?: string
    description?: string
    /** Relative artifact URL, e.g. /static/hubble_diagram.png. */
    resolved_path?: string
    metric?: {
      value?: number | string
      uncertainty?: number | string
      error?: number | string
      unit?: string
      units?: string
    }
  }

  /** A structured ASTRA input (from MySTRA's buildASTRADataMap). */
  export interface InputEntry {
    id: string
    label?: string
    type?: string
    description?: string
    source?: string
    from?: string
  }

  export const PaperView: ComponentType<{
    article: PaperArticle
    crumbs?: unknown[]
    scopeNav?: unknown
    mastheadFrontmatter?: MastheadFrontmatter
    astra?: { inputs: InputEntry[]; outputs?: OutputEntry[] } | null
    projectLabel?: string
  }>

  // The non-narrative surfaces + the shell pieces lightcone-ui's SurfacePage
  // composes. Findings/Decisions walk the page mdast; Outputs/Inputs read the
  // structured data. Typed at the surface we use — the real source is bundled
  // by Vite through the alias; these declarations only keep `tsc` at the border.
  export const FindingsView: ComponentType<{ nodes: unknown[] }>
  export const DecisionsView: ComponentType<{
    nodes: unknown[]
    astraOutputs?: OutputEntry[]
    scopeLabel?: string
  }>
  export const OutputsGallery: ComponentType<{ outputs: OutputEntry[]; baseSlug?: string }>
  export const InputsList: ComponentType<{ inputs: InputEntry[] }>

  export const Masthead: ComponentType<{
    frontmatter?: MastheadFrontmatter
    fallbackTitle?: string
  }>
  export const PaperSidebar: ComponentType<{
    mdast: GenericParent
    activeSurface?: string
    scopeNav?: unknown
    sectionHrefBase?: string
    outputs?: OutputEntry[]
    includeSupportingDocuments?: boolean
  }>
  export const ThemeToggle: ComponentType<Record<string, never>>
  export const AstraDataProvider: ComponentType<{
    value: { inputs: InputEntry[]; outputs: OutputEntry[] }
    children?: ReactNode
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
