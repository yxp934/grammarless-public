import AppKit
import SwiftUI

enum GrammarlessTheme {
    static let aqua = Color(red: 139.0 / 255.0, green: 223.0 / 255.0, blue: 221.0 / 255.0) // #8BDFDD
    static let gold = Color(red: 255.0 / 255.0, green: 227.0 / 255.0, blue: 148.0 / 255.0) // #FFE394
    static let aquaInk = Color(red: 8.0 / 255.0, green: 125.0 / 255.0, blue: 134.0 / 255.0)
    static let goldInk = Color(red: 150.0 / 255.0, green: 100.0 / 255.0, blue: 8.0 / 255.0)
    static let ink = Color(red: 8.0 / 255.0, green: 47.0 / 255.0, blue: 60.0 / 255.0)
    static let mutedInk = Color(red: 93.0 / 255.0, green: 109.0 / 255.0, blue: 114.0 / 255.0)
    static let panel = Color(red: 1.0, green: 0.996, blue: 0.984)
    static let panelWarm = Color(red: 1.0, green: 0.988, blue: 0.947)
    static let card = Color(red: 1.0, green: 0.999, blue: 0.993)
    static let input = Color.white.opacity(0.88)
    static let border = aquaInk.opacity(0.18)
    static let strongBorder = aquaInk.opacity(0.36)
    static let softAqua = aqua.opacity(0.28)
    static let softGold = gold.opacity(0.34)
    static let softInk = ink.opacity(0.08)
    static let error = Color(red: 185.0 / 255.0, green: 52.0 / 255.0, blue: 45.0 / 255.0)

    static let panelRadius: CGFloat = 22
    static let largeRadius: CGFloat = 18
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let smallRadius: CGFloat = 8

    static let panelShadow = Color(red: 8.0 / 255.0, green: 47.0 / 255.0, blue: 60.0 / 255.0).opacity(0.14)

    static let nsAqua = NSColor(calibratedRed: 139.0 / 255.0, green: 223.0 / 255.0, blue: 221.0 / 255.0, alpha: 1)
    static let nsGold = NSColor(calibratedRed: 255.0 / 255.0, green: 227.0 / 255.0, blue: 148.0 / 255.0, alpha: 1)
    static let nsAquaInk = NSColor(calibratedRed: 8.0 / 255.0, green: 125.0 / 255.0, blue: 134.0 / 255.0, alpha: 1)
    static let nsGoldInk = NSColor(calibratedRed: 150.0 / 255.0, green: 100.0 / 255.0, blue: 8.0 / 255.0, alpha: 1)
    static let nsInk = NSColor(calibratedRed: 8.0 / 255.0, green: 47.0 / 255.0, blue: 60.0 / 255.0, alpha: 1)
    static let nsMutedInk = NSColor(calibratedRed: 93.0 / 255.0, green: 109.0 / 255.0, blue: 114.0 / 255.0, alpha: 1)
    static let nsPanel = NSColor(calibratedRed: 1.0, green: 0.996, blue: 0.984, alpha: 1)
    static let nsCard = NSColor(calibratedRed: 1.0, green: 0.999, blue: 0.993, alpha: 1)
    static let nsError = NSColor(calibratedRed: 185.0 / 255.0, green: 52.0 / 255.0, blue: 45.0 / 255.0, alpha: 1)

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct GrammarlessProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GrammarlessTheme.font(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : GrammarlessTheme.mutedInk.opacity(0.70))
            .padding(.horizontal, 14)
            .frame(minHeight: 31)
            .background(isEnabled ? GrammarlessTheme.aquaInk.opacity(configuration.isPressed ? 0.82 : 1) : GrammarlessTheme.softInk)
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
                    .stroke(isEnabled ? GrammarlessTheme.aqua.opacity(0.72) : GrammarlessTheme.border, lineWidth: 1)
            )
            .shadow(color: isEnabled ? GrammarlessTheme.aqua.opacity(0.22) : Color.clear, radius: 8, x: 0, y: 3)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct GrammarlessSoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GrammarlessTheme.font(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? GrammarlessTheme.ink : GrammarlessTheme.mutedInk.opacity(0.65))
            .padding(.horizontal, 13)
            .frame(minHeight: 31)
            .background((configuration.isPressed ? GrammarlessTheme.softAqua : GrammarlessTheme.input).opacity(isEnabled ? 1 : 0.62))
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous)
                    .stroke(GrammarlessTheme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct GrammarlessTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GrammarlessTheme.font(size: 12.5, weight: .semibold))
            .foregroundStyle(GrammarlessTheme.mutedInk)
            .padding(.horizontal, 10)
            .frame(minHeight: 31)
            .background(configuration.isPressed ? GrammarlessTheme.softAqua : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: GrammarlessTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GrammarlessProminentButtonStyle {
    static var grammarlessProminent: GrammarlessProminentButtonStyle { GrammarlessProminentButtonStyle() }
}

extension ButtonStyle where Self == GrammarlessSoftButtonStyle {
    static var grammarlessSoft: GrammarlessSoftButtonStyle { GrammarlessSoftButtonStyle() }
}

extension ButtonStyle where Self == GrammarlessTextButtonStyle {
    static var grammarlessText: GrammarlessTextButtonStyle { GrammarlessTextButtonStyle() }
}
