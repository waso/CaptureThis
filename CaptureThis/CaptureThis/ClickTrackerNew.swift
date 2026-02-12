import Cocoa
import CoreGraphics

struct ClickEventNew {
    let captureTimestamp: Date  // Exact timestamp when video frame was captured (NOT when click happened)
    let x: CGFloat
    let y: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
}

class ClickTrackerNew {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickEvents: [ClickEventNew] = []
    private var isTracking = false
    private var pendingClickLocation: CGPoint?
    private var onClickCallback: ((ClickEventNew) -> Void)?
    private var windowID: CGWindowID?
    private var windowBounds: CGRect?

    func startTracking(windowID: CGWindowID? = nil, onClick: @escaping (ClickEventNew) -> Void) {
        guard !isTracking else { return }

        onClickCallback = onClick
        isTracking = true
        clickEvents.removeAll()
        pendingClickLocation = nil
        self.windowID = windowID

        // Get window bounds if recording a specific window
        if let windowID = windowID {
            windowBounds = getWindowBounds(windowID: windowID)
            print("ClickTrackerNew: Started for window ID \(windowID), bounds: \(windowBounds?.debugDescription ?? "unknown")")
        } else {
            windowBounds = nil
        }

        // Create event tap to monitor mouse clicks globally
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }

                let tracker = Unmanaged<ClickTrackerNew>.fromOpaque(refcon).takeUnretainedValue()
                tracker.handleClickEvent(event: event)

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ClickTrackerNew: Failed to create event tap. Make sure the app has Accessibility permissions.")
            return
        }

        self.eventTap = eventTap

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("ClickTrackerNew: Started (frame-synchronized mode)")
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
        // CGEvent.location also uses top-left origin (different from NSEvent!)
        // So we can use these coordinates directly
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func stopTracking() {
        guard isTracking else { return }

        isTracking = false

        // Disable and cleanup event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        pendingClickLocation = nil

        print("ClickTrackerNew: Stopped. Total clicks: \(clickEvents.count)")
    }

    private func handleClickEvent(event: CGEvent) {
        // Store the click location but DON'T save it yet
        // We'll save it when the next frame is captured
        pendingClickLocation = event.location
        print("ClickTrackerNew: Click detected at: \(event.location)")
    }

    // Called by ScreenRecorder when each frame is captured
    // This ensures clicks are synchronized with video frames
    func sampleClickAtFrameCapture(timestamp: Date) {
        guard isTracking else { return }

        // Only save click event if there's a pending click
        guard let clickLocation = pendingClickLocation else { return }

        var finalX: CGFloat
        var finalY: CGFloat
        var refWidth: CGFloat
        var refHeight: CGFloat

        if let bounds = windowBounds {
            // Recording a specific window - convert to window-relative coordinates
            // clickLocation is from CGEvent.location (top-left origin)
            // bounds is also in top-left origin

            // Check if click is outside the window bounds - if so, ignore it
            if clickLocation.x < bounds.origin.x ||
               clickLocation.x > bounds.origin.x + bounds.width ||
               clickLocation.y < bounds.origin.y ||
               clickLocation.y > bounds.origin.y + bounds.height {
                // Click is outside window bounds - don't record it
                print("ClickTrackerNew: Click at (\(clickLocation.x), \(clickLocation.y)) is outside window bounds \(bounds), ignoring")
                pendingClickLocation = nil
                return
            }

            // Convert to window-relative coordinates (0,0 = top-left of window)
            finalX = clickLocation.x - bounds.origin.x
            finalY = clickLocation.y - bounds.origin.y

            // Use window dimensions as reference
            refWidth = bounds.width
            refHeight = bounds.height
        } else {
            // Recording full screen
            guard let screen = NSScreen.main else { return }
            let screenRect = screen.frame

            // Ignore clicks in the menu bar area (where stop recording button is)
            // Menu bar is at the top of the screen (y=0 to ~y=25-30 in top-left coordinates)
            let menuBarHeight: CGFloat = 30
            if clickLocation.y < menuBarHeight {
                print("ClickTrackerNew: Click at (\(clickLocation.x), \(clickLocation.y)) is in menu bar area, ignoring")
                pendingClickLocation = nil
                return
            }

            // Convert from CoreGraphics coordinates (top-left origin) to video coordinates (top-left origin)
            // For full screen, CGEvent Y already matches video Y (both top-left origin)
            finalX = clickLocation.x
            finalY = clickLocation.y
            refWidth = screenRect.width
            refHeight = screenRect.height
        }

        // Create click event with exact frame capture timestamp
        let clickEvent = ClickEventNew(
            captureTimestamp: timestamp,
            x: finalX,
            y: finalY,
            screenWidth: refWidth,
            screenHeight: refHeight
        )

        clickEvents.append(clickEvent)

        // Clear pending click
        pendingClickLocation = nil

        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onClickCallback?(clickEvent)
        }

        print("ClickTrackerNew[\(clickEvents.count)]: at (\(finalX), \(finalY)) in (\(refWidth)x\(refHeight)) @ \(timestamp)")
    }

    func getEvents() -> [ClickEventNew] {
        return clickEvents
    }

    deinit {
        stopTracking()
    }
}
