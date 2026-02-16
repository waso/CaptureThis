import Cocoa
import AVFoundation

class EditorWindowController: NSWindowController, NSWindowDelegate {
    private var editorViewController: EditorViewController?
    private let windowSize = NSSize(width: 1280, height: 800)

    convenience init(videoURL: URL, clickEvents: [ClickEventNew] = [], cursorPositions: [CursorPositionNew]? = nil, recordingStartTime: Date = Date(), initialZoomMode: ZoomMode = .noZoom, recordingMode: RecordingMode = .fullScreen, cursorOverlayMode: CursorOverlayMode = .normal) {

        // Clear any saved window frame for this app to prevent restoration
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame CaptureThis Editor")
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame CaptureThis")
        UserDefaults.standard.synchronize()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "CaptureThis Editor"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        window.minSize = NSSize(width: 800, height: 500)
        // No maxSize - allow free resizing
        window.isRestorable = false
        window.setFrameAutosaveName("")  // Disable frame autosave

        self.init(window: window)
        window.delegate = self

        // Create editor view controller
        editorViewController = EditorViewController(
            videoURL: videoURL,
            clickEvents: clickEvents,
            cursorPositions: cursorPositions,
            recordingStartTime: recordingStartTime,
            initialZoomMode: initialZoomMode,
            recordingMode: recordingMode,
            cursorOverlayMode: cursorOverlayMode
        )

        // Don't set preferredContentSize - let window be freely resizable

        // Use contentViewController
        window.contentViewController = editorViewController

        // Force size IMMEDIATELY after setting contentViewController
        window.setContentSize(windowSize)
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        guard let window = window else { return }

        // Set initial size and center
        window.setContentSize(windowSize)
        window.center()

        super.showWindow(sender)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    // windowWillResize removed - allow free resizing
}
