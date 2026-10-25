import SwiftUI

/// Persistence feedback is independent of resource/playback health and is never reset by a
/// runtime snapshot. A new edit does not hide an unresolved failure; only a successful save does.
enum PreferencesSaveStatus: String {
    case unchanged, pending, saved, failed

    var message: String {
        switch self {
        case .unchanged: return "设置自动保存。"
        case .pending: return "正在保存设置…"
        case .saved: return "设置已保存。"
        case .failed: return "本次修改尚未保存，关闭应用后可能丢失。"
        }
    }
}

struct PreferencesSaveFeedback: View {
    @ObservedObject var model: ControlCenterModel
    var alwaysShow = false

    var body: some View {
        if alwaysShow || model.preferencesSaveStatus == .failed {
            HStack(alignment: .top, spacing: 8) {
                if model.preferencesSaveStatus == .failed {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.preferencesSaveStatus.message)
                        .font(.caption)
                        .foregroundStyle(model.preferencesSaveStatus == .failed ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("preferences-save-status")
                    if model.preferencesSaveStatus == .failed {
                        Button("重试保存") { model.onRequest(.retrySave) }
                            .controlSize(.small)
                            .accessibilityIdentifier("retry-preferences-save")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(model.preferencesSaveStatus == .failed ? 10 : 0)
            .background(model.preferencesSaveStatus == .failed ? Color.orange.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
