import SwiftUI
import BSideCore

// Explicitly name the property-wrapper type: this SDK also exports a State macro whose
// SwiftUIMacros plugin is absent from the CLT toolchain.
private typealias BoolState = State<Bool>

/// Recent directory discovery, projected by the shared model. It reports only counts and, in a
/// collapsed troubleshooting detail, the raw combination identities. Choosing a background is a
/// visual action in the chooser (ADR-024); this view never discovers or loads media itself.
struct DailyContentFeedback: View {
    @ObservedObject var model: ControlCenterModel
    @BoolState private var showsFileInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.dailyResourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("daily-resource-summary")
            if let notice = model.dailyContentNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keys = model.dailyContentKeys, !keys.isEmpty {
                DisclosureGroup(isExpanded: $showsFileInfo) {
                    Text(keys.map(\.description).joined(separator: "、"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("daily-content-file-info")
                } label: {
                    Text("文件信息").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("按最近一次目录发现统计，实际播放仍需加载素材。")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-content-feedback")
    }
}
