// BSideTestRunner — OnboardingState suites (pure logic; prompt rule #29).

import Foundation
import BSideCore

func runOnboardingStateTests() {
    run("Onboarding.advanceGatedByValidation") { t in
        var state = OnboardingState()
        state.advance()
        t.expectEqual(state.step, OnboardingStep.chooseResource, "welcome → chooseResource")
        state.advance() // no validated resource yet — must NOT advance
        t.expectEqual(state.step, OnboardingStep.chooseResource, "gated: no resource validated")
        state.recordValidation(path: "/tmp/bside", summary: "loops:27")
        state.advance()
        t.expectEqual(state.step, OnboardingStep.dailyBehavior, "validated → advance")
    }

    run("Onboarding.validationFailureClearsSelection") { t in
        var state = OnboardingState()
        state.recordValidation(path: "/tmp/ok", summary: "loops:1")
        state.recordValidationFailure("bad layout")
        t.expectNil(state.selectedPath, "selection cleared")
        t.expect(!state.isResourceValidated, "not validated")
        t.expectEqual(state.validationError, "bad layout", "error surfaced")
    }

    run("Onboarding.backGoesOneStep") { t in
        var state = OnboardingState()
        state.advance()
        state.recordValidation(path: "/tmp/bside", summary: "loops:27")
        state.advance()
        state.goBack()
        t.expectEqual(state.step, OnboardingStep.chooseResource, "back one step")
        state.goBack()
        t.expectEqual(state.step, OnboardingStep.welcome, "back to welcome")
        state.goBack()
        t.expectEqual(state.step, OnboardingStep.welcome, "clamped at welcome")
    }

    run("Onboarding.codableRoundTrip") { t in
        var state = OnboardingState()
        state.recordValidation(path: "/tmp/bside", summary: "loops:27")
        state.loginChoice = false
        state.advance()
        let data = try? JSONEncoder().encode(state)
        let decoded = data.flatMap { try? JSONDecoder().decode(OnboardingState.self, from: $0) }
        t.expectEqual(decoded, state, "round trip")
    }
}
