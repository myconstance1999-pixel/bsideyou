// BSideControlApp — First-run onboarding window (≤4 short steps, prompt rules #14/#16).
// Resource selection funnels through AppDelegate.handleSelectedResourceURL — the SAME entry
// as the menu, Settings, and the regression seam. No duplicated loading logic.

import SwiftUI
import BSideCore

struct OnboardingProbe {
    var assetPath: String?
    var stage: ResourceStage
    var catalogSummary: String?
}

final class OnboardingViewModel: ObservableObject {
    @Published var state: OnboardingState
    private let pickResource: () -> Void
    private let finish: (_ loginEnabled: Bool?, _ initialProfileID: String?) -> Void
    private let stageProbe: () -> OnboardingProbe

    init(state: OnboardingState = OnboardingState(),
         pickResource: @escaping () -> Void,
         finish: @escaping (Bool?, String?) -> Void,
         stageProbe: @escaping () -> OnboardingProbe) {
        self.state = state
        self.pickResource = pickResource
        self.finish = finish
        self.stageProbe = stageProbe
    }

    func refreshFromProbe() {
        let probe = stageProbe()
        if state.selectedPath == nil, probe.stage == .ready || probe.stage == .startingPlayback,
           let path = probe.assetPath {
            state.recordValidation(path: path, summary: probe.catalogSummary)
        }
    }

    func pick() { pickResource() }

    func chooseLogin(enabled: Bool) {
        state.loginChoice = enabled
    }

    func chooseInitialProfile(id: String) {
        state.initialProfileID = id
    }

    func next() {
        refreshFromProbe()
        state.advance()
    }

    func back() { state.goBack() }

    func complete() {
        refreshFromProbe()
        finish(state.loginChoice, state.initialProfileID)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel
    @ObservedObject var saveModel: ControlCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesSaveFeedback(model: saveModel)
            switch model.state.step {
            case .welcome: welcomeStep
            case .chooseResource: resourceStep
            case .dailyBehavior: dailyBehaviorStep
            case .finish: finishStep
            }
            Spacer()
            footer
        }
        .padding(20)
        .frame(width: 460, height: 430, alignment: .topLeading)
    }

    private var stepLabel: String {
        "第 \(OnboardingStep.allCases.firstIndex(of: model.state.step)! + 1) 步，共 4 步"
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("欢迎使用 bsideyou").font(.title3).bold()
            Text("把林离带回你的 Mac 桌面。").foregroundStyle(.secondary)
            bullet("完全本地运行：读取你自己合法持有的 BSide Offline 资源")
            bullet("不修改、不上传任何官方文件")
            bullet("原生 Apple Silicon 应用，安静待在菜单栏")
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择 BSide Offline 目录").font(.title3).bold()
            Text("请选择安装目录、具体版本或 assets 文件夹，以便一并访问画面和环境音。只读使用，不会改动任何文件。")
                .foregroundStyle(.secondary)
            Button("选择资源目录…") { model.pick() }
            if let summary = model.state.catalogSummary {
                Label("✓ 找到支持的 BSide Offline（\(summary)）", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let error = model.state.validationError {
                Text("读取失败：\(error)").foregroundStyle(.red)
            }
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dailyBehaviorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日常行为").font(.title3).bold()
            Text("登录 Mac 后自动启动 bsideyou？").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("开启") { model.chooseLogin(enabled: true) }
                    .buttonStyle(.borderedProminent)
                    .opacity(model.state.loginChoice == true ? 1 : 0.55)
                Button("暂不开启") { model.chooseLogin(enabled: false) }
                    .buttonStyle(.bordered)
                    .opacity(model.state.loginChoice == false ? 1 : 0.55)
            }
            Text("初始使用场景（之后随时可改）").foregroundStyle(.secondary).padding(.top, 6)
            // Same presentation as Settings, in the compact density that fits this small window.
            ProfileChoiceList(profiles: [Profile.normal, .quiet, .coding],
                              selectedID: model.state.initialProfileID ?? "",
                              compact: true,
                              onSelect: { model.chooseInitialProfile(id: $0.id) })
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("一切就绪").font(.title3).bold()
            Text("bsideyou 以后常驻在屏幕右上角的菜单栏。点击菜单栏图标即可控制暂停、场景与音量。")
                .foregroundStyle(.secondary)
            Text("提示：关闭设置或指南窗口不会退出 bsideyou；只有菜单中的“退出”才会停止。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            if model.state.step == .finish {
                Button("打开使用指南") { NotificationCenter.default.post(name: .bsideOpenGuide, object: nil) }
            }
            Spacer()
            if model.state.step != .welcome {
                Button("上一步") { model.back() }
            }
            switch model.state.step {
            case .welcome:
                Button("继续") { model.next() }.buttonStyle(.borderedProminent)
            case .chooseResource:
                Button("继续") { model.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.state.isResourceValidated)
            case .dailyBehavior:
                Button("完成") { model.complete() }.buttonStyle(.borderedProminent)
            case .finish:
                Button("开始使用") { model.complete() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

extension Notification.Name {
    static let bsideOpenGuide = Notification.Name("bsideOpenGuide")
}
