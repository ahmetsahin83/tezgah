import AppKit
import CodeEditSourceEditor
import SwiftUI

/// Xcode-like light and dark themes for the code editor.
enum EditorThemes {
    static func theme(for colorScheme: ColorScheme) -> EditorTheme {
        colorScheme == .dark ? dark : light
    }

    static let light = EditorTheme(
        text: .init(color: hex(0x1F1F24)),
        insertionPoint: hex(0x000000),
        invisibles: .init(color: hex(0xD6D6D6)),
        background: hex(0xFFFFFF),
        lineHighlight: hex(0xECF5FF),
        selection: hex(0xB4D8FD),
        keywords: .init(color: hex(0x9B2393), bold: true),
        commands: .init(color: hex(0x326D74)),
        types: .init(color: hex(0x0B4F79)),
        attributes: .init(color: hex(0x815F03)),
        variables: .init(color: hex(0x1F1F24)),
        values: .init(color: hex(0x6C36A9)),
        numbers: .init(color: hex(0x1C00CF)),
        strings: .init(color: hex(0xC41A16)),
        characters: .init(color: hex(0x1C00CF)),
        comments: .init(color: hex(0x5D6C79), italic: true)
    )

    static let dark = EditorTheme(
        text: .init(color: hex(0xDFDFE0)),
        insertionPoint: hex(0xFFFFFF),
        invisibles: .init(color: hex(0x53606E)),
        background: hex(0x1F1F24),
        lineHighlight: hex(0x23252B),
        selection: hex(0x515B70),
        keywords: .init(color: hex(0xFF7AB2), bold: true),
        commands: .init(color: hex(0x67B7A4)),
        types: .init(color: hex(0x5DD8FF)),
        attributes: .init(color: hex(0xCC9768)),
        variables: .init(color: hex(0xDFDFE0)),
        values: .init(color: hex(0xA167E6)),
        numbers: .init(color: hex(0xD9C97C)),
        strings: .init(color: hex(0xFF8170)),
        characters: .init(color: hex(0xD9C97C)),
        comments: .init(color: hex(0x7F8C98), italic: true)
    )

    /// Same capture → style mapping as the editor (CodeEditSourceEditor keeps its own copy internal).
    static func attribute(for capture: CaptureName, in theme: EditorTheme) -> EditorTheme.Attribute {
        switch capture {
        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
             .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            theme.keywords
        case .comment: theme.comments
        case .variable, .property, .function, .method, .parameter: theme.variables
        case .number, .float: theme.numbers
        case .string: theme.strings
        case .type: theme.types
        case .typeAlternate: theme.attributes
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
