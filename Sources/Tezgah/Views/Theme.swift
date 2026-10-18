import SwiftUI

/// Tezgah's surfaces and lines, light and dark, so every part of the window speaks one language:
/// the chrome around it, the content surface, raised cards, and thin translucent dividers.
enum Theme {
    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x202125) : Color(hex: 0xF5F5F3)
    }

    /// Editors, conversations, panels: one surface, matching the code editor's background.
    static func surface(_ scheme: ColorScheme) -> Color {
        Color(nsColor: EditorThemes.theme(for: scheme).background)
    }

    /// Cards, the composer, the selected tab.
    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2A2B31) : .white
    }

    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    static func chip(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    static func hover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 14
    }

    /// Short and soft; off when the user asks for less motion.
    static func animation(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)
    }
}

/// A thin divider in the theme's line color.
struct ThemeDivider: View {
    var vertical = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Theme.line(scheme))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
