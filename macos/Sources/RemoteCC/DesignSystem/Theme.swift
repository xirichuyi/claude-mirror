import AppKit
import SwiftUI

/// Every colour resolves from the active `ThemePalette`, so appearance and palette changes
/// re-colour the whole app without rebuilding views. Token names are this app's roles.
enum WorkbenchTheme {
    private static func token(_ value: @escaping (ThemePalette) -> NSColor) -> Color {
        Color(nsColor: ThemeStore.dynamic(value))
    }

    /// Window background behind the floating cards.
    static let frame = token(\.frame)
    /// Conversation and editor card.
    static let canvas = token(\.card)
    /// Sidebar and inspector cards.
    static let sidebar = token(\.card)
    static let popup = token(\.popup)
    /// Inputs, code blocks and grouped rows.
    static let surface = token(\.surface)
    static let ink = token(\.text)
    static let inkMuted = token(\.textMuted)
    static let inkDim = token(\.textDim)
    static let onInk = Color.white
    static let primaryButton = token(\.accentFill)
    static let accent = token(\.accent)
    static let userBubble = token(\.tint)
    static let border = token(\.border)
    static let popupBorder = token(\.popupBorder)
    static let separator = token(\.separator)
    static let hover = token(\.hover)
    static let selected = token(\.selected)
    static let selection = token(\.selection)
    static let shadow = token(\.shadow)
    static let scrim = token(\.scrim)
    static let sidebarInk = token(\.text)
    static let sage = token(\.gitAdded)
    static let error = token(\.error)
    static let warning = token(\.warning)
    static let added = token(\.gitAdded)
    static let removed = token(\.gitRemoved)
    static let modified = token(\.gitModified)

    /// One spacing and corner scale for the whole app instead of per-view numbers.
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    static let conversationWidth: CGFloat = 680

    /// Rows 6, tabs and popups 8, cards 10, pill controls 14.
    enum Radius { static let small: CGFloat = 6, medium: CGFloat = 8, card: CGFloat = 10, large: CGFloat = 14 }
    /// Cards float on the frame: 6 pt from the window edge and from each other.
    enum Island { static let margin: CGFloat = 6, gap: CGFloat = 6 }
}
