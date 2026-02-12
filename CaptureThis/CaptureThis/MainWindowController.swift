import Cocoa

class MainWindowController: NSWindowController {
    override func windowDidLoad() {
        super.windowDidLoad()
        // SIMPLIFIED: Don't modify anything, let AppDelegate control size
        print("MainWindowController: windowDidLoad - Window frame: \(window?.frame.size ?? .zero)")
    }
}
