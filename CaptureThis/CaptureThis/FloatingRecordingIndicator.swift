import Cocoa

class FloatingRecordingIndicator: NSWindow {

    private var timerLabel: NSTextField!
    private var redDot: NSView!
    private var micButton: NSButton!
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var minimizeButton: NSButton!
    private var containerView: NSView!
    private var blinkTimer: Timer?
    private var isDotVisible = true
    private(set) var isMicrophoneOff = false

    // Callbacks
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onMicToggle: (() -> Void)?

    init(microphoneOff: Bool = false) {
        self.isMicrophoneOff = microphoneOff
        // Create a compact floating window - single row
        // Always include space for mic indicator
        let windowRect = NSRect(x: 100, y: 100, width: 220, height: 40)

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Window properties
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        setupUI()
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Container view with rounded background - single row, compact
        containerView = NSView(frame: contentView.bounds)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.95).cgColor
        containerView.layer?.cornerRadius = 8
        containerView.layer?.borderWidth = 0
        containerView.autoresizingMask = [.width, .height]
        contentView.addSubview(containerView)

        // Red dot indicator (centered vertically)
        redDot = NSView(frame: NSRect(x: 12, y: 15, width: 10, height: 10))
        redDot.wantsLayer = true
        redDot.layer?.backgroundColor = NSColor(red: 0.9, green: 0.05, blue: 0.0, alpha: 1.0).cgColor
        redDot.layer?.cornerRadius = 5
        containerView.addSubview(redDot)

        // Timer label (smaller font, centered vertically)
        timerLabel = NSTextField(labelWithString: "00:00")
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timerLabel.textColor = .white
        timerLabel.alignment = .left
        timerLabel.frame = NSRect(x: 28, y: 12, width: 50, height: 18)
        containerView.addSubview(timerLabel)

        // Microphone toggle button (always visible, clickable)
        let micX: CGFloat = 80
        let buttonOffset: CGFloat = 25  // Always offset buttons for mic indicator

        micButton = NSButton(frame: NSRect(x: micX, y: 10, width: 20, height: 20))
        micButton.title = ""
        micButton.bezelStyle = .regularSquare
        micButton.isBordered = false
        micButton.wantsLayer = true
        micButton.layer?.backgroundColor = NSColor.clear.cgColor
        micButton.target = self
        micButton.action = #selector(micButtonClicked)
        updateMicrophoneIndicator()
        containerView.addSubview(micButton)

        // Pause button (compact) - shifted right for mic indicator
        pauseButton = NSButton(frame: NSRect(x: 85 + buttonOffset, y: 10, width: 28, height: 20))
        pauseButton.title = ""
        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.wantsLayer = true
        pauseButton.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        pauseButton.layer?.cornerRadius = 3

        let pauseIcon = NSMutableAttributedString(string: "⏸")
        pauseIcon.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 1))
        pauseIcon.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: 1))
        pauseButton.attributedTitle = pauseIcon
        pauseButton.target = self
        pauseButton.action = #selector(pauseButtonClicked)
        containerView.addSubview(pauseButton)

        // Stop button (compact) - shifted right if mic indicator is visible
        stopButton = NSButton(frame: NSRect(x: 120 + buttonOffset, y: 10, width: 28, height: 20))
        stopButton.title = ""
        stopButton.bezelStyle = .regularSquare
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0).cgColor
        stopButton.layer?.cornerRadius = 3

        let stopIcon = NSMutableAttributedString(string: "■")
        stopIcon.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 1))
        stopIcon.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: 1))
        stopButton.attributedTitle = stopIcon
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)
        containerView.addSubview(stopButton)

        // Hide/Minimize button (compact) - shifted right if mic indicator is visible
        minimizeButton = NSButton(frame: NSRect(x: 155 + buttonOffset, y: 10, width: 28, height: 20))
        minimizeButton.title = ""
        minimizeButton.bezelStyle = .regularSquare
        minimizeButton.isBordered = false
        minimizeButton.wantsLayer = true
        minimizeButton.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        minimizeButton.layer?.cornerRadius = 3

        let minimizeIcon = NSMutableAttributedString(string: "▼")
        minimizeIcon.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 1))
        minimizeIcon.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: 1))
        minimizeButton.attributedTitle = minimizeIcon
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeButtonClicked)
        containerView.addSubview(minimizeButton)

        // Start blinking
        startBlinking()
    }

    func updateTime(_ timeString: String) {
        timerLabel.stringValue = timeString
    }

    func startBlinking() {
        // Stop any existing timer first
        stopBlinking()

        // Start blinking
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            self.isDotVisible.toggle()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.redDot.animator().alphaValue = self.isDotVisible ? 1.0 : 0.3
            })
        }
    }

    func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil

        // Safely set alpha if view still exists
        if let dot = redDot, !dot.isHidden {
            dot.alphaValue = 1.0  // Solid red when stopped/paused
        }
    }

    func setPaused(_ paused: Bool) {
        guard let button = pauseButton else { return }

        // Update pause button icon
        let icon = paused ? "▶" : "⏸"
        let pauseIcon = NSMutableAttributedString(string: icon)
        pauseIcon.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 1))
        pauseIcon.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: 1))
        button.attributedTitle = pauseIcon
    }

    func setDisabled(_ disabled: Bool) {
        guard let dot = redDot else { return }

        // Set red dot to faded color when disabled/paused (0.3 alpha)
        // Set to normal color when active (1.0 alpha)
        dot.alphaValue = disabled ? 0.3 : 1.0
    }

    private func updateMicrophoneIndicator() {
        guard let button = micButton else { return }

        let symbolName = isMicrophoneOff ? "mic.slash.fill" : "mic.fill"
        let tintColor = isMicrophoneOff
            ? NSColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0)  // Orange for mic off
            : NSColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)  // Green for mic on

        if let micImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: isMicrophoneOff ? "Microphone Off" : "Microphone On") {
            micImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = micImage.withSymbolConfiguration(config)
            button.contentTintColor = tintColor
        }
    }

    func setMicrophoneOff(_ off: Bool) {
        isMicrophoneOff = off
        updateMicrophoneIndicator()
    }

    @objc private func micButtonClicked() {
        onMicToggle?()
    }

    @objc private func pauseButtonClicked() {
        onPause?()
    }

    @objc private func stopButtonClicked() {
        onStop?()
    }

    @objc private func minimizeButtonClicked() {
        // Minimize to Dock like standard macOS apps
        miniaturize(nil)
        print("FloatingIndicator: Minimized to Dock")
    }

    func cleanup() {
        print("FloatingIndicator: Starting cleanup...")

        // Only stop timers - don't touch UI elements
        blinkTimer?.invalidate()
        blinkTimer = nil

        // Clear callbacks to prevent retain cycles
        onPause = nil
        onStop = nil
        onMicToggle = nil

        print("FloatingIndicator: Cleaned up (timers stopped, callbacks cleared)")
    }

    deinit {
        print("FloatingIndicator: deinit called")
        // Just stop the timer - don't touch any UI
        blinkTimer?.invalidate()
        blinkTimer = nil
    }
}

// Custom content view to make the window draggable
class DraggableFloatingView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        return true
    }
}
