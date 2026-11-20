import AppKit
import SwiftUI

struct WorkbenchMenu<Label: View, Content: View>: View {
    var iconOnly = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Group {
            if iconOnly {
                Button {
                    showing.toggle()
                } label: {
                    label()
                }
                .buttonStyle(WorkbenchIconButtonStyle(selected: showing))
            } else {
                Button {
                    showing.toggle()
                } label: {
                    label()
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .workbenchPopup(isPresented: $showing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2, content: content)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 360)
            .font(WorkbenchMetrics.ui)
            .buttonStyle(WorkbenchMenuActionStyle(close: { showing = false }))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(WorkbenchTheme.ink)
            .padding(5).frame(minWidth: 200)

            .onExitCommand { showing = false }
        }
    }
}

private struct WorkbenchMenuActionStyle: PrimitiveButtonStyle {
    let close: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchMenuAction(configuration: configuration, close: close)
    }
}

private struct WorkbenchMenuAction: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let close: () -> Void
    var body: some View {
        Button {
            close()
            configuration.trigger()
        } label: {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? WorkbenchTheme.error : WorkbenchTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(QuietButtonStyle(height: WorkbenchMetrics.row))
    }
}
