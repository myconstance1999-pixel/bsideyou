// BSideCore — First-run onboarding state machine (pure; prompt rule #29 testability).
// The onboarding WINDOW lives in BSideControlApp; this type owns the logic.

public enum OnboardingStep: String, Codable, CaseIterable {
    case welcome
    case chooseResource
    case dailyBehavior
    case finish
}

public struct OnboardingState: Codable, Hashable {
    public var step: OnboardingStep
    /// Path the user picked this session (validated before reaching `dailyBehavior`).
    public var selectedPath: String?
    /// e.g. "loops:27 transitions:9 ambient:22 unknown:0"
    public var catalogSummary: String?
    public var validationError: String?
    /// Login-at-login choice: true = enable, false = not now, nil = unanswered.
    public var loginChoice: Bool?
    /// Initial profile picked on the daily-behavior step ("normal"/"quiet"/"coding").
    public var initialProfileID: String?

    public init(step: OnboardingStep = .welcome) {
        self.step = step
    }

    public mutating func advance() {
        let index = OnboardingStep.allCases.firstIndex(of: step) ?? 0
        guard OnboardingStep.allCases.indices.contains(index + 1) else { return }
        // Cannot leave the resource step without a successful validation.
        if step == .chooseResource, selectedPath == nil { return }
        step = OnboardingStep.allCases[index + 1]
    }

    public mutating func goBack() {
        let index = OnboardingStep.allCases.firstIndex(of: step) ?? 0
        guard index > 0 else { return }
        step = OnboardingStep.allCases[index - 1]
    }

    public mutating func recordValidation(path: String, summary: String?) {
        selectedPath = path
        catalogSummary = summary
        validationError = nil
    }

    public mutating func recordValidationFailure(_ message: String) {
        validationError = message
        selectedPath = nil
        catalogSummary = nil
    }

    public var isResourceValidated: Bool { selectedPath != nil && validationError == nil }
}
