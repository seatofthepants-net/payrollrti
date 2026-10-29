import SwiftUI

/// The choice screen's palette, light / dark, from the design.
enum Brand {
    static let windowBackground = Color(light: 0xF6F4EE, dark: 0x1C1F1E)
    static let recommendedCard = Color(light: 0xEEF6F1, dark: 0x1F2C26)
    static let recommendedBorder = Color(light: 0x2E7D5B, dark: 0x2F7A5C)
    static let card = Color(light: 0xFFFFFF, dark: 0x252827)
    static let cardBorder = Color(light: 0xE1DCCF, dark: 0xFFFFFF, darkOpacity: 0.09)
    static let text = Color(light: 0x1B1F1D, dark: 0xF2F4F3)
    static let secondaryText = Color(light: 0x5A625E, dark: 0x9DA7A2)
    static let badgeText = Color(light: 0x7A4F08, dark: 0xEDBE62)
    static let badgeBackground = Color(light: 0xFBEBCB, dark: 0xEDBE62, darkOpacity: 0.14)
    static let primaryButton = Color(light: 0x2E7D5B, dark: 0x2E7D5B)
    static let tick = Color(light: 0x1F7A53, dark: 0x5CC497)
    static let iconTileRecommended = Color(light: 0x2E7D5B, dark: 0x5CC497, lightOpacity: 0.12, darkOpacity: 0.14)
    static let iconTile = Color(light: 0x1B1F1D, dark: 0xFFFFFF, lightOpacity: 0.06, darkOpacity: 0.08)
}

extension Color {
    /// A colour that follows the window's appearance.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
            })
    }
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// Whether this copy can open the user's existing payroll data, in plain words.
struct CompatibilityLine: View {
    let verdict: DatabaseCompatibility

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text).font(.system(size: 14)).foregroundStyle(verdict.allowsStart ? Brand.text : Color.red)
        }
    }

    private var text: String {
        switch verdict {
        case .noDatabase: return "No payroll data yet"
        case .current: return "Works with your existing payroll data"
        case .upgrade(let pending):
            return "Will update your payroll data when it starts (\(pending) change\(pending == 1 ? "" : "s"), "
                + "backed up first)"
        case .tooOld(let detail): return "Can't open your payroll data: \(detail)"
        case .unknown(let detail): return "Couldn't check your payroll data: \(detail)"
        }
    }

    private var symbol: String {
        switch verdict {
        case .noDatabase: return "doc"
        case .current: return "checkmark.circle"
        case .upgrade: return "arrow.up.circle"
        case .tooOld: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .noDatabase, .unknown: return Brand.secondaryText
        case .current: return Brand.tick
        case .upgrade: return Brand.badgeText
        case .tooOld: return .red
        }
    }
}

/// The filled green button from the design.
struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Brand.primaryButton, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.top, 8)
    }
}

/// The outlined button from the design: the card's colour with the card's border.
struct SecondaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.cardBorder))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.top, 8)
    }
}
