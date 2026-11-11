import AppKit
import SwiftUI

// Adapted from Winc's theme.rs, view/dialog.rs, view/settings.rs and view/popup_menu.rs.
// Apache-2.0; attribution and the upstream license are bundled in Resources/ThirdParty.
enum WorkbenchMetrics {
    static let row: CGFloat = 24
    static let button: CGFloat = 28
    static let header: CGFloat = 40
    static let status: CGFloat = 26
    static let dialogRadius: CGFloat = 12
    static let ui = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    // Winc theme.rs: SETTINGS_HEADER / PAD / CONTROL_H and DIALOG_LABEL_GAP.
    // The label column is wider for Chinese server and permission names.
    static let formLabel: CGFloat = 72
    static let formGap: CGFloat = 12
    static let formRowGap: CGFloat = 10
    static let dialogHeader: CGFloat = 52
    static let dialogPadding: CGFloat = 24
    static let settingsNavigation: CGFloat = 180
}
