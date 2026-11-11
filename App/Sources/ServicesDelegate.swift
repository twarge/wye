#if os(macOS)
import AppKit
import TwigShared

/// Services ▸ Clone in Twig, for a selected git address in any app. The
/// address goes through the same `twig://clone` link the share sheet and
/// Shortcuts use, so the window that handles links shows the clone sheet.
final class ServicesDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// Named by `NSMessage` in the Info.plist's `NSServices`.
    @objc func cloneRepository(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let text = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: .URL)
            ?? ""
        guard let address = RemoteAddressFinder.firstAddress(in: text) else {
            error.pointee = "The selection has no git repository address in it." as NSString
            return
        }
        NSWorkspace.shared.open(TwigLink.clone(address).url)
    }
}
#endif
