import Cocoa
import CoreGraphics

struct CursorPositionNew {
    let captureTimestamp: Date  // Exact timestamp when video frame was captured
    let x: CGFloat
    let y: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
}

class CursorTrackerNew {
    private var cursorPositions: [CursorPositionNew] = []
    private var isTracking = false
    private var windowID: CGWindowID?
    private var windowBounds: CGRect?

    func startTracking(windowID: CGWindowID? = nil) {
        isTracking = true
        cursorPositions.removeAll()
        self.windowID = windowID

        // Get window bounds if recording a specific window
        if let windowID = windowID {
            windowBounds = getWindowBounds(windowID: windowID)
            print("CursorTracker: Started for window ID \(windowID), bounds: \(windowBounds?.debugDescription ?? "unknown")")
        } else {
            windowBounds = nil
            print("CursorTracker: Started (frame-synchronized mode)")
        }
    }

    private func getWindowBounds(windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let windowInfo = windowList.first,
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns coordinates with origin at TOP-LEFT
        // We need to convert to bottom-left origin (matching NSEvent.mouseLocation)
        guard let mainScreen = NSScreen.main else { return nil }
        let mainScreenHeight = mainScreen.frame.height

        // Convert from CG coordinates (top-left) to NS coordinates (bottom-left)
        let nsY = mainScreenHeight - y - height

        return CGRect(x: x, y: nsY, width: width, height: height)
    }

    func stopTracking() {
        isTracking = false
        print("CursorTracker: Stopped. Total positions: \(cursorPositions.count)")
    }

    // Called by ScreenRecorder when each frame is captured
    func sampleCursorAtFrameCapture(timestamp: Date) {
        guard isTracking else { return }

        // Get current cursor position (in screen coordinates)
        let mouseLocation = NSEvent.mouseLocation

        var finalX: CGFloat
        var finalY: CGFloat
        var refWidth: CGFloat
        var refHeight: CGFloat

        if let bounds = windowBounds {
            // Recording a specific window - convert to window-relative coordinates
            // mouseLocation is in screen coordinates (bottom-left origin)
            // bounds is also in bottom-left origin

            // Convert to window-relative coordinates (0,0 = bottom-left of window)
            finalX = mouseLocation.x - bounds.origin.x
            finalY = mouseLocation.y - bounds.origin.y

            // Use window dimensions as reference
            refWidth = bounds.width
            refHeight = bounds.height

            // Clamp to window bounds to avoid negative or out-of-bounds coordinates
            finalX = max(0, min(finalX, refWidth))
            finalY = max(0, min(finalY, refHeight))
        } else {
            // Recording full screen - use screen coordinates directly
            guard let screen = NSScreen.main else { return }
            let screenRect = screen.frame

            finalX = mouseLocation.x
            finalY = mouseLocation.y
            refWidth = screenRect.width
            refHeight = screenRect.height
        }

        // Create cursor position with exact frame capture timestamp
        let position = CursorPositionNew(
            captureTimestamp: timestamp,
            x: finalX,
            y: finalY,
            screenWidth: refWidth,
            screenHeight: refHeight
        )

        cursorPositions.append(position)

        // Log first few samples
        if cursorPositions.count <= 5 {
            print("Cursor[\(cursorPositions.count)]: at (\(finalX), \(finalY)) in (\(refWidth)x\(refHeight)) @ \(timestamp)")
        }
    }

    func getPositions() -> [CursorPositionNew] {
        return cursorPositions
    }
}
