#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RemoteCCCore

struct MenuList: View {
    let count: Int
    let selection: Int
    let row: (Int) -> AnyView

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        row(index)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(index == selection ? WorkbenchTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.small))
                            .id(index)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .background(WorkbenchTheme.popup, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.popupBorder))
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
    }
}
#endif
