//
//  MissionControlWindowSelector.swift
//  CaptureThis
//
//  Mission Control-style window selection with grid view
//

import Cocoa
import ApplicationServices
import ScreenCaptureKit

struct WindowThumbnail {
    let windowID: CGWindowID
    let appName: String
    let title: String
    let image: NSImage?
    let originalBounds: CGRect
    let scWindow: SCWindow? // Store SCWindow for thumbnail capture
}

// Store original window state for restoration
struct WindowState {
    let windowID: CGWindowID
    let appName: String
    let position: CGPoint
    let size: CGSize
    let pid: pid_t
}

class MissionControlWindowSelector: NSViewController {
    private var overlayWindow: NSWindow?
    private var windows: [WindowThumbnail] = []
    private var thumbnailViews: [WindowThumbnailView] = []
    private var hoveredView: WindowThumbnailView?
    private var eventMonitor: Any?  // Store event monitor to remove it later

    // Track original window states and which windows were modified
    private var originalWindowStates: [CGWindowID: WindowState] = [:]
    private var modifiedWindows: Set<CGWindowID> = []

    var onWindowSelected: ((CGWindowID, String) -> Void)?
    var onCancelled: (() -> Void)?

    deinit {
        // Safety: ensure event monitor is removed when controller is deallocated
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
            print("MissionControlWindowSelector: Event monitor removed in deinit")
        }
    }

    override func loadView() {
        view = NSView(frame: NSScreen.main?.frame ?? .zero)
        view.wantsLayer = true

        // CRITICAL: Make sure view background is CLEAR so background image can show
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false

        print("MissionControlWindowSelector: loadView called - view background is clear")

        // Add loading indicator
        let label = NSTextField(frame: CGRect(
            x: 0,
            y: (view.frame.height - 40) / 2,
            width: view.frame.width,
            height: 40
        ))
        label.stringValue = "Loading windows..."
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = .white
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 24, weight: .medium)
        label.tag = 999 // Tag to remove later
        view.addSubview(label)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add ESC key handler and store it so we can remove it later
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                self?.cancel()
                return nil
            }
            return event
        }

        // Load windows and create grid asynchronously
        Task { @MainActor in
            // CRITICAL: Remove loading label BEFORE loading windows
            // Otherwise it gets captured as a window!
            self.view.subviews.first(where: { $0.tag == 999 })?.removeFromSuperview()

            // Capture wallpaper asynchronously
            await captureAndSetWallpaper()

            await loadWindows()
            createGrid()
        }
    }

    func show() {
        guard let screen = NSScreen.main else { return }

        print("MissionControlWindowSelector: Setting up window...")

        // Create full-screen overlay window
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.contentViewController = self
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        overlayWindow = window
        window.makeKeyAndOrderFront(nil)

        print("MissionControlWindowSelector: Window shown, wallpaper will be loaded asynchronously")
    }

    // Capture and set wallpaper asynchronously
    private func captureAndSetWallpaper() async {
        guard let screen = NSScreen.main else { return }

        print("MissionControlWindowSelector: Capturing desktop wallpaper...")

        do {
            // Get all windows via ScreenCaptureKit
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            print("MissionControlWindowSelector: Searching for Desktop Picture window among \(content.windows.count) SCWindows")

            // Find the Desktop Picture window owned by Dock
            for scWindow in content.windows {
                guard let appName = scWindow.owningApplication?.applicationName else { continue }

                // Check if owned by Dock
                guard appName == "Dock" else { continue }

                let title = scWindow.title ?? ""

                // Check if it's a Desktop Picture or Wallpaper window (name changed in macOS Sonoma)
                guard title.hasPrefix("Desktop Picture") || title.hasPrefix("Wallpaper") else {
                    continue
                }

                // Match to current screen by checking window bounds
                let windowFrame = scWindow.frame
                let screenFrame = screen.frame

                // Match by checking if window origin is close to screen origin
                if abs(windowFrame.origin.x - screenFrame.origin.x) < 1 &&
                   abs(windowFrame.origin.y - screenFrame.origin.y) < 1 {

                    print("MissionControlWindowSelector: Found Desktop Picture window: '\(title)' (ID: \(scWindow.windowID))")

                    // Capture this specific window using ScreenCaptureKit
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    config.width = Int(windowFrame.width)
                    config.height = Int(windowFrame.height)
                    config.scalesToFit = false

                    do {
                        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        let nsImage = NSImage(cgImage: cgImage, size: screenFrame.size)
                        print("MissionControlWindowSelector: Successfully captured desktop wallpaper: \(nsImage.size)")

                        // Update UI on main thread
                        await MainActor.run {
                            addWallpaperBackground(nsImage, to: self.view, screenFrame: screenFrame)
                        }
                        return
                    } catch {
                        print("MissionControlWindowSelector: Failed to capture Desktop Picture window: \(error)")
                    }

                    break
                }
            }

            print("MissionControlWindowSelector: Could not find Desktop Picture window")
        } catch {
            print("MissionControlWindowSelector: Failed to get window list: \(error)")
        }

        // Fallback to dark background if wallpaper capture failed
        await MainActor.run {
            print("MissionControlWindowSelector: Using dark background fallback")
            let fallbackView = NSView(frame: self.view.bounds)
            fallbackView.wantsLayer = true
            fallbackView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            fallbackView.autoresizingMask = [.width, .height]
            self.view.addSubview(fallbackView)
            self.view.subviews.insert(self.view.subviews.removeLast(), at: 0)
        }
    }


    // Add wallpaper as background image view
    private func addWallpaperBackground(_ image: NSImage, to view: NSView, screenFrame: CGRect) {
        // Create image view for wallpaper
        let wallpaperView = NSImageView(frame: view.bounds)
        wallpaperView.image = image
        wallpaperView.imageScaling = .scaleProportionallyUpOrDown
        wallpaperView.autoresizingMask = [.width, .height]
        wallpaperView.wantsLayer = true

        view.addSubview(wallpaperView)
        // Move to back so it's behind everything
        view.subviews.insert(view.subviews.removeLast(), at: 0)

        // Add subtle dark overlay on top of wallpaper for contrast
        let overlayView = NSView(frame: view.bounds)
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        overlayView.autoresizingMask = [.width, .height]
        view.addSubview(overlayView)
        view.subviews.insert(view.subviews.removeLast(), at: 1)  // Put it right after wallpaper

        print("MissionControlWindowSelector: Wallpaper background added with dark overlay")
    }

    private func captureDesktopScreenshotAsync() async -> NSImage? {
        guard let screen = NSScreen.main else { return nil }

        do {
            // Small delay to let the window appear first
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("MissionControlWindowSelector: No display found")
                return nil
            }

            // Capture EVERYTHING on screen (desktop + windows) - this will include our overlay but it's dark so OK
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height

            let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            print("MissionControlWindowSelector: Captured full screen: \(screenshot.width)x\(screenshot.height)")
            return NSImage(cgImage: screenshot, size: screen.frame.size)
        } catch {
            print("MissionControlWindowSelector: Screenshot capture error: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            print("MissionControlWindowSelector: Found \(content.windows.count) total windows")

            for scWindow in content.windows {
                // Skip our own app and system apps
                guard let appName = scWindow.owningApplication?.applicationName else { continue }

                // Trim whitespace from app name
                let trimmedAppName = appName.trimmingCharacters(in: .whitespaces)

                // Skip if app name is empty or is a system app
                if trimmedAppName.isEmpty ||
                   trimmedAppName.contains("CaptureThis") ||
                   trimmedAppName == "Finder" ||
                   trimmedAppName == "Dock" ||
                   trimmedAppName == "SystemUIServer" {
                    print("MissionControlWindowSelector: Skipping system/empty app: '\(appName)'")
                    continue
                }

                // Skip tiny windows
                if scWindow.frame.width < 100 || scWindow.frame.height < 100 {
                    continue
                }

                let bounds = scWindow.frame
                let title = scWindow.title ?? ""

                // Skip windows with no meaningful title or system backstop windows
                if title.isEmpty || title.contains("Backstop") {
                    print("MissionControlWindowSelector: Skipping window with no/system title from: \(trimmedAppName) - '\(title)'")
                    continue
                }

                // Capture window thumbnail using ScreenCaptureKit
                guard let image = try? await self.captureWindowThumbnail(window: scWindow) else {
                    print("MissionControlWindowSelector: Failed to capture thumbnail for: \(trimmedAppName) - \(title)")
                    continue
                }

                // Store original window state for potential restoration
                let windowState = WindowState(
                    windowID: scWindow.windowID,
                    appName: trimmedAppName,
                    position: CGPoint(x: bounds.origin.x, y: bounds.origin.y),
                    size: CGSize(width: bounds.width, height: bounds.height),
                    pid: scWindow.owningApplication?.processID ?? 0
                )
                self.originalWindowStates[scWindow.windowID] = windowState

                // Log what we're adding for debugging
                print("MissionControlWindowSelector: ✓ Adding window: \(trimmedAppName) - \(title) (ID: \(scWindow.windowID)) at \(windowState.position) size \(windowState.size)")

                let thumbnail = WindowThumbnail(
                    windowID: scWindow.windowID,
                    appName: trimmedAppName,
                    title: title,
                    image: image,
                    originalBounds: bounds,
                    scWindow: scWindow
                )

                self.windows.append(thumbnail)
            }

            print("MissionControlWindowSelector: Loaded \(self.windows.count) valid windows")
        } catch {
            print("MissionControlWindowSelector: Error loading windows: \(error)")
        }
    }

    private func captureWindowThumbnail(window: SCWindow) async throws -> NSImage? {
        // Create a filter for this specific window
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Create configuration for thumbnail capture
        let config = SCStreamConfiguration()
        config.width = min(Int(window.frame.width), 800)
        config.height = min(Int(window.frame.height), 600)
        config.scalesToFit = true

        // Capture the window screenshot
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // Convert CGImage to NSImage
        let size = NSSize(width: screenshot.width, height: screenshot.height)
        return NSImage(cgImage: screenshot, size: size)
    }

    private func createGrid() {
        // Remove loading indicator
        view.subviews.first(where: { $0.tag == 999 })?.removeFromSuperview()

        guard !windows.isEmpty else {
            print("MissionControlWindowSelector: No windows to display")

            // Show error message
            let label = NSTextField(frame: CGRect(
                x: 0,
                y: (view.frame.height - 40) / 2,
                width: view.frame.width,
                height: 40
            ))
            label.stringValue = "No windows available to record. Press ESC to cancel."
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.textColor = .white
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
            view.addSubview(label)
            return
        }

        guard let screenFrame = NSScreen.main?.frame else { return }

        // Mission Control-style organic layout with variation
        let margin: CGFloat = 80
        let baseSpacing: CGFloat = 30
        let availableWidth = screenFrame.width - (margin * 2)
        let availableHeight = screenFrame.height - (margin * 2)

        // Calculate a common scale factor that fits all windows proportionally
        let totalWindowArea = windows.reduce(0) { $0 + ($1.originalBounds.width * $1.originalBounds.height) }
        let availableArea = availableWidth * availableHeight * 0.55  // Use 55% of available space for more breathing room

        // Initial scale estimate
        var scale = sqrt(availableArea / totalWindowArea)

        // Clamp scale to reasonable bounds
        scale = min(scale, 0.4)
        scale = max(scale, 0.08)

        print("MissionControlWindowSelector: Using initial scale factor: \(scale)")

        // Create scaled window sizes with slight random variation for organic feel
        struct ScaledWindow {
            let thumbnail: WindowThumbnail
            let size: CGSize
            let scaleVariation: CGFloat  // Individual scale variation
        }

        let scaledWindows = windows.enumerated().map { (index, window) in
            // Add slight scale variation (±5%) for organic look
            let scaleVariation = 1.0 + CGFloat.random(in: -0.05...0.05)

            return ScaledWindow(
                thumbnail: window,
                size: CGSize(
                    width: window.originalBounds.width * scale * scaleVariation,
                    height: window.originalBounds.height * scale * scaleVariation
                ),
                scaleVariation: scaleVariation
            )
        }

        // Arrange windows in rows with organic spacing and slight Y-offset variation
        var currentY: CGFloat = margin
        var currentX: CGFloat = margin
        var rowHeight: CGFloat = 0
        var windowsInRow: [(window: ScaledWindow, x: CGFloat, y: CGFloat, yOffset: CGFloat)] = []
        var allRows: [[(window: ScaledWindow, x: CGFloat, y: CGFloat, yOffset: CGFloat)]] = []

        for scaledWindow in scaledWindows {
            let windowWidth = scaledWindow.size.width
            let windowHeight = scaledWindow.size.height

            // Vary spacing slightly for each window (organic feel)
            let spacingVariation = baseSpacing + CGFloat.random(in: -8...12)

            // Check if window fits in current row
            if currentX + windowWidth > screenFrame.width - margin && !windowsInRow.isEmpty {
                // Start new row
                allRows.append(windowsInRow)
                windowsInRow = []
                currentY += rowHeight + baseSpacing + CGFloat.random(in: -5...10)  // Vary row spacing
                currentX = margin
                rowHeight = 0
            }

            // Add slight Y-offset variation within the row for organic look
            let yOffset = CGFloat.random(in: -10...10)

            windowsInRow.append((scaledWindow, currentX, currentY, yOffset))
            currentX += windowWidth + spacingVariation
            rowHeight = max(rowHeight, windowHeight)
        }

        // Add last row
        if !windowsInRow.isEmpty {
            allRows.append(windowsInRow)
        }

        // Check if total height overflows - if so, scale down everything
        let totalHeightNeeded = allRows.enumerated().reduce(0) { total, row in
            let (index, windows) = row
            let maxHeight = windows.map { $0.window.size.height }.max() ?? 0
            return total + maxHeight + (index > 0 ? baseSpacing : 0)
        }

        if totalHeightNeeded > availableHeight {
            // Need to scale down further
            let heightScale = availableHeight / totalHeightNeeded
            scale *= heightScale * 0.95  // 95% to add some safety margin

            print("MissionControlWindowSelector: Height overflow detected, rescaling to: \(scale)")

            // Recalculate with new scale
            let rescaledWindows = windows.enumerated().map { (index, window) in
                // Keep same scale variation for consistency
                let scaleVariation = 1.0 + CGFloat.random(in: -0.05...0.05)

                return ScaledWindow(
                    thumbnail: window,
                    size: CGSize(
                        width: window.originalBounds.width * scale * scaleVariation,
                        height: window.originalBounds.height * scale * scaleVariation
                    ),
                    scaleVariation: scaleVariation
                )
            }

            // Redo layout with rescaled windows
            allRows.removeAll()
            windowsInRow.removeAll()
            currentY = margin
            currentX = margin
            rowHeight = 0

            for scaledWindow in rescaledWindows {
                let windowWidth = scaledWindow.size.width
                let windowHeight = scaledWindow.size.height

                let spacingVariation = baseSpacing + CGFloat.random(in: -8...12)

                // Check if window fits in current row
                if currentX + windowWidth > screenFrame.width - margin && !windowsInRow.isEmpty {
                    // Start new row
                    allRows.append(windowsInRow)
                    windowsInRow = []
                    currentY += rowHeight + baseSpacing + CGFloat.random(in: -5...10)
                    currentX = margin
                    rowHeight = 0
                }

                let yOffset = CGFloat.random(in: -10...10)

                windowsInRow.append((scaledWindow, currentX, currentY, yOffset))
                currentX += windowWidth + spacingVariation
                rowHeight = max(rowHeight, windowHeight)
            }

            // Add last row
            if !windowsInRow.isEmpty {
                allRows.append(windowsInRow)
            }
        }

        // Calculate total height and vertically center
        let finalTotalHeight = allRows.enumerated().reduce(0) { total, row in
            let (index, windows) = row
            let maxHeight = windows.map { $0.window.size.height }.max() ?? 0
            return total + maxHeight + (index > 0 ? baseSpacing : 0)
        }

        // Ensure vertical offset doesn't push windows off screen
        let verticalOffset: CGFloat
        if finalTotalHeight > availableHeight {
            verticalOffset = 0
            print("MissionControlWindowSelector: Warning - total height (\(finalTotalHeight)) still exceeds available height (\(availableHeight))")
        } else {
            verticalOffset = (screenFrame.height - finalTotalHeight) / 2
        }

        // Create thumbnail views with organic positioning
        for row in allRows {
            // Calculate row width for centering
            let rowWidth = row.last!.x + row.last!.window.size.width - row.first!.x
            let rowOffset = (screenFrame.width - rowWidth) / 2

            for item in row {
                // Calculate final position with Y-offset variation
                let finalX = item.x - margin + rowOffset
                let finalY = item.y - margin + verticalOffset + item.yOffset  // Add Y-offset for organic feel

                // Ensure window stays within screen bounds
                let clampedX = max(margin, min(finalX, screenFrame.width - margin - item.window.size.width))
                let clampedY = max(margin, min(finalY, screenFrame.height - margin - item.window.size.height))

                let thumbnailView = WindowThumbnailView(frame: CGRect(
                    x: clampedX,
                    y: clampedY,
                    width: item.window.size.width,
                    height: item.window.size.height
                ))

                thumbnailView.configure(with: item.window.thumbnail)
                thumbnailView.onHover = { [weak self] view in
                    self?.handleHover(view: view)
                }
                thumbnailView.onClick = { [weak self] view in
                    self?.handleClick(view: view)
                }
                thumbnailView.onResizeNow = { [weak self] view, newSize in
                    self?.handleResizeNow(view: view, newSize: newSize)
                }

                // Add subtle shadow for depth
                thumbnailView.wantsLayer = true
                thumbnailView.shadow = NSShadow()
                thumbnailView.layer?.shadowColor = NSColor.black.cgColor
                thumbnailView.layer?.shadowOpacity = 0.4
                thumbnailView.layer?.shadowOffset = CGSize(width: 0, height: -4)
                thumbnailView.layer?.shadowRadius = 12

                view.addSubview(thumbnailView)
                thumbnailViews.append(thumbnailView)
            }
        }

        print("MissionControlWindowSelector: Created \(allRows.count) rows with organic layout, scale \(scale)")
    }

    private func handleHover(view: WindowThumbnailView?) {
        // Remove highlight from previous view
        hoveredView?.setHighlighted(false)

        // Highlight new view
        hoveredView = view
        view?.setHighlighted(true)
    }

    private func handleResizeNow(view: WindowThumbnailView, newSize: CGSize) {
        guard let thumbnail = view.thumbnail else { return }

        let appName = thumbnail.appName
        let windowID = thumbnail.windowID

        // Calculate optimal size based on screen resolution (up to 80% of screen)
        let optimalSize = calculateOptimalWindowSize(for: newSize)

        // Get current window size via Accessibility API to check if resize is needed
        getCurrentWindowSize(windowID: windowID) { [weak self] currentSize in
            guard let self = self else { return }

            if let currentSize = currentSize {
                let currentAspect = currentSize.width / currentSize.height
                let targetAspect = optimalSize.width / optimalSize.height
                let aspectDiff = abs(currentAspect - targetAspect)

                // If aspect ratio is already correct (within 1% tolerance) and size is similar, skip resize
                if aspectDiff < 0.01 && abs(currentSize.width - optimalSize.width) < 50 {
                    print("MissionControlWindowSelector: Window already at correct aspect ratio \(String(format: "%.3f", currentAspect)) (target: \(String(format: "%.3f", targetAspect))), skipping resize")
                    return
                }

                print("MissionControlWindowSelector: Current aspect: \(String(format: "%.3f", currentAspect)), target: \(String(format: "%.3f", targetAspect)) - resize needed")
            }

            print("MissionControlWindowSelector: Resizing \(appName) to \(optimalSize) (requested: \(newSize))...")

            // Start capturing thumbnails continuously to show animation
            self.startContinuousThumbnailCapture(for: view, duration: 1.0)

            // Resize the window
            self.resizeWindow(appName: appName, windowID: windowID, newSize: optimalSize) { success in
                if success {
                    print("MissionControlWindowSelector: ✓ Window resized to \(optimalSize)")
                    // Mark this window as modified for potential restoration
                    self.modifiedWindows.insert(windowID)
                } else {
                    print("MissionControlWindowSelector: ⚠️ Failed to resize window")
                }
            }
        }
    }

    // Get the current size of a window via Accessibility API
    private func getCurrentWindowSize(windowID: CGWindowID, completion: @escaping (CGSize?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Get the window info to find the owning PID
            guard let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
                  let info = windowInfo.first,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            // Check accessibility permissions
            let trusted = AXIsProcessTrusted()
            if !trusted {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            // Create AXUIElement for the application
            let appElement = AXUIElementCreateApplication(pid)

            // Get all windows
            var windowList: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)

            guard result == .success, let windows = windowList as? [AXUIElement], let targetWindow = windows.first else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            // Get current size
            var currentSizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(targetWindow, kAXSizeAttribute as CFString, &currentSizeValue)
            if let sizeValue = currentSizeValue {
                var currentSize = CGSize.zero
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &currentSize)

                DispatchQueue.main.async {
                    completion(currentSize)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    // Continuously capture thumbnails to show resize animation in real-time
    private func startContinuousThumbnailCapture(for view: WindowThumbnailView, duration: TimeInterval) {
        guard let thumbnail = view.thumbnail,
              let scWindow = thumbnail.scWindow else { return }

        let captureInterval = 0.05  // Capture every 50ms (20fps)
        let totalCaptures = Int(duration / captureInterval)
        var captureCount = 0

        // Create a timer to capture thumbnails repeatedly
        let timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] timer in
            captureCount += 1

            // Capture a new thumbnail
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    if let newImage = try await self.captureWindowThumbnail(window: scWindow) {
                        await MainActor.run {
                            view.updateImageInstant(newImage)
                        }
                    }
                } catch {
                    // Ignore errors during continuous capture
                }
            }

            // Stop after duration
            if captureCount >= totalCaptures {
                timer.invalidate()
                print("MissionControlWindowSelector: ✓ Thumbnail animation complete")
            }
        }

        RunLoop.current.add(timer, forMode: .common)
    }

    // Calculate optimal window size based on screen resolution and desired aspect ratio
    private func calculateOptimalWindowSize(for targetSize: CGSize) -> CGSize {
        guard let screen = NSScreen.main else {
            return targetSize
        }

        let screenSize = screen.visibleFrame.size
        let maxWidth = screenSize.width * 0.9
        let maxHeight = screenSize.height * 0.9

        // Calculate target aspect ratio
        let targetAspect = targetSize.width / targetSize.height

        print("MissionControlWindowSelector: Screen size: \(screenSize), Max size (90%): \(maxWidth)x\(maxHeight)")
        print("MissionControlWindowSelector: Target aspect ratio: \(targetAspect) (\(targetSize.width):\(targetSize.height))")

        // Calculate optimal size that fits within 90% of screen while maintaining aspect ratio
        var optimalWidth: CGFloat
        var optimalHeight: CGFloat

        if targetAspect > 1.0 {
            // Landscape orientation (width > height)
            // Try to use maximum width first
            optimalWidth = maxWidth
            optimalHeight = optimalWidth / targetAspect

            // If height exceeds max, scale down
            if optimalHeight > maxHeight {
                optimalHeight = maxHeight
                optimalWidth = optimalHeight * targetAspect
            }
        } else {
            // Portrait orientation (height > width) or square
            // Try to use maximum height first
            optimalHeight = maxHeight
            optimalWidth = optimalHeight * targetAspect

            // If width exceeds max, scale down
            if optimalWidth > maxWidth {
                optimalWidth = maxWidth
                optimalHeight = optimalWidth / targetAspect
            }
        }

        let result = CGSize(width: round(optimalWidth), height: round(optimalHeight))
        print("MissionControlWindowSelector: Calculated optimal size: \(result)")

        return result
    }

    // Recapture and update the thumbnail for a window
    private func updateThumbnail(for view: WindowThumbnailView) {
        guard let thumbnail = view.thumbnail,
              let scWindow = thumbnail.scWindow else { return }

        print("MissionControlWindowSelector: Recapturing thumbnail for \(thumbnail.appName)...")

        Task {
            do {
                // Recapture the window thumbnail
                if let newImage = try await self.captureWindowThumbnail(window: scWindow) {
                    await MainActor.run {
                        view.updateImage(newImage)
                        print("MissionControlWindowSelector: ✓ Thumbnail updated")
                    }
                }
            } catch {
                print("MissionControlWindowSelector: ⚠️ Failed to recapture thumbnail: \(error)")
            }
        }
    }

    private func handleClick(view: WindowThumbnailView) {
        guard let thumbnail = view.thumbnail else { return }

        print("MissionControlWindowSelector: Selected window: \(thumbnail.appName)")

        let windowID = thumbnail.windowID
        let appName = thumbnail.appName

        // User is proceeding with recording, so clear modified windows tracking
        // We don't want to restore windows if the user intentionally chose to record with new size
        modifiedWindows.removeAll()
        print("MissionControlWindowSelector: Cleared modified windows tracking - user is proceeding with recording")

        // Close the grid first
        close()

        // Start recording immediately
        // If user clicked an aspect ratio button, the window was already resized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.onWindowSelected?(windowID, appName)
        }
    }


    // Calculate a better aspect ratio for screen recording
    private func calculateBetterAspectRatio(currentSize: CGSize) -> CGSize {
        let currentWidth = currentSize.width
        let currentHeight = currentSize.height
        let currentAspect = currentWidth / currentHeight

        // Common aspect ratios for screen recording
        let aspectRatios: [(ratio: CGFloat, width: CGFloat, height: CGFloat)] = [
            (16.0/9.0, 1920, 1080),   // 16:9 HD
            (16.0/9.0, 1280, 720),    // 16:9 HD smaller
            (16.0/10.0, 1440, 900),   // 16:10
            (4.0/3.0, 1024, 768),     // 4:3
            (16.0/9.0, 1600, 900),    // 16:9 intermediate
        ]

        // Find the closest standard resolution that fits the current window
        var bestMatch = aspectRatios[0]
        var bestScore = CGFloat.greatestFiniteMagnitude

        for ar in aspectRatios {
            // Prefer resolutions that are close to current size but better aspect ratio
            let widthDiff = abs(ar.width - currentWidth)
            let heightDiff = abs(ar.height - currentHeight)
            let aspectDiff = abs(ar.ratio - currentAspect)

            let score = widthDiff + heightDiff + (aspectDiff * 500) // Weight aspect ratio heavily

            if score < bestScore {
                bestScore = score
                bestMatch = ar
            }
        }

        return CGSize(width: bestMatch.width, height: bestMatch.height)
    }

    // Resize a window using Accessibility API and center it on screen
    private func resizeWindow(appName: String, windowID: CGWindowID, newSize: CGSize, completion: @escaping (Bool) -> Void) {
        print("MissionControlWindowSelector: Attempting to resize window for app: '\(appName)' (ID: \(windowID)) to size: \(newSize)")

        DispatchQueue.global(qos: .userInitiated).async {
            // Check if we have accessibility permissions
            let trusted = AXIsProcessTrusted()
            if !trusted {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ❌ No Accessibility permission. Please grant in System Settings > Privacy & Security > Accessibility")
                    completion(false)
                }
                return
            }

            // Get the window info to find the owning PID
            guard let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
                  let info = windowInfo.first,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ❌ Failed to get window info for ID: \(windowID)")
                    completion(false)
                }
                return
            }

            print("MissionControlWindowSelector: Found PID: \(pid) for window ID: \(windowID)")

            // Create AXUIElement for the application
            let appElement = AXUIElementCreateApplication(pid)

            // Get all windows
            var windowList: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)

            guard result == .success, let windows = windowList as? [AXUIElement] else {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ❌ Failed to get windows for app. Error: \(result.rawValue)")
                    completion(false)
                }
                return
            }

            print("MissionControlWindowSelector: Found \(windows.count) windows for app")

            // Try to find the matching window (usually the first one is what we want)
            guard let targetWindow = windows.first else {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ❌ No windows found")
                    completion(false)
                }
                return
            }

            // Get current size
            var currentSizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(targetWindow, kAXSizeAttribute as CFString, &currentSizeValue)
            if let sizeValue = currentSizeValue {
                var currentSize = CGSize.zero
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &currentSize)
                print("MissionControlWindowSelector: Current window size: \(currentSize)")
            }

            // Calculate center position on screen
            guard let screen = NSScreen.main else {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ❌ Failed to get main screen")
                    completion(false)
                }
                return
            }

            let screenFrame = screen.visibleFrame
            let centerX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2
            let centerY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
            let centerPosition = CGPoint(x: centerX, y: centerY)

            print("MissionControlWindowSelector: Screen frame: \(screenFrame)")
            print("MissionControlWindowSelector: Centering window at: \(centerPosition)")

            // Set new size
            var newSizeValue = newSize
            let sizeAxValue = AXValueCreate(.cgSize, &newSizeValue)!
            let setSizeResult = AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeAxValue)

            if setSizeResult != .success {
                DispatchQueue.main.async {
                    print("MissionControlWindowSelector: ⚠️ Failed to resize window. Error: \(setSizeResult.rawValue)")
                    completion(false)
                }
                return
            }

            // Wait a moment for the resize to complete
            Thread.sleep(forTimeInterval: 0.1)

            // Get the ACTUAL size after resize (app may have constrained it)
            var actualSizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(targetWindow, kAXSizeAttribute as CFString, &actualSizeValue)

            var actualSize = newSize
            if let sizeValue = actualSizeValue {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &actualSize)
            }

            // Check if actual size matches requested size
            let widthDiff = abs(actualSize.width - newSize.width)
            let heightDiff = abs(actualSize.height - newSize.height)

            if widthDiff > 10 || heightDiff > 10 {
                print("MissionControlWindowSelector: ⚠️ Window constrained by app - Requested: \(Int(newSize.width))×\(Int(newSize.height)), Actual: \(Int(actualSize.width))×\(Int(actualSize.height))")
                let actualAspect = actualSize.width / actualSize.height
                let requestedAspect = newSize.width / newSize.height
                print("MissionControlWindowSelector: Aspect ratio - Requested: \(String(format: "%.3f", requestedAspect)), Actual: \(String(format: "%.3f", actualAspect))")
            }

            // IMPORTANT: Recalculate center position based on ACTUAL size to ensure equal gaps
            let actualCenterX = screenFrame.origin.x + (screenFrame.width - actualSize.width) / 2
            let actualCenterY = screenFrame.origin.y + (screenFrame.height - actualSize.height) / 2
            let actualCenterPosition = CGPoint(x: actualCenterX, y: actualCenterY)

            print("MissionControlWindowSelector: Centering window based on actual size at: \(actualCenterPosition)")

            // Set position based on actual size for perfect centering
            var actualPositionValue = actualCenterPosition
            let actualPositionAxValue = AXValueCreate(.cgPoint, &actualPositionValue)!
            let setPositionResult = AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, actualPositionAxValue)

            DispatchQueue.main.async {
                if setPositionResult == .success {
                    print("MissionControlWindowSelector: ✅ Window resized to \(Int(actualSize.width))×\(Int(actualSize.height)) and centered at \(actualCenterPosition)")
                    completion(true)
                } else {
                    print("MissionControlWindowSelector: ⚠️ Failed to center window. Error: \(setPositionResult.rawValue)")
                    // Still consider it success if resize worked
                    completion(true)
                }
            }
        }
    }

    private func cancel() {
        print("MissionControlWindowSelector: Cancelled")

        // Restore any modified windows to their original state
        if !modifiedWindows.isEmpty {
            print("MissionControlWindowSelector: Restoring \(modifiedWindows.count) modified window(s)...")
            restoreModifiedWindows()
        }

        // Close first, then call callback after a brief delay to ensure cleanup completes
        close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.onCancelled?()
        }
    }

    // Restore all modified windows to their original positions and sizes
    private func restoreModifiedWindows() {
        for windowID in modifiedWindows {
            guard let originalState = originalWindowStates[windowID] else {
                print("MissionControlWindowSelector: ⚠️ No original state found for window ID: \(windowID)")
                continue
            }

            print("MissionControlWindowSelector: Restoring \(originalState.appName) (ID: \(windowID)) to position: \(originalState.position), size: \(originalState.size)")

            // Restore using Accessibility API
            DispatchQueue.global(qos: .userInitiated).async {
                guard originalState.pid != 0 else {
                    print("MissionControlWindowSelector: ⚠️ Invalid PID for window restoration")
                    return
                }

                // Check accessibility permissions
                let trusted = AXIsProcessTrusted()
                if !trusted {
                    print("MissionControlWindowSelector: ⚠️ Cannot restore - no Accessibility permission")
                    return
                }

                // Create AXUIElement for the application
                let appElement = AXUIElementCreateApplication(originalState.pid)

                // Get all windows
                var windowList: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)

                guard result == .success, let windows = windowList as? [AXUIElement], let targetWindow = windows.first else {
                    print("MissionControlWindowSelector: ⚠️ Failed to get window for restoration")
                    return
                }

                // Restore size
                var restoreSize = originalState.size
                let sizeAxValue = AXValueCreate(.cgSize, &restoreSize)!
                let setSizeResult = AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeAxValue)

                // Restore position
                var restorePosition = originalState.position
                let positionAxValue = AXValueCreate(.cgPoint, &restorePosition)!
                let setPositionResult = AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, positionAxValue)

                DispatchQueue.main.async {
                    if setSizeResult == .success && setPositionResult == .success {
                        print("MissionControlWindowSelector: ✅ Restored \(originalState.appName)")
                    } else {
                        print("MissionControlWindowSelector: ⚠️ Failed to restore \(originalState.appName) - Size: \(setSizeResult.rawValue), Position: \(setPositionResult.rawValue)")
                    }
                }
            }
        }
    }

    private func close() {
        // CRITICAL: Remove event monitor to prevent system hang
        // Ensure this happens on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let monitor = self.eventMonitor {
                NSEvent.removeMonitor(monitor)
                self.eventMonitor = nil
                print("MissionControlWindowSelector: Event monitor removed")
            }

            // Hide the overlay window (DON'T close - causes animation crash)
            if let window = self.overlayWindow {
                window.orderOut(nil)
                // DON'T close or nil out - just hide it
                print("MissionControlWindowSelector: Overlay window hidden")
            }
        }
    }

    // Public cleanup method for external callers
    func cleanup() {
        print("MissionControlWindowSelector: Cleanup called")
        close()

        // Clear thumbnail views to release memory
        thumbnailViews.removeAll()
        windows.removeAll()

        // Properly dispose of overlay window after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let window = self?.overlayWindow {
                window.close()
                self?.overlayWindow = nil
                print("MissionControlWindowSelector: Overlay window closed and nil'd")
            }
        }
    }
}

// MARK: - Window Thumbnail View

class WindowThumbnailView: NSView {
    private var imageView: NSImageView!
    private var labelView: NSTextField!
    private var highlightBorder: NSView!
    private var buttonContainer: NSView!
    private var sizePreviewLabel: NSTextField!
    private var trackingArea: NSTrackingArea?

    // Store the selected aspect ratio for when user clicks to record
    private var selectedAspectRatio: CGSize?

    var thumbnail: WindowThumbnail?
    var onHover: ((WindowThumbnailView?) -> Void)?
    var onClick: ((WindowThumbnailView) -> Void)?
    var onResizeNow: ((WindowThumbnailView, CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Add subtle shadow for depth (like real Mission Control)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        layer?.shadowRadius = 10

        // Image view for thumbnail - full size now since label will be outside
        imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0  // Explicitly no border
        imageView.layer?.borderColor = nil
        addSubview(imageView)

        // Label for app name (will be positioned BELOW the border, outside the thumbnail)
        labelView = NSTextField(frame: CGRect(
            x: 0,
            y: -25,  // Below the thumbnail
            width: bounds.width,
            height: 20
        ))
        labelView.isEditable = false
        labelView.isBordered = false
        labelView.isSelectable = false
        labelView.drawsBackground = false
        labelView.textColor = .white
        labelView.alignment = .center
        labelView.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelView.wantsLayer = true
        labelView.layer?.shadowColor = NSColor.black.cgColor
        labelView.layer?.shadowOpacity = 0.8
        labelView.layer?.shadowOffset = CGSize(width: 0, height: 0)
        labelView.layer?.shadowRadius = 3
        addSubview(labelView)

        // Highlight border (hidden by default) - thicker and more prominent
        highlightBorder = NSView(frame: bounds.insetBy(dx: 2, dy: 2))
        highlightBorder.wantsLayer = true
        highlightBorder.layer?.borderColor = NSColor.systemBlue.cgColor
        highlightBorder.layer?.borderWidth = 5
        highlightBorder.layer?.cornerRadius = 8
        highlightBorder.layer?.backgroundColor = NSColor.clear.cgColor
        highlightBorder.isHidden = true
        addSubview(highlightBorder)

        // Container for aspect ratio buttons (hidden by default, shown on hover)
        buttonContainer = NSView(frame: .zero)
        buttonContainer.wantsLayer = true
        buttonContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        buttonContainer.layer?.cornerRadius = 8
        buttonContainer.isHidden = true
        addSubview(buttonContainer)

        // Size preview label (shows selected aspect ratio)
        sizePreviewLabel = NSTextField(frame: .zero)
        sizePreviewLabel.isEditable = false
        sizePreviewLabel.isBordered = false
        sizePreviewLabel.drawsBackground = false
        sizePreviewLabel.textColor = .white
        sizePreviewLabel.alignment = .center
        sizePreviewLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        sizePreviewLabel.stringValue = ""
        sizePreviewLabel.isHidden = true
        sizePreviewLabel.wantsLayer = true
        sizePreviewLabel.layer?.shadowColor = NSColor.black.cgColor
        sizePreviewLabel.layer?.shadowOpacity = 1.0
        sizePreviewLabel.layer?.shadowOffset = CGSize(width: 0, height: 0)
        sizePreviewLabel.layer?.shadowRadius = 2
        addSubview(sizePreviewLabel)

        // Create single "Resize" button
        let buttonWidth: CGFloat = 100
        let buttonHeight: CGFloat = 26

        let resizeButton = NSButton(frame: CGRect(
            x: 8,
            y: 6,
            width: buttonWidth,
            height: buttonHeight
        ))
        resizeButton.title = "RESIZE"
        resizeButton.isBordered = false
        resizeButton.bezelStyle = .shadowlessSquare
        resizeButton.focusRingType = .none
        resizeButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        resizeButton.target = self
        resizeButton.action = #selector(resizeButtonClicked(_:))
        resizeButton.wantsLayer = true
        resizeButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        resizeButton.layer?.cornerRadius = 4
        resizeButton.layer?.borderWidth = 0
        resizeButton.layer?.masksToBounds = true
        resizeButton.contentTintColor = .white

        buttonContainer.addSubview(resizeButton)

        // Size the container to fit the button
        let containerWidth = buttonWidth + 16
        let containerHeight = buttonHeight + 12
        buttonContainer.frame.size = CGSize(width: containerWidth, height: containerHeight)

        // Add tracking area for hover
        updateTrackingAreas()
    }

    @objc private func resizeButtonClicked(_ sender: NSButton) {
        guard let screen = NSScreen.main else { return }

        let screenSize = screen.visibleFrame.size
        let screenAspect = screenSize.width / screenSize.height

        // Calculate 90% of screen size while maintaining screen aspect ratio
        let targetWidth = screenSize.width * 0.9
        let targetHeight = screenSize.height * 0.9
        let newSize = CGSize(width: targetWidth, height: targetHeight)

        print("WindowThumbnailView: Resizing window to 90% of screen: \(Int(targetWidth))×\(Int(targetHeight)) (aspect: \(String(format: "%.3f", screenAspect)))")

        // Store the selected aspect ratio
        selectedAspectRatio = newSize

        // Update preview label to show selected size
        sizePreviewLabel.stringValue = "Resizing to 90% of screen..."
        sizePreviewLabel.isHidden = false

        // Highlight the button
        sender.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor

        // Resize the window immediately!
        onResizeNow?(self, newSize)
    }

    func configure(with thumbnail: WindowThumbnail) {
        self.thumbnail = thumbnail
        imageView.image = thumbnail.image
        labelView.stringValue = thumbnail.appName

        // Update frame positions to match new bounds - full size for image now
        imageView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)

        // Position label below the thumbnail (outside bounds)
        labelView.frame = CGRect(
            x: 0,
            y: -25,  // Below the thumbnail
            width: bounds.width,
            height: 20
        )

        highlightBorder.frame = bounds.insetBy(dx: 2, dy: 2)

        // Position button container at BOTTOM INSIDE the thumbnail
        buttonContainer.frame.origin = CGPoint(
            x: (bounds.width - buttonContainer.frame.width) / 2,
            y: 10  // 10px from bottom, inside the thumbnail
        )

        // Position size preview label above the buttons (inside the thumbnail)
        sizePreviewLabel.frame = CGRect(
            x: 0,
            y: buttonContainer.frame.origin.y + buttonContainer.frame.height + 5,
            width: bounds.width,
            height: 20
        )
    }

    func setHighlighted(_ highlighted: Bool) {
        highlightBorder.isHidden = !highlighted
        buttonContainer.isHidden = !highlighted  // Show/hide button container with border

        // Show size preview label only if highlighted AND an aspect ratio is selected
        sizePreviewLabel.isHidden = !highlighted || selectedAspectRatio == nil

        // NO ANIMATION - just scale immediately to avoid animation crashes
        if highlighted {
            self.layer?.transform = CATransform3DMakeScale(1.05, 1.05, 1.0)
        } else {
            self.layer?.transform = CATransform3DIdentity
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )

        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(self)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Pass both the view and the selected aspect ratio to the click handler
        onClick?(self)
    }

    // Get the selected aspect ratio (if any)
    func getSelectedAspectRatio() -> CGSize? {
        return selectedAspectRatio
    }

    // Update the thumbnail image instantly without animation (for continuous capture)
    func updateImageInstant(_ newImage: NSImage) {
        imageView.image = newImage
    }

    // Update the thumbnail image with smooth morphing animation
    func updateImage(_ newImage: NSImage) {
        guard let oldImage = imageView.image else {
            // No old image, just set the new one
            imageView.image = newImage
            return
        }

        // Calculate aspect ratios
        let oldAspect = oldImage.size.width / oldImage.size.height
        let newAspect = newImage.size.width / newImage.size.height

        // If aspect ratios are similar, just swap without animation
        if abs(oldAspect - newAspect) < 0.01 {
            imageView.image = newImage
            return
        }

        // Create a temporary overlay image view for blending
        let newImageView = NSImageView(frame: imageView.frame)
        newImageView.image = newImage
        newImageView.imageScaling = .scaleAxesIndependently
        newImageView.wantsLayer = true
        newImageView.alphaValue = 0.0

        // Add new image view on top
        addSubview(newImageView, positioned: .above, relativeTo: imageView)

        // Animate with Core Animation for smooth 60fps
        let duration = 0.8

        // Create opacity animation for crossfade
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.0
        opacityAnimation.toValue = 1.0
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        // Create transform animation for morphing
        let oldScaleX = 1.0
        let newScaleX = newAspect / oldAspect

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale.x")
        scaleAnimation.fromValue = oldScaleX
        scaleAnimation.toValue = newScaleX
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        // Apply animations
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Clean up: set final state and remove temp view
            self?.imageView.layer?.transform = CATransform3DIdentity
            self?.imageView.image = newImage
            self?.imageView.alphaValue = 1.0
            newImageView.removeFromSuperview()
        }

        // Morph old image by scaling
        self.imageView.layer?.add(scaleAnimation, forKey: "scaleTransform")
        self.imageView.layer?.transform = CATransform3DMakeScale(newScaleX, 1.0, 1.0)

        // Fade in new image on top
        newImageView.layer?.add(opacityAnimation, forKey: "fadeIn")
        newImageView.alphaValue = 1.0

        CATransaction.commit()
    }
}
