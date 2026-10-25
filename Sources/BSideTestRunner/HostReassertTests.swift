// BSideTestRunner — HostReassert suites (Beta Slice 5).
// These exercise the EXACT pure double-hop reassert reducer StableDesktopPanelHost drives in
// production, so the stale/delayed-wake-callback generation guard proven here is the
// production-used scheduling logic — not a test mirror.

import Foundation
import BSideCore

func runHostReassertTests() {
    run("Reassert.triggerReassertsNowAndSchedulesScopedHop") { t in
        var gate = HostReassert()
        let effects = gate.onTrigger()
        t.expectEqual(effects, [.reassertNow, .scheduleReassert(generation: 1)],
                      "immediate reassert + generation-scoped second hop")
    }

    run("Reassert.currentGenerationHopApplies") { t in
        var gate = HostReassert()
        let effects = gate.onTrigger()
        guard case .scheduleReassert(let generation) = effects[1] else {
            t.expect(false, "schedule effect present"); return
        }
        t.expect(gate.reassertIfCurrent(generation: generation), "current generation hop applies")
    }

    run("Reassert.replacedHostInvalidatesPendingHop") { t in
        var gate = HostReassert()
        let effects = gate.onTrigger()
        guard case .scheduleReassert(let generation) = effects[1] else {
            t.expect(false, "schedule effect present"); return
        }
        gate.invalidate()   // host torn down / replaced before the delayed hop fires
        t.expect(!gate.reassertIfCurrent(generation: generation),
                 "stale hop cannot act on a replaced host")
    }

    run("Reassert.newestTriggerWinsAmongBursts") { t in
        var gate = HostReassert()
        let first = gate.onTrigger()
        guard case .scheduleReassert(let g1) = first[1] else { t.expect(false, "g1"); return }
        let second = gate.onTrigger()
        guard case .scheduleReassert(let g2) = second[1] else { t.expect(false, "g2"); return }
        t.expect(g2 > g1, "generations monotonic")
        t.expect(!gate.reassertIfCurrent(generation: g1), "older hop is stale")
        t.expect(gate.reassertIfCurrent(generation: g2), "newest hop is current")
    }

    run("Reassert.generationAdvancesAcrossInvalidate") { t in
        var gate = HostReassert()
        let initial = gate.generation
        let fx = gate.onTrigger()
        guard case .scheduleReassert(let g1) = fx[1] else { t.expect(false, "g1"); return }
        gate.invalidate()
        t.expect(g1 > initial, "trigger advances generation")
        t.expect(gate.generation > g1, "invalidate advances generation again")
    }
}
