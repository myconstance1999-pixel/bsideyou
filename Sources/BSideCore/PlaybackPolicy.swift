// BSideCore — PlaybackPolicy: THE single decision point for "should it play / how loud" (ADR-005).
// Pure function; table-tested; worst condition wins (Phosphene-derived pattern, rewritten).

public enum PlaybackPolicy {
    public static func performanceLighting(desired: DesiredState, minuteOfDay: Int) -> PerformanceLighting {
        let time: TimeOfDay
        switch desired.timeMode {
        case .auto: time = TimeOfDay.autoBucket(minuteOfDay: minuteOfDay)
        case .fixed(let fixed): time = fixed
        }
        switch time { case .noon: return .daylight; case .evening: return .sunset; case .night: return .night }
    }

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Fold every active condition into one EffectivePlaybackState.
    public static func evaluate(
        desired: DesiredState, context: RuntimeContext, minuteOfDay: Int? = nil, performance: PerformanceSession? = nil,
        performanceAwaitingNext: Bool = false
    ) -> EffectivePlaybackState {
        var reasons: [String] = []
        var visualPaused = false
        var performancePaused = false
        var audioMuted = false
        var factor = 1.0

        func pauseAll(_ why: String) {
            visualPaused = true
            performancePaused = true
            audioMuted = true
            reasons.append(why)
        }

        // 1. Explicit user pause pauses everything.
        if desired.paused { pauseAll("user-paused") }

        if desired.dailyVisualPaused {
            visualPaused = true
            reasons.append("daily-user-paused")
        }

        // 2. Profile-level visual pause (e.g. Movie) mutes audio too by construction.
        if desired.profile.visualPaused {
            pauseAll("profile:\(desired.profile.id)")
        }

        // 3. System asleep — nothing should run (safety; monitors usually stop us earlier).
        if !context.systemAwake { pauseAll("system-asleep") }

        // 4. Screen asleep — pause everything (nobody is watching; save power).
        if !context.screenAwake { pauseAll("screen-asleep") }

        // 4b. Screen locked — lock screen covers the desktop; pause everything.
        if context.screenLocked { pauseAll("screen-locked") }

        // 4c. Fast user switching leaves this agent alive in an inactive session.
        if !context.sessionActive { pauseAll("session-inactive") }

        // 5. Serious/critical thermal pressure removes media work until the system recovers.
        // Scaling volume alone does not stop video or audio decoding.
        switch context.thermal {
        case .critical:
            pauseAll("thermal-critical")
        case .serious:
            pauseAll("thermal-serious")
        case .fair, .nominal:
            break
        }

        // 6. Other fullscreen apps suppress only unattended daily imagery. The selected
        // companion soundtrack and explicit songs keep their independent clocks across Spaces.
        if context.fullscreenAppActive && desired.pauseVisualOnFullscreen && !context.homeCompanionVisible {
            visualPaused = true
            reasons.append("fullscreen-app")
        }

        // 7. Low Power Mode freezes unattended daily imagery. The owner explicitly permits
        // animation while the home surface is actually visible.
        // The independent song clock is unaffected by daily-only restrictions.
        // Thermal/system/user restrictions still win for every media clock.
        if context.lowPowerMode && !context.homeCompanionVisible {
            visualPaused = true
            reasons.append("low-power:daily-static")
        }

        // 7b. A covered desktop needs no continuing daily animation. Keep requested audio;
        // ordinary windows covering an explicit performance must not interrupt listening.
        if !context.desktopVisible && !context.homeCompanionVisible {
            visualPaused = true
            reasons.append("desktop-occluded")
        }

        // 8. Per-app rules from the active profile, matched against the foreground app.
        if let bundleID = context.foregroundAppBundleID,
           let rule = desired.profile.appRules.first(where: { $0.bundleID == bundleID }) {
            switch rule.action {
            case .pauseAll:
                pauseAll("app-rule:\(bundleID):pause")
            case .muteAudio:
                audioMuted = true
                reasons.append("app-rule:\(bundleID):mute")
            case .duckAudio:
                factor = min(factor, desired.profile.clampDuck(rule))
                reasons.append("app-rule:\(bundleID):duck")
            }
        }

        // A song has its own audiovisual clock. Session pause and queue handoff never
        // pause daily companionship; daily visual restrictions never pause the song.
        if let performance {
            if performanceAwaitingNext {
                performancePaused = true
                audioMuted = true
                reasons.append("performance-awaiting-next")
            }
            if performance.paused {
                performancePaused = true
                audioMuted = true
                reasons.append("performance-paused")
            }
        }

        // Final volumes: master × channel × profile factor × contextual factor × mute flags.
        let musicBase = desired.masterVolume * desired.musicVolume * desired.profile.musicFactor
        let ambientBase = desired.masterVolume * desired.ambientVolume * desired.profile.ambientFactor
        let music = audioMuted ? 0 : Self.clamp(musicBase * factor)
        let ambient = audioMuted ? 0 : Self.clamp(ambientBase * factor)
        // A muted channel from user intent still zeroes out even without contextual mute.
        let musicFinal = desired.musicMuted ? 0 : music
        let ambientFinal = desired.ambientMuted || desired.dailySoundtrack == .silent ? 0 : ambient

        let ambientPaused = performance == nil && desired.dailyMusicPaused && ambientFinal > 0
        if performance == nil && desired.dailyMusicPaused { reasons.append("daily-music-paused") }

        return EffectivePlaybackState(
            visual: visualPaused ? .paused : .full,
            musicVolume: musicFinal,
            ambientVolume: performance == nil && !ambientPaused ? ambientFinal : 0,
            performancePaused: performance != nil && performancePaused,
            ambientPaused: ambientPaused,
            reasons: reasons
        )
    }
}

extension Profile {
    /// Clamp helper used by policy for `.duckAudio` rules.
    func clampDuck(_ rule: AppRule) -> Double { min(max(rule.duckFactor, 0), 1) }
}
