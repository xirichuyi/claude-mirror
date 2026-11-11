import SwiftUI

// Geometry adapted from Winc v0.1.502, icons.rs and icons/files.rs (Apache-2.0).
// Paths use an 18 pt canvas; stroke stays 1.25 pt regardless of the surrounding font.
struct WorkbenchIcon: View {
    let symbol: String

    var body: some View {
        Group {
            if let glyph = WorkbenchGlyph(symbol) {
                glyph.path.stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: symbol).font(.system(size: 13, weight: .regular))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private enum WorkbenchGlyph {
    case files, search, folder, openFolder, addFolder, document, addFile
    case refresh, sidebar, rightSidebar, split, plus, close, down, right, up, more
    case git, chat, compose, terminal, collapse, locate, send, archive, bell, account, monitor, gear

    init?(_ symbol: String) {
        switch symbol {
        case "doc.on.doc": self = .files
        case "magnifyingglass": self = .search
        case "folder": self = .folder
        case "folder.open": self = .openFolder
        case "folder.badge.plus": self = .addFolder
        case "doc", "doc.text", "doc.plaintext": self = .document
        case "doc.badge.plus": self = .addFile
        case "arrow.clockwise": self = .refresh
        case "sidebar.left": self = .sidebar
        case "sidebar.right": self = .rightSidebar
        case "rectangle.split.2x1": self = .split
        case "plus": self = .plus
        case "xmark": self = .close
        case "chevron.down": self = .down
        case "chevron.right": self = .right
        case "chevron.up": self = .up
        case "ellipsis": self = .more
        case "arrow.triangle.branch": self = .git
        case "bubble.left", "bubble.left.and.bubble.right": self = .chat
        case "square.and.pencil": self = .compose
        case "terminal": self = .terminal
        case "rectangle.compress.vertical": self = .collapse
        case "scope": self = .locate
        case "arrow.up": self = .send
        case "archivebox": self = .archive
        case "bell": self = .bell
        case "person.crop.circle": self = .account
        case "desktopcomputer": self = .monitor
        case "gearshape": self = .gear
        default: return nil
        }
    }

    var path: Path {
        var p = Path()
        switch self {
        case .files:
            p.addRoundedRect(
                in: CGRect(x: 6.75, y: 5.75, width: 8.5, height: 10), cornerSize: CGSize(width: 2, height: 2))
            p.line(9.5, 9.5, 12.5, 9.5)
            p.line(9.5, 12.25, 11.25, 12.25)
            p.move(to: CGPoint(x: 2.75, y: 12.25))
            p.addLine(to: CGPoint(x: 2.75, y: 4.25))
            p.addQuadCurve(to: CGPoint(x: 4.75, y: 2.25), control: CGPoint(x: 2.75, y: 2.25))
            p.addLine(to: CGPoint(x: 11.75, y: 2.25))
        case .search:
            p.circle(8, 8, 4.75)
            p.line(11.86, 11.86, 14.75, 14.75)
        case .folder, .openFolder, .addFolder:
            p = folderPath(open: self == .openFolder, small: self == .addFolder)
            if self == .addFolder { p.plus(9, 10, 2.25) }
        case .document, .addFile:
            p.move(to: CGPoint(x: 5.5, y: 3))
            p.addLine(to: CGPoint(x: 10.5, y: 3))
            p.addLine(to: CGPoint(x: 14, y: 6.5))
            p.addLine(to: CGPoint(x: 14, y: 13.5))
            p.addQuadCurve(to: CGPoint(x: 12.5, y: 15), control: CGPoint(x: 14, y: 15))
            p.addLine(to: CGPoint(x: 5.5, y: 15))
            p.addQuadCurve(to: CGPoint(x: 4, y: 13.5), control: CGPoint(x: 4, y: 15))
            p.addLine(to: CGPoint(x: 4, y: 4.5))
            p.addQuadCurve(to: CGPoint(x: 5.5, y: 3), control: CGPoint(x: 4, y: 3))
            if self == .addFile {
                p.plus(9, 10, 2.25)
            } else {
                p.line(10.5, 3, 10.5, 6.5)
                p.line(10.5, 6.5, 14, 6.5)
            }
        case .refresh:
            p.addArc(
                center: CGPoint(x: 9, y: 9), radius: 5.5, startAngle: .degrees(0), endAngle: .degrees(315),
                clockwise: false)
            p.addLine(to: CGPoint(x: 14.5, y: 6.525))
            p.line(14.5, 6.525, 14.5, 3.525)
            p.line(14.5, 6.525, 11.5, 6.525)
        case .sidebar, .rightSidebar, .split:
            p.addRoundedRect(
                in: CGRect(x: 1.75, y: 3, width: 14.5, height: 12), cornerSize: CGSize(width: 3, height: 3))
            let x: CGFloat = self == .sidebar ? 6.75 : self == .rightSidebar ? 11.25 : 9
            p.line(x, 3, x, 15)
        case .plus: p.plus(9, 9, 5)
        case .close:
            p.line(5, 5, 13, 13)
            p.line(13, 5, 5, 13)
        case .down: p.polyline([(5, 7), (9, 11), (13, 7)])
        case .up: p.polyline([(5, 11), (9, 7), (13, 11)])
        case .right: p.polyline([(7, 5), (11, 9), (7, 13)])
        case .more:
            for x: CGFloat in [4.5, 9, 13.5] { p.circle(x, 9, 0.5) }
        case .git:
            p.circle(5, 4, 2)
            p.circle(5, 14, 2)
            p.circle(13, 4, 2)
            p.line(5, 6, 5, 12)
            p.move(to: CGPoint(x: 13, y: 6))
            p.addCurve(to: CGPoint(x: 7, y: 14), control1: CGPoint(x: 13, y: 11), control2: CGPoint(x: 11, y: 14))
        case .chat:
            p.move(to: CGPoint(x: 5, y: 3))
            p.addLine(to: CGPoint(x: 13, y: 3))
            p.addQuadCurve(to: CGPoint(x: 15, y: 5), control: CGPoint(x: 15, y: 3))
            p.addLine(to: CGPoint(x: 15, y: 10))
            p.addQuadCurve(to: CGPoint(x: 13, y: 12), control: CGPoint(x: 15, y: 12))
            p.polyline([(13, 12), (8, 12), (4, 15), (4, 12)])
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 10), control: CGPoint(x: 2.5, y: 12))
            p.addLine(to: CGPoint(x: 2.5, y: 5))
            p.addQuadCurve(to: CGPoint(x: 5, y: 3), control: CGPoint(x: 2.5, y: 3))
        case .compose:
            p.polyline([(9, 4), (4, 4), (3, 5), (3, 14), (4, 15), (13, 15), (14, 14), (14, 9)])
            p.polyline([(7, 11), (8, 8), (13, 3), (15, 5), (10, 10), (7, 11)])
        case .terminal:
            p.addRoundedRect(in: CGRect(x: 2, y: 3.5, width: 14, height: 11), cornerSize: CGSize(width: 2, height: 2))
            p.polyline([(5, 7), (7, 9), (5, 11)])
            p.line(9, 11, 12, 11)
        case .collapse:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 6, width: 11, height: 9), cornerSize: CGSize(width: 2, height: 2))
            p.line(5.5, 3, 12.5, 3)
            p.line(6.5, 10.5, 11.5, 10.5)
        case .locate:
            p.circle(9, 9, 5.5)
            p.line(9, 3.5, 9, 6.5)
            p.line(9, 11.5, 9, 14.5)
            p.line(3.5, 9, 6.5, 9)
            p.line(11.5, 9, 14.5, 9)
        case .send:
            p.line(9, 3, 9, 15)
            p.polyline([(4.5, 7.5), (9, 3), (13.5, 7.5)])
        case .archive:
            p.addRoundedRect(in: CGRect(x: 2, y: 3, width: 14, height: 3), cornerSize: CGSize(width: 1, height: 1))
            p.polyline([(3.5, 6), (3.5, 14), (14.5, 14), (14.5, 6)])
            p.line(7, 9, 11, 9)
        case .bell:
            p.move(to: CGPoint(x: 3, y: 12))
            p.addQuadCurve(to: CGPoint(x: 5, y: 6), control: CGPoint(x: 5, y: 10))
            p.addCurve(to: CGPoint(x: 13, y: 6), control1: CGPoint(x: 5, y: 1.5), control2: CGPoint(x: 13, y: 1.5))
            p.addQuadCurve(to: CGPoint(x: 15, y: 12), control: CGPoint(x: 13, y: 10))
            p.closeSubpath()
            p.move(to: CGPoint(x: 7, y: 14))
            p.addQuadCurve(to: CGPoint(x: 11, y: 14), control: CGPoint(x: 9, y: 17))
        case .account:
            p.circle(9, 9, 7)
            p.circle(9, 7, 2.5)
            p.move(to: CGPoint(x: 4, y: 14))
            p.addCurve(to: CGPoint(x: 14, y: 14), control1: CGPoint(x: 5, y: 10), control2: CGPoint(x: 13, y: 10))
        case .gear:
            let step = CGFloat.pi / 4
            var points: [(CGFloat, CGFloat)] = []
            for tooth in 0..<8 {
                let angle = CGFloat(tooth) * step
                for (offset, radius): (CGFloat, CGFloat) in [(-0.3, 4.6), (-0.17, 6.4), (0.17, 6.4), (0.3, 4.6)] {
                    points.append((9 + cos(angle + offset * step) * radius, 9 + sin(angle + offset * step) * radius))
                }
            }
            p.polyline(points)
            p.closeSubpath()
            p.circle(9, 9, 1.9)
        case .monitor:
            p.addRoundedRect(
                in: CGRect(x: 1.5, y: 2.5, width: 15, height: 10), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.line(9, 12.5, 9, 15.5)
            p.line(5, 15.5, 13, 15.5)
        }
        return p
    }

    private func folderPath(open: Bool, small: Bool) -> Path {
        var p = Path()
        let l: CGFloat = small ? 2.5 : 2.125
        let t: CGFloat = 3.625
        let r: CGFloat = small ? 15.5 : 15.875
        let b: CGFloat = 14.375
        p.move(to: CGPoint(x: l, y: b - 2))
        p.addLine(to: CGPoint(x: l, y: t + 2))
        p.addQuadCurve(to: CGPoint(x: l + 2, y: t), control: CGPoint(x: l, y: t))
        p.addLine(to: CGPoint(x: l + 5, y: t))
        p.addLine(to: CGPoint(x: l + 6.5, y: t + 2))
        p.addLine(to: CGPoint(x: r - 2, y: t + 2))
        p.addQuadCurve(to: CGPoint(x: r, y: t + 4), control: CGPoint(x: r, y: t + 2))
        if open {
            p.addLine(to: CGPoint(x: r, y: t + 5))
            p.polyline([(l + 2.75, t + 5), (r + 0.25, t + 5), (r - 2, b), (l + 2, b)])
            p.addQuadCurve(to: CGPoint(x: l, y: b - 2), control: CGPoint(x: l, y: b))
            p.line(l + 2.75, t + 5, l + 0.4, b - 0.75)
        } else {
            p.addLine(to: CGPoint(x: r, y: b - 2))
            p.addQuadCurve(to: CGPoint(x: r - 2, y: b), control: CGPoint(x: r, y: b))
            p.addLine(to: CGPoint(x: l + 2, y: b))
            p.addQuadCurve(to: CGPoint(x: l, y: b - 2), control: CGPoint(x: l, y: b))
        }
        return p
    }
}

extension Path {
    fileprivate mutating func line(_ x: CGFloat, _ y: CGFloat, _ ex: CGFloat, _ ey: CGFloat) {
        move(to: CGPoint(x: x, y: y))
        addLine(to: CGPoint(x: ex, y: ey))
    }
    fileprivate mutating func polyline(_ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { addLine(to: CGPoint(x: point.0, y: point.1)) }
    }
    fileprivate mutating func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
    fileprivate mutating func plus(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        line(x - radius, y, x + radius, y)
        line(x, y - radius, x, y + radius)
    }
}

/// Fixed hit regions and the same feedback for every workspace toolbar action.
struct WorkbenchIconButtonStyle: ButtonStyle {
    var selected = false
    var size: CGFloat = 24
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, selected: selected, size: size)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(selected ? WorkbenchTheme.ink : WorkbenchTheme.inkMuted)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovered = $0 }
    }

    private var background: Color {
        guard enabled else { return .clear }
        if configuration.isPressed { return WorkbenchTheme.ink.opacity(0.10) }
        if selected { return WorkbenchTheme.selected }
        return hovered ? WorkbenchTheme.hover : .clear
    }
}
