// On-demand MySTRA bake — the ASTRA path's leanest transform invocation.
//
// MySTRA ships no `bake` subcommand: its CLI only boots a long-running Express
// content server. But the astra.yaml -> mdast transform is a pure, synchronous,
// offline library pair (`loadASTRASource` + `buildAllPages`). This wrapper calls
// them directly and writes the page bundle to stdout, so the Shuttle daemon can
// shell out once per opened astra.yaml instead of standing up a second server.
//
//   LC_MYSTRA_DIR=<mystra-checkout> node bake.mjs <projectDir> [universe]
//     -> stdout: { pages: [{ slug, title, level, ast, frontmatter, ... }] }
//
// `ast` is the mdast root the @lightcone/renderer consumes. The transform is
// offline; figure nodes carry `/static/<id>.<ext>` URLs the daemon serves
// separately, and citations degrade to plain DOI links without a DOI cache.
//
// MySTRA resolution mirrors lightcone-ui's CLI: $LC_MYSTRA_DIR, else a sibling
// checkout next to this repo's parent projects dir. We import its built
// `dist/index.js` (run `npm install && npm run build` in the MySTRA checkout
// once — its dist/ is gitignored).

import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

function resolveMystraDist() {
  const fromEnv = process.env.LC_MYSTRA_DIR
  const candidates = [
    fromEnv && join(fromEnv, 'dist', 'index.js'),
    // sibling of the projects dir: <projects>/LightconeResearch/MySTRA
    resolve(dirname(fileURLToPath(import.meta.url)), '../../../LightconeResearch/MySTRA/dist/index.js'),
  ].filter(Boolean)
  const hit = candidates.find((p) => existsSync(p))
  if (!hit) {
    throw new Error(
      `MySTRA dist not found. Set LC_MYSTRA_DIR to a built MySTRA checkout ` +
        `(npm install && npm run build there). Looked at:\n  ${candidates.join('\n  ')}`,
    )
  }
  return hit
}

const [projectDir, universe] = process.argv.slice(2)
if (!projectDir) {
  process.stderr.write('usage: node bake.mjs <projectDir> [universe]\n')
  process.exit(2)
}

const { loadASTRASource, buildAllPages } = await import(pathToFileURL(resolveMystraDist()).href)
const src = loadASTRASource(resolve(projectDir), universe)
const pages = buildAllPages(src.analysis, src.universe, src.results, src.projectDir)
process.stdout.write(JSON.stringify({ pages }))
