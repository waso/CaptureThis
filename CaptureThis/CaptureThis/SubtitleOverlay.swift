import Cocoa

class SubtitleOverlay {
    private var overlayWindow: NSWindow?
    private var subtitleLabel: NSTextField?
    private var isActive = false

    // Bounds of the recording area
    private var recordingBounds: CGRect

    // Timer for hiding subtitle after delay
    private var hideTimer: Timer?

    init(recordingBounds: CGRect) {
        self.recordingBounds = recordingBounds
    }

    deinit {
        // Ensure cleanup happens
        hideTimer?.invalidate()

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

        isActive = true

        print("SubtitleOverlay: Started for bounds \(recordingBounds)")
    }

    func stop() {
        guard isActive else { return }

        hideTimer?.invalidate()
        hideTimer = nil

        isActive = false

        // NEVER close the window - just hide it
        // This prevents animation-related crashes
        overlayWindow?.orderOut(nil)

        // Clear the label
        if let label = subtitleLabel {
            label.stringValue = ""
            label.alphaValue = 0.0
        }

        print("SubtitleOverlay: Stopped")
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
        window.level = .floating  // Above most windows
        window.ignoresMouseEvents = true  // Don't interfere with user interaction
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none  // CRITICAL: Disable ALL window animations
        window.isReleasedWhenClosed = false  // CRITICAL: Don't release on close

        // Create subtitle label
        createSubtitleLabel(in: window)

        window.orderFront(nil)
        overlayWindow = window
    }

    private func createSubtitleLabel(in window: NSWindow) {
        let windowSize = window.frame.size

        // Position subtitle at bottom center
        // Create a container view that will auto-size based on text
        let containerView = NSView(frame: NSRect(
            x: 0,
            y: 40,  // 40pt from bottom
            width: windowSize.width,
            height: 200  // Enough space for multi-line text
        ))

        let label = NSTextField()
        label.isEditable = false
        label.isBordered = false
        label.isSelectable = false
        label.drawsBackground = false  // No background on the label itself
        label.textColor = .white
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 60, weight: .bold)  // 3x bigger (was 20pt)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.stringValue = ""
        label.alphaValue = 0.0  // Start hidden

        // Use attributed string for text with background only around text
        label.wantsLayer = true
        label.layer?.masksToBounds = false

        containerView.addSubview(label)
        window.contentView?.addSubview(containerView)
        subtitleLabel = label
    }

    // Show subtitle text
    func showSubtitle(_ text: String, duration: TimeInterval = 1.0) {
        guard let label = subtitleLabel, let containerView = label.superview else { return }

        // Cancel previous hide timer
        hideTimer?.invalidate()

        // Update text with attributed string that has background only around text
        DispatchQueue.main.async { [weak self, weak label] in
            guard let self = self, let label = label else { return }
            // Create attributed string with background color
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.8),  // Background only around text
                .paragraphStyle: paragraphStyle
            ]

            let attributedString = NSAttributedString(string: text, attributes: attributes)
            label.attributedStringValue = attributedString

            // Calculate text size and resize label to fit tightly
            let maxWidth = containerView.frame.width * 0.9  // Max 90% of screen width
            let textSize = attributedString.boundingRect(
                with: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size

            // Add padding around text
            let padding: CGFloat = 20
            let labelWidth = min(textSize.width + padding * 2, maxWidth)
            let labelHeight = textSize.height + padding * 2

            // Center the label horizontally
            let labelX = (containerView.frame.width - labelWidth) / 2

            label.frame = NSRect(
                x: labelX,
                y: 0,
                width: labelWidth,
                height: labelHeight
            )

            // Add rounded corners to the label
            label.wantsLayer = true
            label.layer?.cornerRadius = 12
            label.layer?.masksToBounds = true

            // NO ANIMATION - just show immediately
            // Animations cause crashes in _NSWindowTransformAnimation
            label.alphaValue = 1.0

            print("SubtitleOverlay: Showing subtitle: \(text)")
        }

        // Schedule hide after duration
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hideSubtitle()
        }
    }

    // Hide subtitle
    func hideSubtitle() {
        guard let label = subtitleLabel else { return }

        DispatchQueue.main.async { [weak label] in
            guard let label = label else { return }
            // NO ANIMATION - just hide immediately
            // Animations cause crashes in _NSWindowTransformAnimation
            label.alphaValue = 0.0
            label.stringValue = ""
        }
    }

    private func closeOverlayWindow() {
        // NEVER actually close - just hide
        // Closing causes animation crashes
        overlayWindow?.orderOut(nil)
    }

    // Update bounds if recording window moves/resizes
    func updateBounds(_ newBounds: CGRect) {
        recordingBounds = newBounds
        overlayWindow?.setFrame(newBounds, display: true)

        // Recreate subtitle label with new bounds
        if let window = overlayWindow {
            subtitleLabel?.removeFromSuperview()
            createSubtitleLabel(in: window)
        }
    }
}
