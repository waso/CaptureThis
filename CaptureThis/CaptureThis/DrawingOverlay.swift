import Cocoa
import CoreGraphics

class DrawingOverlay {
    private var overlayWindow: NSWindow?
    private var drawingView: DrawingView?
    private var isActive = false
    private var eventMonitor: Any?
    private var flagsMonitor: Any?
    private var globalFlagsMonitor: Any?  // FIX: Store global monitor so we can remove it
    private var isControlKeyPressed = false

    // Bounds of the recording area (either full screen or specific window)
    private var recordingBounds: CGRect
    private var isDrawing = false

    init(recordingBounds: CGRect) {
        self.recordingBounds = recordingBounds
    }

    deinit {
        // Ensure monitors are removed
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Just hide the window - never close it
        // Closing causes animation crashes
        overlayWindow?.orderOut(nil)
    }

    func start() {
        guard !isActive else { return }

        // Create window only if it doesn't exist, otherwise just show it
        if overlayWindow == nil {
            createOverlayWindow()
        } else {
            overlayWindow?.orderFront(nil)
        }

        startMonitoring()
        isActive = true

        print("DrawingOverlay: Started for bounds \(recordingBounds)")
    }

    func stop() {
        guard isActive else { return }

        stopMonitoring()
        isActive = false

        // NEVER close the window - just hide it
        // This prevents animation-related crashes
        overlayWindow?.orderOut(nil)

        // Clear any drawings
        drawingView?.clearDrawings()

        print("DrawingOverlay: Stopped")
    }

    private func createOverlayWindow() {
        // Create a transparent window that covers the recording area
        let window = NSWindow(
            contentRect: recordingBounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating  // Above most windows but gets captured by screen recording
        window.ignoresMouseEvents = false  // We need to track mouse events for drawing
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        // Create custom drawing view
        let view = DrawingView(frame: NSRect(origin: .zero, size: recordingBounds.size))
        window.contentView = view

        overlayWindow = window
        drawingView = view
    }

    private func startMonitoring() {
        // Monitor mouse events (drag for drawing)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self, self.isControlKeyPressed else {
                return event  // Pass through if Control not pressed
            }

            // Convert mouse location to window coordinates
            if let window = self.overlayWindow, let view = self.drawingView {
                let locationInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                let locationInView = view.convert(locationInWindow, from: nil)

                switch event.type {
                case .leftMouseDown:
                    view.startDrawing(at: locationInView)
                    self.isDrawing = true
                    return nil  // Consume event

                case .leftMouseDragged:
                    if self.isDrawing {
                        view.continueDrawing(to: locationInView)
                        return nil  // Consume event
                    }

                case .leftMouseUp:
                    self.isDrawing = false
                    return nil  // Consume event

                default:
                    break
                }
            }

            return event
        }

        // Monitor Control key state
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }

            let wasPressed = self.isControlKeyPressed
            self.isControlKeyPressed = event.modifierFlags.contains(.control)

            // Control key just pressed - show overlay and change cursor
            if !wasPressed && self.isControlKeyPressed {
                self.showOverlay()
                self.setCrosshairCursor()
            }

            // Control key just released - hide overlay and restore cursor
            if wasPressed && !self.isControlKeyPressed {
                self.hideOverlay()
                self.restoreCursor()
            }

            return event
        }

        // Also monitor global flags to catch Control key state
        // FIX: Store the monitor so we can remove it later
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }

            let wasPressed = self.isControlKeyPressed
            self.isControlKeyPressed = event.modifierFlags.contains(.control)

            if !wasPressed && self.isControlKeyPressed {
                self.showOverlay()
                self.setCrosshairCursor()
            }

            if wasPressed && !self.isControlKeyPressed {
                self.hideOverlay()
                self.restoreCursor()
            }
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }

        // FIX: Remove global monitor to prevent memory leak
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
    }

    private func showOverlay() {
        overlayWindow?.orderFront(nil)
        overlayWindow?.makeKeyAndOrderFront(nil)
        print("DrawingOverlay: Showing overlay")
    }

    private func hideOverlay() {
        // Clear all drawings
        drawingView?.clearDrawings()
        overlayWindow?.orderOut(nil)
        isDrawing = false
        print("DrawingOverlay: Hiding overlay and clearing drawings")
    }

    private func closeOverlayWindow() {
        // NEVER actually close - just hide
        // Closing causes animation crashes
        overlayWindow?.orderOut(nil)
    }

    private func setCrosshairCursor() {
        NSCursor.crosshair.set()
    }

    private func restoreCursor() {
        NSCursor.arrow.set()
    }

    // Update bounds if recording window moves/resizes
    func updateBounds(_ newBounds: CGRect) {
        recordingBounds = newBounds
        overlayWindow?.setFrame(newBounds, display: true)
        drawingView?.frame = NSRect(origin: .zero, size: newBounds.size)
    }
}

// Custom view that handles drawing
class DrawingView: NSView {
    private var currentPath: NSBezierPath?
    private var paths: [NSBezierPath] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startDrawing(at point: NSPoint) {
        currentPath = NSBezierPath()
        currentPath?.move(to: point)
        currentPath?.lineWidth = 4.0
        currentPath?.lineCapStyle = .round
        currentPath?.lineJoinStyle = .round
    }

    func continueDrawing(to point: NSPoint) {
        currentPath?.line(to: point)

        // Add current path to paths array if not already there
        if let path = currentPath, !paths.contains(where: { $0 === path }) {
            paths.append(path)
        }

        needsDisplay = true
    }

    func clearDrawings() {
        paths.removeAll()
        currentPath = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw all completed paths
        NSColor.red.setStroke()

        for path in paths {
            path.stroke()
        }
    }
}
