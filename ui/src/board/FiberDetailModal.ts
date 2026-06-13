/**
 * FiberDetailModal — viewer seam shim.
 *
 * Portolan's FiberDetailModal was a rich floating side-panel (outcome,
 * history, sent-files strip, reshape controls, a Three.js-adjacent file
 * viewer). The Shuttle UI constitution cuts that panel: "opening a fiber =
 * opening a file" — a clicked card opens the *viewer*, not a bespoke panel.
 *
 * So this shim keeps `KanbanModal.ts` a near-verbatim port (it still
 * constructs and calls `.open()` / `.close()`) while routing the open through
 * the host's `onOpenFiber` callback. The board slice wires `onOpenFiber` to a
 * placeholder; the viewer slice (@lightcone/renderer) replaces that callback
 * with the real fiber/file render. The constructor accepts the full Portolan
 * argument list and ignores everything it no longer needs.
 *
 * Terminal moves (Temper / Compost) are unaffected — they already route
 * through the inline card buttons' optimistic `transition()` path, not this
 * panel.
 */
import type { ColumnKind, KanbanCard } from './KanbanTypes.js'

export class FiberDetailModal {
  private readonly onOpenFiber: (
    card: KanbanCard,
    options?: { openInNewWindow?: boolean },
  ) => void

  constructor(
    _shuttleBase: string,
    onOpenFiber: (card: KanbanCard, options?: { openInNewWindow?: boolean }) => void,
    _onSaved: () => void,
    _onAttachFreshTmux?: (tmuxSessionName: string) => void,
    _onTransition?: (card: KanbanCard, target: ColumnKind) => void,
    _onOpenWorker?: (tmuxSessionName: string, shuttleHost?: string) => void,
    _resolveCityProjectPath?: (cityId: string) => string | undefined,
    _opts?: {
      onOpenFile?: (fullPath: string, originId: string) => void
      portolanBase?: string
    },
  ) {
    this.onOpenFiber = onOpenFiber
  }

  /** Click a card → open it in the viewer. (scopeCityId / columnKind were only
   *  meaningful to the old in-panel content fetch; the viewer fetches by the
   *  card's loom-relative id, owner-routed by origin.) */
  open(card: KanbanCard, _scopeCityId?: string | null, _columnKind?: ColumnKind): void {
    this.onOpenFiber(card)
  }

  /** No floating panel to tear down. */
  close(): void {}
}
