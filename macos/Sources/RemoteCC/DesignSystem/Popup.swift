#if canImport(SwiftUI)
    import SwiftUI
    import AppKit

    /// Winc-style window-local card: no NSPopover arrow, system chrome, or layout reflow.
    struct WorkbenchPopup<Content: View>: NSViewRepresentable {
        @Binding var isPresented: Bool
        @ViewBuilder var content: () -> Content

        func makeNSView(context: Context) -> NSView { NSView() }
        func makeCoordinator() -> Coordinator { Coordinator() }
        func updateNSView(_ anchor: NSView, context: Context) {
            context.coordinator.update(anchor: anchor, presented: $isPresented, content: AnyView(content()))
        }
        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

        @MainActor final class Coordinator {
            private var panel: PopupPanel?
            private var hosting: NSHostingView<AnyView>?
            private var keyMonitor: Any?
            private var outsideMonitor: Any?
            private var observers: [NSObjectProtocol] = []
            private var generation = 0
            private var dismiss: (() -> Void)?
            private weak var previousResponder: NSResponder?

            func update(anchor: NSView, presented: Binding<Bool>, content: AnyView) {
                generation += 1
                guard presented.wrappedValue else {
                    remove()
                    return
                }
                dismiss = { presented.wrappedValue = false }
                if let hosting {
                    hosting.rootView = content
                    return
                }
                let ticket = generation
                DispatchQueue.main.async { [weak self, weak anchor] in
                    guard let self, self.generation == ticket, let anchor,
                        let window = anchor.window, let contentView = window.contentView
                    else { return }
                    let root = contentView.superview ?? contentView
                    self.present(anchor: anchor, window: window, root: root, content: content)
                }
            }

            private func present(anchor: NSView, window: NSWindow, root: NSView, content: AnyView) {
                let card = NSHostingView(rootView: content)
                card.layoutSubtreeIfNeeded()
                let size = card.fittingSize
                let target = anchor.convert(anchor.bounds, to: root)
                let width = min(max(size.width, target.width, 160), root.bounds.width - 16)
                let height = min(size.height, root.bounds.height - 16)
                let below = root.isFlipped ? target.maxY + 4 : target.minY - height - 4
                let above = root.isFlipped ? target.minY - height - 4 : target.maxY + 4
                let y = below >= 8 && below + height <= root.bounds.height - 8 ? below : above
                card.frame = NSRect(
                    x: min(max(8, target.minX), root.bounds.width - width - 8),
                    y: min(max(8, y), root.bounds.height - height - 8), width: width, height: height)
                let screenRect = window.convertToScreen(root.convert(card.frame, to: nil))
                let popup = PopupPanel(
                    contentRect: screenRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                    defer: false)
                popup.isOpaque = false
                popup.backgroundColor = .clear
                popup.hasShadow = true
                popup.isReleasedWhenClosed = false
                popup.contentView = card
                popup.identifier = NSUserInterfaceItemIdentifier("workbench-popup")
                previousResponder = window.firstResponder
                window.addChildWindow(popup, ordered: .above)
                popup.orderFront(nil)
                hosting = card
                panel = popup
                monitorEvents(anchor: anchor, window: window)
            }

            private func monitorEvents(anchor: NSView, window: NSWindow) {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
                    [weak self, weak anchor, weak window] event in
                    guard let self, let anchor, let window else { return event }
                    return self.handle(event, anchor: anchor, parent: window)
                }
                outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
                    ) { [weak self, weak window] notification in
                        MainActor.assumeIsolated {
                            guard let self, let activated = notification.object as? NSWindow,
                                activated !== window, activated !== self.panel
                            else { return }
                            self.close()
                        }
                    })
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.close() }
                    })
                for name in [NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                    observers.append(
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                            [weak self] _ in
                            MainActor.assumeIsolated { self?.close() }
                        })
                }
            }

            private func handle(_ event: NSEvent, anchor: NSView, parent window: NSWindow) -> NSEvent? {
                guard let hosting else { return event }
                if event.type != .keyDown {
                    if event.window !== panel {
                        // The trigger owns its toggle. Closing here first would make its
                        // mouse-up action reopen the popup immediately.
                        if event.window === window,
                            anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                        {
                            return event
                        }
                        close()
                    }
                    return event
                }
                guard event.window === window || event.window === panel else { return event }
                let window = panel ?? window
                if event.keyCode == 53 {
                    close()
                    return nil
                }
                if event.keyCode == 125 || event.keyCode == 48 && !event.modifierFlags.contains(.shift) {
                    window.selectNextKeyView(
                        (window.firstResponder as? NSView)?.isDescendant(of: hosting) == true
                            ? window.firstResponder : hosting)
                    return nil
                }
                if event.keyCode == 126 || event.keyCode == 48 {
                    window.selectPreviousKeyView(
                        (window.firstResponder as? NSView)?.isDescendant(of: hosting) == true
                            ? window.firstResponder : hosting)
                    return nil
                }
                // Do not type into the composer behind an open popup.
                if event.modifierFlags.contains(.command) { return event }
                return (window.firstResponder as? NSView)?.isDescendant(of: hosting) == true ? event : nil
            }

            private func close() {
                let action = dismiss
                remove()
                action?()
            }
            func remove() {
                generation += 1
                if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
                outsideMonitor = nil
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers = []
                if let panel, let window = panel.parent {
                    window.removeChildWindow(panel)
                    if let previousResponder { window.makeFirstResponder(previousResponder) }
                }
                panel?.orderOut(nil)
                panel?.close()
                panel = nil
                hosting = nil
                previousResponder = nil
                dismiss = nil
            }
        }
    }

    private final class PopupPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    extension View {
        func workbenchPopup<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content)
            -> some View
        {
            background(
                WorkbenchPopup(isPresented: isPresented) {
                    content()
                        .background(WorkbenchTheme.popup, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.popupBorder))
                        .padding(1)
                })
        }
    }
#endif
