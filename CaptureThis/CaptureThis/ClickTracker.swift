import Cocoa
import CoreGraphics

struct ClickEvent {
    let timestamp: Date
    let x: CGFloat
    let y: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
}

class ClickTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickEvents: [ClickEvent] = []
    private var isTracking = false
    private var onClickCallback: ((ClickEvent) -> Void)?

    func startTracking(onClick: @escaping (ClickEvent) -> Void) {
        guard !isTracking else { return }

        onClickCallback = onClick
        isTracking = true
        clickEvents.removeAll()

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

                let tracker = Unmanaged<ClickTracker>.fromOpaque(refcon).takeUnretainedValue()
                tracker.handleClickEvent(event: event)

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Make sure the app has Accessibility permissions.")
            return
        }

        self.eventTap = eventTap

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("Click tracking started")
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

        print("Click tracking stopped. Total clicks: \(clickEvents.count)")
    }

    private func handleClickEvent(event: CGEvent) {
        let location = event.location

        // Get screen dimensions
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame

        // Convert from CoreGraphics coordinates (bottom-left origin) to video coordinates (top-left origin)
        // CoreGraphics Y increases upward, but video Y increases downward
        let videoY = screenRect.height - location.y

        // Create click event
        let clickEvent = ClickEvent(
            timestamp: Date(),
            x: location.x,
            y: videoY,
            screenWidth: screenRect.width,
            screenHeight: screenRect.height
        )

        clickEvents.append(clickEvent)

        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onClickCallback?(clickEvent)
        }

        print("Click tracked at: (\(location.x), \(videoY)) [flipped from CG: (\(location.x), \(location.y))]")
    }

    func getEvents() -> [ClickEvent] {
        return clickEvents
    }

    deinit {
        stopTracking()
    }
}
