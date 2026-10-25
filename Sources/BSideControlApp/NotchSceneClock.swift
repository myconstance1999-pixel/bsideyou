// Island-only local time, independent of the wallpaper's Beijing schedule and media state.
import Foundation
import SwiftUI
import AppKit

struct NotchSceneSchedule: Equatable {
    var morning = 6
    var afternoon = 12
    var evening = 18

    var isValid: Bool {
        0 <= morning && morning < afternoon && afternoon < evening && evening < 24
    }

    func choice(at date: Date, calendar: Calendar) -> NotchSceneChoice {
        let hour = calendar.component(.hour, from: date)
        if hour >= morning && hour < afternoon { return .cloudyDesk }
        if hour >= afternoon && hour < evening { return .goldenDesk }
        return .lamplitSofa
    }

    func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
        [morning, afternoon, evening].compactMap { hour in
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0),
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }.min()
    }
}

/// Restrained environmental tint; this does not relight illustration pixels or infer normals.
struct NotchAmbientLight: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var strength: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static func at(_ date: Date, calendar: Calendar) -> Self {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        let stops: [(Double, Self)] = [
            (0, .init(red: 0.40, green: 0.49, blue: 0.78, strength: 0.12)),
            (6, .init(red: 0.75, green: 0.83, blue: 0.71, strength: 0.13)),
            (12, .init(red: 0.88, green: 0.86, blue: 0.64, strength: 0.15)),
            (18, .init(red: 0.95, green: 0.61, blue: 0.33, strength: 0.18)),
            (24, .init(red: 0.40, green: 0.49, blue: 0.78, strength: 0.12))
        ]
        let i = (0..<(stops.count - 1)).first { hour < stops[$0 + 1].0 } ?? 3
        let (start, a) = stops[i]; let (end, b) = stops[i + 1]
        let t = min(1, max(0, (hour - start) / (end - start)))
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return .init(red: mix(a.red, b.red), green: mix(a.green, b.green),
                     blue: mix(a.blue, b.blue), strength: mix(a.strength, b.strength))
    }
}

/// One cancellable deadline while visible: a scene boundary or the next 60-second light target.
/// Native interpolation supplies frames; hidden/reduced/power-saving surfaces have no light ticks.
final class NotchSceneChoiceModel: ObservableObject {
    @Published private(set) var choice: NotchSceneChoice
    @Published private(set) var light: NotchAmbientLight
    @Published private(set) var schedule = NotchSceneSchedule()
    @Published private(set) var previewHour: Int?
    @Published private(set) var animationEpoch = 0
    @Published private(set) var motionAllowed = false
    private(set) var isVisible = false
    private(set) var artworkAvailable = false
    private(set) var scheduledDate: Date?
    private(set) var refreshCount = 0
    private(set) var isShutDown = false
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let reduceMotion: () -> Bool
    private let lowPower: () -> Bool
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         lowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         observeClock: Bool = true) {
        self.now = now; self.calendar = calendar
        self.reduceMotion = reduceMotion; self.lowPower = lowPower
        let date = now(); let cal = calendar()
        choice = NotchSceneSchedule().choice(at: date, calendar: cal)
        light = NotchAmbientLight.at(date, calendar: cal)
        if observeClock {
            for name in [Notification.Name.NSSystemClockDidChange,
                         .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                         .NSProcessInfoPowerStateDidChange] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak self] _ in
                        self?.refreshEnvironment(animateScene: true)
                    })
            }
        }
    }

    deinit {
        pending?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setVisible(_ visible: Bool) {
        guard !isShutDown, visible != isVisible else { return }
        isVisible = visible
        refreshEnvironment()
    }

    /// Availability includes the sharp reveal and successful source/kernel preparation.
    /// Scene boundaries remain scheduled when artwork is unavailable; frame work does not.
    func setArtworkAvailable(_ available: Bool) {
        guard !isShutDown, available != artworkAvailable else { return }
        artworkAvailable = available
        refreshEnvironment()
    }

    /// Menu-only inspection time; nil returns to the actual Mac local clock. Never changes OS time.
    func preview(hour: Int?) {
        guard !isShutDown, hour == nil || (0..<24).contains(hour!) else { return }
        previewHour = hour
        refreshEnvironment(animateScene: true)
    }

    @discardableResult
    func setSchedule(_ value: NotchSceneSchedule) -> Bool {
        guard !isShutDown, value.isValid else { return false }
        schedule = value
        refreshEnvironment(animateScene: true)
        return true
    }

    func refreshEnvironment(animateScene: Bool = false) {
        guard !isShutDown else { return }
        cancelDeadline()
        let cal = calendar(); let actual = now()
        let date = previewHour.flatMap {
            cal.date(bySettingHour: $0, minute: 0, second: 0, of: actual)
        } ?? actual
        let allow = NotchArtworkSceneLight.eligible(visible: isVisible, sharpRevealed: artworkAvailable,
            available: artworkAvailable, reduceMotion: reduceMotion(), lowPower: lowPower())
        // Recreate only the decorative layer to cancel any in-flight interpolation immediately.
        var snap = Transaction(animation: nil); snap.disablesAnimations = true
        withTransaction(snap) {
            if !allow || motionAllowed != allow || !animateScene { animationEpoch &+= 1 }
            motionAllowed = allow
            light = .at(date, calendar: cal)
        }
        let nextChoice = schedule.choice(at: date, calendar: cal)
        withAnimation(allow && animateScene ? .easeInOut(duration: 0.35) : nil) {
            choice = nextChoice
        }
        refreshCount &+= 1
        guard isVisible else { return }

        let boundary = previewHour == nil ? schedule.nextBoundary(after: actual, calendar: cal) : nil
        // A menu preview freezes clock deadlines and scene choice, not eligible decorative
        // image motion. Its TimelineView exists only while the original artwork is visible.
        guard allow && previewHour == nil else {
            if let boundary { enqueue(at: boundary, from: actual) }
            return
        }
        let target = min(boundary ?? actual.addingTimeInterval(60), actual.addingTimeInterval(60))
        let interval = max(0.01, target.timeIntervalSince(actual))
        let token = generation
        // Let the newly visible layer first receive the current value, then interpolate to the
        // next minute. This queued callback is invalidated on close, sleep or preference changes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.isVisible, self.motionAllowed else { return }
            withAnimation(.linear(duration: interval)) { self.light = .at(target, calendar: cal) }
        }
        enqueue(at: target, from: actual)
    }

    private func enqueue(at date: Date, from actual: Date) {
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isShutDown, self.isVisible, self.generation == token else { return }
            self.refreshEnvironment(animateScene: true)
        }
        pending = item; scheduledDate = date
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, date.timeIntervalSince(actual)), execute: item)
    }

    private func cancelDeadline() {
        generation &+= 1
        pending?.cancel(); pending = nil; scheduledDate = nil
    }

    func shutdown() {
        guard !isShutDown else { return }
        setVisible(false)
        isShutDown = true
        cancelDeadline()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// Observe the clock directly so scene updates do not rebuild the controls or their hit targets.
struct NotchTimedSceneSurface: View {
    @ObservedObject var model: NotchSceneChoiceModel
    let layout: NotchShelfLayout
    let sharpRevealed: Bool

    var body: some View {
        let image = NotchSceneImageStore.shared.image(for: model.choice)
        let available = sharpRevealed && layout.showsCharacterImage
            && NotchArtworkSceneLight.shared.prepare(model.choice, image: image)
        ZStack {
            NotchSceneSurface(layout: layout, choice: model.choice,
                              image: image, sharpRevealed: sharpRevealed,
                              lightingActive: model.motionAllowed && available,
                              onLightUnavailable: { model.setArtworkAvailable(false) })
                .id(model.choice)
                .transition(.opacity)
            HStack(spacing: 0) {
                if layout.showsCharacterImage {
                    Color.clear.frame(width: layout.characterRegionWidth)
                }
                LinearGradient(colors: [.clear, model.light.color.opacity(model.light.strength), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .id(model.animationEpoch)
        .onAppear { model.setArtworkAvailable(available) }
        .onChange(of: available) { model.setArtworkAvailable($0) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
