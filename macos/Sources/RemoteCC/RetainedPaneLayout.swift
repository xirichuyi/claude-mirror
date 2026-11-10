import SwiftUI

/// Keep pane identity and scroll state while measuring only visible panes.
/// Inactive panes retain their last proposal instead of being squeezed to zero width.
struct RetainedPaneLayout: Layout {
    var selection: Int
    var split = false
    var fraction: CGFloat = 0.5
    var gap: CGFloat = 6
    var parkInactive = true

    struct Cache { var sizes: [Int: CGSize] = [:] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 400))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let left = ((bounds.width - gap) * fraction).rounded()
        for (index, view) in subviews.enumerated() {
            let visible = split || index == selection
            let size: CGSize
            if visible {
                size = CGSize(width: split ? (index == 0 ? left : bounds.width - gap - left) : bounds.width, height: bounds.height)
                cache.sizes[index] = size
            } else {
                size = cache.sizes[index] ?? bounds.size
            }
            let x = visible ? bounds.minX + (split && index == 1 ? left + gap : 0) : (parkInactive ? bounds.maxX + 100 : bounds.minX)
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

extension View {
    func paneVisible(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible).disabled(!visible).accessibilityHidden(!visible)
    }
}

// Animate the tab indicator only. Pane geometry and scroll views switch atomically.
extension View {
    func sidebarPaneVisible(_ visible: Bool) -> some View {
        paneVisible(visible)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}
