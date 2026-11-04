#if canImport(SwiftUI)
import SwiftUI
import AppKit

struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var dragOrigin: Double?
    @State private var hovered = false

    var body: some View {
        Rectangle().fill(.clear)
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                Rectangle().fill(Color.primary.opacity(hovered || dragOrigin != nil ? 0.15 : 0))
                    .frame(width: 2)
                    .allowsHitTesting(false)
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = width }
                    // Global coordinates stay stable while the divider itself moves.
                    width = min(360, max(200, (dragOrigin ?? width) + value.translation.width))
                }
                .onEnded { _ in dragOrigin = nil })
            .onHover { inside in
                guard hovered != inside else { return }
                hovered = inside
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .onDisappear {
                if hovered { NSCursor.pop(); hovered = false }
            }
            .accessibilityElement()
            .accessibilityLabel("调整侧栏宽度")
            .accessibilityValue("\(Int(width)) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(360, width + 20)
                case .decrement: width = max(200, width - 20)
                @unknown default: break
                }
            }
    }
}
#endif
