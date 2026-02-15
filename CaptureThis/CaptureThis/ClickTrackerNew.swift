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
    private var globalMonitor: Any?
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

        // Try CGEvent tap first (requires Accessibility permission)
        var eventTapCreated = false

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        print("ClickTrackerNew: Accessibility trusted = \(trusted)")

        if trusted {
            let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                            (1 << CGEventType.rightMouseDown.rawValue)

            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                    let tracker = Unmanaged<ClickTrackerNew>.fromOpaque(refcon).takeUnretainedValue()
                    tracker.handleClickEvent(event: event)
                    return Unmanaged.passRetained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                self.eventTap = tap
                runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                eventTapCreated = true
                print("ClickTrackerNew: CGEvent tap created successfully")
            } else {
                print("ClickTrackerNew: CGEvent tap creation failed despite being trusted")
            }
        }

        // Fallback: use NSEvent global monitor (no Accessibility permission needed)
        if !eventTapCreated {
            print("ClickTrackerNew: Using NSEvent global monitor fallback")
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                // NSEvent.mouseLocation uses bottom-left origin (AppKit coordinates)
                // Convert to top-left origin (CoreGraphics coordinates) for consistency
                guard let screen = NSScreen.main else { return }
                let screenHeight = screen.frame.height
                // For global monitor, use NSEvent.mouseLocation (screen coordinates)
                let screenLocation = NSEvent.mouseLocation
                let cgLocation = CGPoint(
                    x: screenLocation.x,
                    y: screenHeight - screenLocation.y
                )
                self?.handleClickAtLocation(cgLocation)
            }
        }

        print("ClickTrackerNew: Started (frame-synchronized mode, eventTap=\(eventTapCreated))")
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

        // Remove NSEvent monitor if used
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }

        eventTap = nil
        runLoopSource = nil
        globalMonitor = nil
        pendingClickLocation = nil

        print("ClickTrackerNew: Stopped. Total clicks: \(clickEvents.count)")
    }

    private func handleClickEvent(event: CGEvent) {
        // Store the click location but DON'T save it yet
        // We'll save it when the next frame is captured
        pendingClickLocation = event.location
        print("ClickTrackerNew: Click detected at: \(event.location)")
    }

    private func handleClickAtLocation(_ location: CGPoint) {
        // Same as handleClickEvent but takes a CGPoint directly (for NSEvent fallback)
        pendingClickLocation = location
        print("ClickTrackerNew: Click detected (NSEvent) at: \(location)")
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
            if clickLocation.x < bounds.origin.x ||
               clickLocation.x > bounds.origin.x + bounds.width ||
               clickLocation.y < bounds.origin.y ||
               clickLocation.y > bounds.origin.y + bounds.height {
                print("ClickTrackerNew: Click at (\(clickLocation.x), \(clickLocation.y)) is outside window bounds \(bounds), ignoring")
                pendingClickLocation = nil
                return
            }

            finalX = clickLocation.x - bounds.origin.x
            finalY = clickLocation.y - bounds.origin.y
            refWidth = bounds.width
            refHeight = bounds.height
        } else {
            // Recording full screen
            guard let screen = NSScreen.main else { return }
            let screenRect = screen.frame

            // Ignore clicks in the menu bar area
            let menuBarHeight: CGFloat = 30
            if clickLocation.y < menuBarHeight {
                print("ClickTrackerNew: Click at (\(clickLocation.x), \(clickLocation.y)) is in menu bar area, ignoring")
                pendingClickLocation = nil
                return
            }

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
