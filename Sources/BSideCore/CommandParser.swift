// BSideCore — deterministic Command Bar parser (prompt rule #20: no AI/LLM, pure mapping).
// Applies user text to a DesiredState copy; returns an error hint when nothing matched.

public enum CommandParser {
    public static func apply(_ raw: String, to state: inout DesiredState) -> String? {
        let text = raw.lowercased().replacingOccurrences(of: " ", with: "")
        var matched = false

        // Mutes (order matters: 取消静音/环境音静音 before bare 静音)
        if text.contains("取消静音") || text.contains("解除静音") {
            state.musicMuted = false; state.ambientMuted = false; matched = true
        } else if text.contains("环境音静音") {
            state.ambientMuted = true; matched = true
        } else if text.contains("静音") {
            state.musicMuted = true; state.ambientMuted = true; matched = true
        }

        // Pause/resume
        if text.contains("暂停") { state.paused = true; matched = true }
        if text.contains("恢复") || text.contains("继续") { state.paused = false; matched = true }

        // Scene
        if text.contains("场景a") || text.contains("scenea") { state.scene = .a; matched = true }
        if text.contains("场景b") || text.contains("sceneb") { state.scene = .b; matched = true }
        if text.contains("场景c") || text.contains("scenec") { state.scene = .c; matched = true }

        // Outfit
        if text.contains("r1") { state.outfit = .r1; matched = true }
        if text.contains("r2") { state.outfit = .r2; matched = true }
        if text.contains("r3") { state.outfit = .r3; matched = true }

        // Time of day
        if text.contains("自动") { state.timeMode = .auto; matched = true }
        if text.contains("中午") || text.contains("白天") { state.timeMode = .fixed(.noon); matched = true }
        if text.contains("傍晚") || text.contains("黄昏") { state.timeMode = .fixed(.evening); matched = true }
        if text.contains("夜晚") || text.contains("晚上") || text.contains("夜里") {
            state.timeMode = .fixed(.night); matched = true
        }

        // Host mode
        if text.contains("预览") || text.contains("浮窗") { state.desktopMode = false; matched = true }
        else if text.contains("桌面模式") { state.desktopMode = true; matched = true }

        // Volumes ("音乐 20%" → 0.2)
        if let v = percentAfter(keyword: "音乐", in: text) {
            state.musicVolume = v; state.musicMuted = false; matched = true
        }
        if let v = percentAfter(keyword: "环境", in: text) {
            state.ambientVolume = v; state.ambientMuted = false; matched = true
        }
        if let v = percentAfter(keyword: "总音量", in: text) ?? percentAfter(keyword: "音量", in: text) {
            state.masterVolume = v; matched = true
        }

        // Profiles
        if text.contains("静音模式") { state.profile = .silent; matched = true }
        if text.contains("工作模式") || text.contains("工作") { state.profile = .coding; matched = true }
        if text.contains("电影") { state.profile = .movie; matched = true }
        if text.contains("安静") { state.profile = .quiet; matched = true }
        if text.contains("正常") || text.contains("普通") { state.profile = .normal; matched = true }

        return matched ? nil
            : "未识别的命令（示例：夜晚 R2 / 音乐 20% / 环境音静音 / 暂停 / 恢复 / 工作模式）"
    }

    /// First "NN%" (or bare number) after `keyword`, scaled to 0...1.
    static func percentAfter(keyword: String, in text: String) -> Double? {
        guard let range = text.range(of: keyword) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), (0...100).contains(value) else { return nil }
        return value / 100
    }
}
