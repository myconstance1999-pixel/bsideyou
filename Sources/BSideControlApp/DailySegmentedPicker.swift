import AppKit
import SwiftUI

/// AppKit enforces per-segment availability. SwiftUI's segmented Picker can still select a
/// disabled option on macOS, leaving its native selection out of sync with a guarded binding.
struct DailySegmentedPicker<Value: Hashable>: NSViewRepresentable {
    struct Option {
        let value: Value
        let title: String
        let isEnabled: Bool
    }

    let label: String
    @Binding var selection: Value
    let options: [Option]
    var accessibilityIdentifier: String = "daily-segmented-picker"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.selectedSegmentBezelColor = NSColor(FrontendAppearance.accent)
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            control.setLabel(option.title, forSegment: index)
            control.setEnabled(option.isEnabled, forSegment: index)
            control.setToolTip(option.isEnabled ? nil : "最近一次目录发现未包含此选项所需的日常素材。",
                               forSegment: index)
        }
        control.setAccessibilityLabel(label)
        control.setAccessibilityIdentifier(accessibilityIdentifier)
        synchronizeSelection(control)
    }

    private func synchronizeSelection(_ control: NSSegmentedControl) {
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
    }

    final class Coordinator: NSObject {
        var parent: DailySegmentedPicker

        init(_ parent: DailySegmentedPicker) { self.parent = parent }

        @objc func selectionChanged(_ control: NSSegmentedControl) {
            // The model can reject an obsolete request after resource availability changed.
            // Always read the binding back, including when no published state update occurs.
            defer { parent.synchronizeSelection(control) }
            let index = control.selectedSegment
            guard control.isEnabled, parent.options.indices.contains(index),
                  parent.options[index].isEnabled else { return }
            parent.selection = parent.options[index].value
        }
    }
}
