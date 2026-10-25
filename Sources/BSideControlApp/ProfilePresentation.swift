// BSideControlApp — display-only presentation for playback profiles ("使用场景").
//
// All copy is keyed by the STABLE profile id, never by the persisted display name, so a legacy
// English label ("Normal") or a future id still renders honest, current copy. This file only maps
// id -> text and draws one compact selectable row; it adds no playback/volume behavior and never
// mutates DesiredState. Both Settings and Onboarding consume it, which is what makes the two
// surfaces read identically.

import SwiftUI
import BSideCore

/// Display copy for one use-case row. `useCase` is the short "when to use" clause and `effect`
/// is the concrete sound/pause result, stated relative to the user's current settings.
struct ProfilePresentation: Equatable {
    let id: String
    let title: String
    let useCase: String
    let effect: String
    /// True only for the synthetic 手动调节 row created by a manual volume edit.
    let isCustom: Bool

    /// Controller contract form, e.g. "休息、听歌时使用。音乐和环境音保持当前音量，画面继续播放。"
    var detail: String { useCase.isEmpty ? effect : "\(useCase)\(effect)" }
}

enum ProfilePresentationCatalog {
    static let customID = Profile.custom.id

    static func presentation(for profile: Profile) -> ProfilePresentation {
        presentation(id: profile.id, storedName: profile.name)
    }

    /// Copy contract keyed by stable id. Unknown ids fall back to the stored name and say so,
    /// instead of guessing an effect for a scene this build does not know.
    static func presentation(id: String, storedName: String) -> ProfilePresentation {
        switch id {
        case "normal":
            return ProfilePresentation(
                id: id, title: "日常陪伴", useCase: "休息、听歌时使用。",
                effect: "音乐和环境音保持当前音量，画面继续播放。", isCustom: false)
        case "quiet":
            return ProfilePresentation(
                id: id, title: "轻声背景", useCase: "阅读、聊天时使用。",
                effect: "音乐和环境音降至当前设置的30%，画面继续播放。", isCustom: false)
        case "coding":
            return ProfilePresentation(
                id: id, title: "专注工作", useCase: "写作、编程时使用。",
                effect: "音乐和环境音降至当前设置的15%，画面继续播放。", isCustom: false)
        case "silent":
            return ProfilePresentation(
                id: id, title: "无声画面", useCase: "只想看动态画面时使用。",
                effect: "音乐和环境音静音，画面与歌曲进度继续。", isCustom: false)
        case "movie":
            return ProfilePresentation(
                id: id, title: "暂停陪伴", useCase: "开会、看视频时使用。",
                effect: "日常画面和歌曲一起暂停，所有声音静音；切换其他场景后按当前暂停状态恢复。",
                isCustom: false)
        case "custom":
            return ProfilePresentation(
                id: id, title: "手动调节", useCase: "",
                effect: "按你设置的音量播放，不额外降低音量。", isCustom: true)
        default:
            let trimmed = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProfilePresentation(
                id: id, title: trimmed.isEmpty ? "未命名使用场景" : trimmed, useCase: "",
                effect: "当前版本不认识这个使用场景，保留原名称显示；声音继续按已保存的设置生效。",
                isCustom: false)
        }
    }

    /// Rows to show: the built-ins (plus 手动调节 while active), plus the current profile when
    /// its id is unknown — so a future id stays visible with its stored name instead of
    /// silently disappearing from the list. Ordered loudest-neutral -> quietest -> paused.
    static func visibleOptions(selected: Profile, base: [Profile]) -> [Profile] {
        var options = base
        if !options.contains(where: { $0.id == selected.id }) { options.append(selected) }
        return displayOrder(options)
    }

    /// Presentation order only; persisted Core order/factors are untouched.
    static func displayOrder(_ profiles: [Profile]) -> [Profile] {
        let rank: [String: Int] = ["normal": 0, "quiet": 1, "coding": 2, "silent": 3, "movie": 4, "custom": 5]
        return profiles.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? 90
            let right = rank[rhs.element.id] ?? 90
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Under the preset rows: what a use-case controls and what it does not.
    static let scopeNote = "使用场景只调整声音与暂停，不改变正在播放的歌曲或背景画面；全屏、系统静音/暂停与演奏/观看状态仍会生效。"
    /// Beside the volume sliders: manual edits are what create the neutral 手动调节 case.
    static let customSwitchNote = "调整任一音量会自动切换到「手动调节」，按你设置的音量播放，不额外降低音量。"
    /// Neutral, non-alarming explanation shown while 手动调节 is selected.
    static let customSelectedNote = "当前是「手动调节」：按上面的主音量和分路音量播放，不额外降低音量。"
}

/// Compact native selectable rows shared by Settings and Onboarding ("same presentation").
/// `compact` switches to a denser single-line row so the fixed-height onboarding step stays
/// usable; the copy and the selected indicator are identical on both surfaces.
struct ProfileChoiceList: View {
    let profiles: [Profile]
    let selectedID: String
    var compact: Bool = false
    let onSelect: (Profile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ForEach(profiles, id: \.id) { profile in
                let presentation = ProfilePresentationCatalog.presentation(for: profile)
                let isSelected = presentation.id == selectedID
                Button { onSelect(profile) } label: {
                    ProfileChoiceRow(presentation: presentation, isSelected: isSelected, compact: compact)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-choice-\(presentation.id)")
                .accessibilityLabel(Text("\(presentation.title)，\(presentation.detail)"))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
            if selectedID == ProfilePresentationCatalog.customID {
                Text(ProfilePresentationCatalog.customSelectedNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("profile-custom-selected-note")
            }
        }
    }
}

/// One selectable use-case row: checkmark indicator + title + use case/effect copy.
struct ProfileChoiceRow: View {
    let presentation: ProfilePresentation
    let isSelected: Bool
    var compact: Bool = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.top, compact ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 3 : 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
