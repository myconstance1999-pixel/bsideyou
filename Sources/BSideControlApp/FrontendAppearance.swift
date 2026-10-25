import AppKit
import SwiftUI

/// Shared colors and type identity for the accepted Control Center/library layout. No appearance
/// preference is persisted: the real app follows the system's light/dark appearance.
enum FrontendAppearance {
    static let surface = Color(nsColor: NSColor(name: "BSideFrontendSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.15, green: 0.165, blue: 0.155, alpha: 1)
            : NSColor(srgbRed: 0.973, green: 0.970, blue: 0.953, alpha: 1)
    })
    static let accent = Color(red: 0.29, green: 0.40, blue: 0.34)

    /// Restrained serif identity shared by the Control Center name and the library headings:
    /// one page title, one quieter selected-track heading.
    static let titleFont = Font.system(size: 22, weight: .medium, design: .serif)
    static let trackTitleFont = Font.system(size: 18, weight: .medium, design: .serif)

    static func actionTint(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.64, green: 0.76, blue: 0.68) : accent
    }

    static func actionForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.16, blue: 0.12) : .white
    }
}

/// Warm materials scoped to the music workspace; the notch keeps its existing palette.
enum MusicWorkspaceAppearance {
    static let background = adaptive("MusicBackground", light: (0.966, 0.956, 0.931), dark: (0.142, 0.142, 0.129))
    static let surface = adaptive("MusicSurface", light: (0.989, 0.981, 0.959), dark: (0.173, 0.173, 0.157))
    static let inset = adaptive("MusicInset", light: (0.932, 0.919, 0.884), dark: (0.211, 0.211, 0.186))
    static let accent = adaptive("MusicAccent", light: (0.38, 0.43, 0.32), dark: (0.82, 0.71, 0.50))
    static let line = adaptive("MusicLine", light: (0.85, 0.84, 0.80), dark: (0.26, 0.26, 0.23))
    static let selected = adaptive("MusicSelected", light: (0.88, 0.90, 0.83), dark: (0.24, 0.24, 0.20))

    static func actionForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.13) : .white
    }

    private static func adaptive(_ name: String, light: (Double, Double, Double),
                                 dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: name) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}
