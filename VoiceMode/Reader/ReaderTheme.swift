import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, dark, black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .black: "Black"
        }
    }

    var background: UIColor {
        switch self {
        case .light: UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        case .dark: UIColor(white: 0.11, alpha: 1)
        case .black: .black
        }
    }

    var text: UIColor {
        switch self {
        case .light: UIColor(white: 0.1, alpha: 1)
        case .dark: UIColor(white: 0.85, alpha: 1)
        case .black: UIColor(white: 0.74, alpha: 1) // softer than white to avoid glare on OLED
        }
    }

    var secondary: UIColor {
        switch self {
        case .light: UIColor(white: 0.45, alpha: 1)
        case .dark: UIColor(white: 0.55, alpha: 1)
        case .black: UIColor(white: 0.45, alpha: 1)
        }
    }

    var highlight: UIColor {
        switch self {
        case .light: UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 0.45)
        case .dark, .black: UIColor(red: 0.97, green: 0.6, blue: 0.11, alpha: 0.28)
        }
    }

    static let accent = Color(red: 0.97, green: 0.6, blue: 0.11)

    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// Typography shared by pagination and rendering. Both must use identical attributes
/// or pages will overflow.
struct ReaderStyle: Equatable {
    var fontSize: CGFloat

    var font: UIFont {
        let base = UIFont.systemFont(ofSize: fontSize)
        return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: fontSize) } ?? base
    }

    func attributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.35
        paragraph.paragraphSpacing = fontSize * 0.6
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
}
