import SwiftUI
import BSideCore

private typealias StudyTitleState = State<String>

/// The readout consumes a snapshot only; a future lighting renderer can reuse it unchanged.
struct StudyTimerReadout: View {
    let state: StudyTimerPresentation
    var compact = false
    var timeSize: CGFloat? = nil
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: compact ? 2 : 8) {
            Text(state.timeText)
                .font(.system(size: timeSize ?? (compact ? 30 : 56), weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.identity)
                .accessibilityIdentifier("study-time")
                .accessibilityLabel("自习时间 \(state.timeText)")
            Text(state.status)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("study-status")
        }
    }
}

struct StudyTimerPage: View {
    @ObservedObject var model: StudyTimerController
    @StudyTitleState private var title = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("自习").font(FrontendAppearance.titleFont)
                if let error = model.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("重试", action: model.retry)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                timerCard
                StudyHistoryView(model: model)
            }
            .padding(24)
        }
        .background(FrontendAppearance.surface)
        .onAppear { title = model.ledger.title }
        .accessibilityIdentifier("study-page")
    }

    private var timerCard: some View {
        VStack(spacing: 18) {
            Picker("计时方式", selection: Binding(get: { model.ledger.mode }, set: model.selectMode)) {
                Text("正计时").tag(StudyTimerMode.countUp)
                Text("倒计时").tag(StudyTimerMode.countdown)
            }
            .pickerStyle(.segmented).tint(FrontendAppearance.accent).frame(maxWidth: 260)
            .disabled(model.ledger.active != nil || model.loadFailed)
            .accessibilityIdentifier("study-mode")
            if model.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in StudyTimerReadout(state: model.presentation) }
            } else { StudyTimerReadout(state: model.presentation) }
            HStack(spacing: 14) {
                TextField("本次自习名称（可选）", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(model.ledger.active != nil || model.loadFailed)
                    .onSubmit { model.configure(title: title) }
                    .onDisappear { if model.ledger.active == nil { model.configure(title: title) } }
                    .accessibilityIdentifier("study-title")
                if model.ledger.mode == .countdown {
                    HStack(spacing: 6) {
                        TextField("分钟", value: Binding(get: { model.ledger.countdownMinutes },
                            set: { model.configure(minutes: $0) }), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 58)
                            .accessibilityLabel("倒计时分钟")
                            .accessibilityIdentifier("study-duration")
                        Text("分钟").font(.callout).foregroundStyle(.secondary)
                        Stepper("倒计时分钟", value: Binding(get: { model.ledger.countdownMinutes },
                            set: { model.configure(minutes: $0) }), in: 1...240)
                            .labelsHidden().fixedSize()
                    }
                    .disabled(model.ledger.active != nil || model.loadFailed)
                }
            }
            HStack(spacing: 12) {
                Button {
                    if model.ledger.active == nil { model.configure(title: title) }
                    model.toggle()
                } label: {
                    Label(model.isRunning ? "暂停" : model.ledger.active != nil ? "继续" : "开始自习",
                          systemImage: model.isRunning ? "pause.fill" : "play.fill")
                        .frame(minWidth: 104)
                }
                .buttonStyle(.borderedProminent)
                .tint(FrontendAppearance.actionTint(for: colorScheme))
                .disabled(model.loadFailed)
                .accessibilityIdentifier("study-toggle")
                if model.ledger.active != nil {
                    Button("结束并记录", action: model.finish)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("study-finish")
                }
            }
            Text("锁屏或睡眠时自动暂停，回来后手动继续。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

}

/// Saved study records only. Opening history never mounts a clock or edits the ledger.
struct StudyHistoryView: View {
    @ObservedObject var model: StudyTimerController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                summary("今日已记录", records: model.ledger.records.filter { Calendar.current.isDateInToday($0.endedAt) })
                summary("近 7 天记录", records: recentRecords)
            }
            history
        }
        .accessibilityIdentifier("study-history")
    }

    private var recentRecords: [StudyRecord] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        return model.ledger.records.filter { $0.endedAt >= start && $0.endedAt <= Date() }
    }

    private func summary(_ label: String, records: [StudyRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(duration(records.reduce(0) { $0 + $1.session.elapsed })).font(.title3).monospacedDigit()
            Text("\(records.count) 次自习").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自习记录").font(.headline)
            if model.ledger.records.isEmpty {
                Text("还没有自习记录。结束计时后会保存在这里。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(model.ledger.records.reversed()) { record in
                HStack(spacing: 14) {
                    Image(systemName: record.session.mode == .countdown ? "hourglass" : "stopwatch")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.session.title.isEmpty ? "自习" : record.session.title).font(.callout.weight(.medium))
                        Text(record.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(duration(record.session.elapsed)).monospacedDigit()
                        Text(record.session.reachedTarget ? "倒计时完成" : "已记录")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let value = Int(min(Double(Int.max / 2), max(0, seconds)))
        if value < 60 { return "\(value) 秒" }
        if value < 3600 {
            return value % 60 == 0 ? "\(value / 60) 分钟" : "\(value / 60) 分 \(value % 60) 秒"
        }
        return "\(value / 3600) 小时 \(value / 60 % 60) 分钟"
    }
}
