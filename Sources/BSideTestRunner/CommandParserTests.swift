// BSideTestRunner — CommandParser suites (deterministic command bar mapping).

import Foundation
import BSideCore

func runCommandParserTests() {
    run("Parser.nightR2") { t in
        var d = DesiredState(scene: .a, outfit: .r1, timeMode: .auto)
        let error = CommandParser.apply("夜晚 R2", to: &d)
        t.expectNil(error, "recognized")
        t.expectEqual(d.scene, Scene.a, "scene unchanged")
        t.expectEqual(d.outfit, Outfit.r2, "outfit r2")
        t.expectEqual(d.timeMode, TimeMode.fixed(.night), "night fixed")
    }

    run("Parser.musicVolumePercent") { t in
        var d = DesiredState()
        d.musicMuted = true
        let error = CommandParser.apply("音乐 20%", to: &d)
        t.expectNil(error, "recognized")
        t.expectNear(d.musicVolume, 0.2, "volume parsed")
        t.expect(!d.musicMuted, "mute cleared")
    }

    run("Parser.ambientMuteAndResume") { t in
        var d = DesiredState(paused: true)
        let muteError = CommandParser.apply("环境音静音", to: &d)
        t.expectNil(muteError, "mute ok")
        t.expect(d.ambientMuted, "ambient muted")
        t.expect(!d.musicMuted, "music unaffected")
        let resumeError = CommandParser.apply("恢复", to: &d)
        t.expectNil(resumeError, "resume ok")
        t.expect(!d.paused, "resumed")
    }

    run("Parser.pauseAndProfiles") { t in
        var d = DesiredState()
        _ = CommandParser.apply("暂停", to: &d)
        t.expect(d.paused, "paused")
        _ = CommandParser.apply("工作模式", to: &d)
        t.expectEqual(d.profile.id, "coding", "coding profile")
        _ = CommandParser.apply("电影", to: &d)
        t.expectEqual(d.profile.id, "movie", "movie profile")
    }

    run("Parser.unmatchedInputReportsError") { t in
        var d = DesiredState()
        let error = CommandParser.apply("跳舞给我看", to: &d)
        t.expectNotNil(error, "unknown → hint")
        t.expectEqual(d, DesiredState(), "state untouched")
    }

    run("Parser.masterVolumeAlias") { t in
        var d = DesiredState()
        let error = CommandParser.apply("音量50", to: &d)
        t.expectNil(error, "recognized")
        t.expectNear(d.masterVolume, 0.5, "master halved")
    }
}
