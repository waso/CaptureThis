import Cocoa
import CoreGraphics
import CoreVideo

struct CursorPosition {
    let frameTime: TimeInterval  // Time in seconds from start of recording
    let x: CGFloat
    let y: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
}

class CursorTracker {
    private var cursorPositions: [CursorPosition] = []
    private var isTracking = false
    private var displayLink: CVDisplayLink?
    private var startTime: CFTimeInterval = 0

    func startTracking() {
        guard !isTracking else { return }

        isTracking = true
        cursorPositions.removeAll()
        startTime = CACurrentMediaTime()  // High-precision start time

        // Use CVDisplayLink for display-synchronized cursor sampling
        // This fires callbacks synchronized with the display refresh (60Hz/120Hz)
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        if let displayLink = displayLink {
            CVDisplayLinkSetOutputCallback(displayLink, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
                guard let context = displayLinkContext else { return kCVReturnSuccess }
                let tracker = Unmanaged<CursorTracker>.fromOpaque(context).takeUnretainedValue()
                tracker.sampleCursorPosition()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())

            CVDisplayLinkStart(displayLink)
        }

        print("Cursor tracking started with CVDisplayLink (display-synchronized)")
    }

    func stopTracking() {
        guard isTracking else { return }

        isTracking = false

        // Stop and cleanup display link
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil

        print("Cursor tracking stopped. Total positions: \(cursorPositions.count)")
    }

    private func sampleCursorPosition() {
        guard isTracking else { return }

        // Get current cursor position
        let mouseLocation = NSEvent.mouseLocation

        // Get screen dimensions
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame

        // Calculate time since tracking started (using high-precision media time)
        let currentTime = CACurrentMediaTime()
        let frameTime = currentTime - startTime

        // NSEvent.mouseLocation returns coordinates with bottom-left origin (Y=0 at bottom)
        // CIImage (used in video processing) ALSO uses bottom-left origin
        // So we should NOT flip - use the coordinates directly
        let videoY = mouseLocation.y

        // Create cursor position with frame-relative time
        let position = CursorPosition(
            frameTime: frameTime,  // Time in seconds since tracking started
            x: mouseLocation.x,
            y: videoY,
            screenWidth: screenRect.width,
            screenHeight: screenRect.height
        )

        cursorPositions.append(position)
    }

    func getPositions() -> [CursorPosition] {
        return cursorPositions
    }

    deinit {
        stopTracking()
    }
}
