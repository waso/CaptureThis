//
//  WindowSelector.swift
//  CaptureThis
//
//  Window selection via mouse hover with visual highlight - click to confirm
//

import Cocoa
import ApplicationServices

class WindowSelector {
    private var eventMonitor: Any?
    private var clickMonitor: Any?
    private var highlightWindow: NSWindow?
    private var currentHoveredWindow: (windowID: CGWindowID, appName: String)?
    private var isActive = false
    private var trackingTimer: Timer?

    var onWindowSelected: ((CGWindowID, String) -> Void)?

    init() {}

    func start() {
        guard !isActive else { return }

        // Check for Accessibility permission
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessibilityEnabled {
            print("Accessibility permission required for window detection")
            return
        }

        // Create highlight window ONCE
        createHighlightWindow()

        // Use NSEvent monitors instead of CGEvent taps for stability
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove()
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseClick()
        }

        // Also add local monitor for events in our own windows
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            if event.type == .mouseMoved {
                self?.handleMouseMove()
            } else if event.type == .leftMouseDown {
                self?.handleMouseClick()
            }
            return event
        }

        // Start periodic tracking (more stable than event taps)
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateHighlight()
        }

        isActive = true
        print("Window selector started - hover and click to select")
    }

    func stop() {
        guard isActive else { return }

        // Stop timer
        trackingTimer?.invalidate()
        trackingTimer = nil

        // Remove monitors
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        // Close and release highlight window
        highlightWindow?.orderOut(nil)
        highlightWindow?.close()
        highlightWindow = nil

        currentHoveredWindow = nil
        isActive = false

        print("Window selector stopped")
    }

    private func createHighlightWindow() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        let highlightView = NSView(frame: .zero)
        highlightView.wantsLayer = true
        highlightView.layer?.borderColor = NSColor.systemBlue.cgColor
        highlightView.layer?.borderWidth = 4
        highlightView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        highlightView.layer?.cornerRadius = 8

        window.contentView = highlightView
        highlightWindow = window
    }

    private func handleMouseMove() {
        // Just mark that we need to update - actual update happens in timer
    }

    private func updateHighlight() {
        let mouseLocation = NSEvent.mouseLocation

        // NSEvent.mouseLocation gives us coordinates with origin at BOTTOM-LEFT of main screen
        // CGWindowListCopyWindowInfo gives window bounds with origin at TOP-LEFT
        // We need to convert mouse location to CG coordinates for hit testing

        guard let mainScreen = NSScreen.main else { return }
        let mainScreenHeight = mainScreen.frame.height

        // Convert from NS coordinates (bottom-left) to CG coordinates (top-left)
        let cgMouseLocation = CGPoint(x: mouseLocation.x, y: mainScreenHeight - mouseLocation.y)

        guard let windowInfo = getWindowUnderCursor(at: cgMouseLocation) else {
            highlightWindow?.orderOut(nil)
            currentHoveredWindow = nil
            return
        }

        // Only update if different window
        if currentHoveredWindow?.windowID != windowInfo.windowID {
            currentHoveredWindow = (windowID: windowInfo.windowID, appName: windowInfo.appName)
        }

        // Update highlight position (windowInfo.bounds is already in NS coordinates)
        if let window = highlightWindow {
            window.setFrame(windowInfo.bounds, display: false)
            window.orderFront(nil)
        }
    }

    private func handleMouseClick() {
        guard let hoveredWindow = currentHoveredWindow else { return }

        print("Window selected: \(hoveredWindow.appName) (ID: \(hoveredWindow.windowID))")

        // Stop and notify
        let windowID = hoveredWindow.windowID
        let appName = hoveredWindow.appName

        stop()

        DispatchQueue.main.async { [weak self] in
            self?.onWindowSelected?(windowID, appName)
        }
    }

    private func getWindowUnderCursor(at location: CGPoint) -> (windowID: CGWindowID, appName: String, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Get all screens to understand coordinate system
        guard let mainScreen = NSScreen.main else { return nil }
        let mainScreenHeight = mainScreen.frame.height

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            // CGWindowListCopyWindowInfo returns coordinates in Quartz/CGDisplay coordinates
            // Origin is at TOP-LEFT of main screen (not bottom-left like NSWindow!)
            // We need to convert to NSWindow coordinates for setFrame
            let cgRect = CGRect(x: x, y: y, width: width, height: height)

            // Convert from CG coordinates (top-left origin) to NS coordinates (bottom-left origin)
            let nsRect = CGRect(
                x: x,
                y: mainScreenHeight - y - height,
                width: width,
                height: height
            )

            if cgRect.contains(location) {
                guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                      let ownerName = windowInfo[kCGWindowOwnerName as String] as? String else {
                    continue
                }

                if ownerName.contains("CaptureThis") || ownerName.contains("Electron") {
                    continue
                }

                let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
                if layer != 0 {
                    continue
                }

                if width < 50 || height < 50 {
                    continue
                }

                return (windowID: windowID, appName: ownerName, bounds: nsRect)
            }
        }

        return nil
    }
}
