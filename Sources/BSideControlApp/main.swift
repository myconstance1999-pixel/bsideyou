// BSideControlApp entry point — long-lived accessory (menu bar) application.

import AppKit
import BSidePlatform

// Explicit, resource-free model regression. Exit before NSApplication, preferences or Agent.
if CommandLine.arguments.contains("--verify-control-state") {
    exit(runControlStateRegression())
}

// Render-only verification uses explicit paths and never starts the application or Agent.
if CommandLine.arguments.contains("--verify-notch-scene-lighting") {
    let arguments = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
    guard let resources = value(after: "--notch-lighting-resources"),
          let evidence = value(after: "--notch-lighting-evidence") else {
        fputs("Scene-light verification requires resource and evidence folders.\n", stderr)
        exit(2)
    }
    exit(Int32(runNotchArtworkSceneLightRegression(
        resourceRoot: URL(fileURLWithPath: resources, isDirectory: true),
        outputFolder: URL(fileURLWithPath: evidence, isDirectory: true)
    )))
}

// Fail fast BEFORE NSApplication/AppDelegate: a duplicate activation must not even create a
// second status item / supervisor (Slice 7 duplicate-open acceptance, prompt rule #5), and a
// candidate launched next to the ordinary app must exit after a short native instruction
// instead of starting a second Agent. Both the ordinary duplicate case and the
// candidate-versus-ordinary conflict are decided by a pure policy (StartupDecisionPolicy).
SingleInstanceGuard.exitIfDuplicate()

// NO persistence is created before this point on the proceed path: AppPaths.applicationSupport is
// resolved lazily by the first real IO (prefs load / first log record). A duplicate-activation or
// conflict exit DOES write one `control.log` record through AppLog.control (which may create the
// support directory and control.log); it never loads preferences, creates a status item or
// starts an Agent.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
