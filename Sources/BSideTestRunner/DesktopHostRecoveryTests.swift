// Exercises the production host controller with private notification centers and fake windows.
// These tests neither create NSWindows nor depend on the machine's current display configuration.

import AppKit
import BSidePlatform
import BSideCore

private final class RecoveryTestHost: DesktopHost {
    let strategyName: String
    private let canInstall: () -> Bool
    private(set) var isInstalled = false
    private(set) var visibility: Bool?
    var onVisibilityChanged: ((Bool?) -> Void)?
    private(set) var installCount = 0
    private(set) var showCount = 0
    private(set) var teardownCount = 0
    private(set) var reassertCount = 0
    private(set) var installedLayer: CALayer?

    init(desktopMode: Bool, canInstall: @escaping () -> Bool) {
        strategyName = desktopMode ? "test-desktop" : "test-preview"
        self.canInstall = canInstall
    }

    func install(layer: CALayer) {
        installCount += 1
        isInstalled = canInstall()
        installedLayer = isInstalled ? layer : nil
        visibility = nil
    }

    func show() { if isInstalled { showCount += 1 } }

    func teardown() {
        teardownCount += 1
        isInstalled = false
        installedLayer = nil
        visibility = nil
    }

    func reassert() { reassertCount += 1 }

    func deliverVisibility(_ visible: Bool?) {
        visibility = visible
        onVisibilityChanged?(visible)
    }
}

@discardableResult
private func drainHostRecovery(until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while !predicate(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func flushHostRecovery() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    _ = drainHostRecovery(until: { drained })
}

func runDesktopHostRecoveryTests() {
    run("DesktopHost.noScreenRecoversRequestedPresentationOnScreenEvent") { t in
        for desktopMode in [true, false] {
            let center = NotificationCenter()
            let layer = CALayer()
            var screenAvailable = false
            var hosts: [RecoveryTestHost] = []
            let controller = DesktopHostController(layer: layer, notificationCenter: center) { mode in
                let host = RecoveryTestHost(desktopMode: mode, canInstall: { screenAvailable })
                hosts.append(host)
                return host
            }
            controller.ensureInstalled(desktopMode: desktopMode)
            t.expect(!controller.isInstalled, "a host object without a window is not installed")
            t.expectEqual(hosts.count, 1, "one host retains the requested presentation")
            let host = hosts[0]
            screenAvailable = true
            for _ in 0..<4 {
                center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
            t.expect(drainHostRecovery(until: { controller.isInstalled }),
                     "screen notification retries even without a RuntimeContext change")
            t.expectEqual(hosts.count, 1, "recovery reuses the uninstalled host")
            t.expectEqual(host.installCount, 2, "screen burst produces one recovery attempt")
            t.expectEqual(host.showCount, 1, "only the successful installation shows")
            t.expect(host.installedLayer === layer, "recovery attaches the original engine layer")
            t.expectEqual(controller.strategyName, desktopMode ? "test-desktop" : "test-preview",
                          "no-screen startup does not lose the requested presentation")
            controller.teardown()
        }
    }

    run("DesktopHost.unknownVisibilityDoesNotReinstallAWindow") { t in
        let center = NotificationCenter()
        let host = RecoveryTestHost(desktopMode: true, canInstall: { true })
        let controller = DesktopHostController(layer: CALayer(), notificationCenter: center) { _ in host }
        controller.ensureInstalled(desktopMode: true)
        t.expect(host.visibility == nil, "an installed window may still have unknown visibility")
        for _ in 0..<4 {
            controller.ensureInstalled(desktopMode: true)
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        controller.reassert()
        flushHostRecovery()
        t.expectEqual(host.installCount, 1, "installed same-mode host preserves window and content")
        t.expectEqual(host.showCount, 1, "screen events do not repeatedly show an installed host")
        t.expectEqual(host.reassertCount, 1, "wake still reasserts the existing host")
        controller.teardown()
    }

    run("DesktopHost.modeReplacementRejectsOldVisibilityAndPendingRetry") { t in
        let center = NotificationCenter()
        var screenAvailable = false
        var hosts: [RecoveryTestHost] = []
        var changes: [Bool?] = []
        let controller = DesktopHostController(layer: CALayer(), notificationCenter: center) { mode in
            let host = RecoveryTestHost(desktopMode: mode, canInstall: { screenAvailable })
            hosts.append(host)
            return host
        }
        controller.onVisibilityChanged = { changes.append($0) }
        controller.ensureInstalled(desktopMode: true)
        let oldHost = hosts[0]
        let staleVisibility = oldHost.onVisibilityChanged
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        screenAvailable = true
        controller.ensureInstalled(desktopMode: false)
        flushHostRecovery()
        staleVisibility?(false)
        t.expectEqual(changes, [nil], "only the current installation publishes its unknown reset")
        t.expectEqual(oldHost.teardownCount, 1, "mode replacement tears down the old host")
        t.expectEqual(hosts.count, 2, "a pending screen retry cannot replace the new installed host")
        t.expectEqual(hosts[1].installCount, 1, "new mode is installed once")
        hosts[1].deliverVisibility(true)
        t.expectEqual(changes, [nil, true], "current host observations are forwarded")
        controller.teardown()
    }

    run("DesktopHost.teardownInvalidatesPendingScreenWorkAndAllowsFreshStart") { t in
        let center = NotificationCenter()
        var screenAvailable = false
        var hosts: [RecoveryTestHost] = []
        var changes: [Bool?] = []
        let controller = DesktopHostController(layer: CALayer(), notificationCenter: center) { mode in
            let host = RecoveryTestHost(desktopMode: mode, canInstall: { screenAvailable })
            hosts.append(host)
            return host
        }
        controller.onVisibilityChanged = { changes.append($0) }
        controller.ensureInstalled(desktopMode: true)
        let staleVisibility = hosts[0].onVisibilityChanged
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        controller.teardown()
        screenAvailable = true
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        staleVisibility?(false)
        flushHostRecovery()
        t.expectEqual(hosts[0].installCount, 1, "queued and later screen events cannot revive a torn-down host")
        t.expect(changes.isEmpty, "teardown invalidates queued unknown and old visibility callbacks")
        t.expect(!controller.isInstalled, "teardown removes installation state")

        screenAvailable = false
        controller.ensureInstalled(desktopMode: false)
        screenAvailable = true
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        t.expect(drainHostRecovery(until: { controller.isInstalled }), "fresh lifecycle installs on its screen event")
        t.expectEqual(hosts.count, 2, "restart creates one fresh host")
        t.expectEqual(hosts[1].installCount, 2, "restart observes with one current generation")
        controller.teardown()
    }

    run("DesktopHost.wakeRetriesAnUninstalledHost") { t in
        var screenAvailable = false
        let host = RecoveryTestHost(desktopMode: true, canInstall: { screenAvailable })
        let controller = DesktopHostController(layer: CALayer(), notificationCenter: NotificationCenter()) { _ in host }
        controller.ensureInstalled(desktopMode: true)
        screenAvailable = true
        controller.reassert()
        t.expect(controller.isInstalled, "wake can recover a host before the screen-configuration event")
        t.expectEqual(host.installCount, 2, "wake retries the failed installation")
        t.expectEqual(host.reassertCount, 0, "wake does not reassert a nonexistent window")
        controller.teardown()
    }
}
