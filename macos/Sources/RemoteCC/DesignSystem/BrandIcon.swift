import AppKit
import SwiftUI

struct BrandIcon: View {
    var size: CGFloat = 24
    var body: some View {
        if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}
