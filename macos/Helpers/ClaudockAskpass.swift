import AppKit

// OpenSSH invokes this helper only during an explicit connection attempt.
// Credentials go straight to SSH over stdout; they are never saved to disk.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let confirmation = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm"
    || prompt.contains("yes/no")
let alert = NSAlert()
alert.messageText = confirmation ? "确认 SSH 主机指纹" : "SSH 身份验证"
alert.informativeText = prompt
alert.addButton(withTitle: confirmation ? "信任并连接" : "继续")
alert.addButton(withTitle: "取消")
let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
if !confirmation {
    input.placeholderString = "密码或私钥口令"
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
}
app.activate(ignoringOtherApps: true)
guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
let answer = confirmation ? "yes" : input.stringValue
FileHandle.standardOutput.write(Data((answer + "\n").utf8))
input.stringValue = ""
