import Cocoa
import AVFoundation
import UniformTypeIdentifiers

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    var isRecordingActive = false  // Track recording state
    var statusItem: NSStatusItem?  // Keep status item at app level to ensure it persists
    var dragMonitor: Any?
    var initialMouseLocation: NSPoint?
    var initialWindowOrigin: NSPoint?
    var currentZoomMode: Int = 0  // 0=No zoom, 1=Zoom in/out, 2=Follow mouse, 3=Manual
    var mainViewController: MainViewController?  // Reference to the recording controller
    var controlWindow: NSWindow?  // Reference to our control panel window
    var screenButton: HoverButton?  // Reference to screen recording button
    var windowButton: HoverButton?  // Reference to window recording button
    var selfieButton: HoverButton?  // Reference to selfie camera button
    var microphoneButton: HoverButton?  // Reference to microphone button
    var microphoneIconView: NSImageView?  // Reference to microphone icon
    var microphoneLabel: NSTextField?  // Reference to microphone label
    var cursorButton: HoverButton?  // Reference to cursor mode button
    var cursorIconView: NSImageView?  // Reference to cursor icon
    var cursorLabel: NSTextField?  // Reference to cursor label
    var currentCursorMode: Int = 0  // 0=Normal, 1=Click Highlight, 2=Big Pointer
    var zoomLabel: NSTextField?  // Reference to zoom label for updating text
    var recordingModeSelected: Bool = false  // Track if user has selected a recording mode
    var isFullScreenMode: Bool = true  // Track recording mode: true=full screen, false=selected window (default)
    var backgroundPickerWindow: BackgroundImagePickerWindow?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // SIMPLIFIED: Create a basic test window to verify sizing works

        // Load saved zoom mode preference
        currentZoomMode = UserDefaults.standard.integer(forKey: "zoomMode")

        // Load saved cursor overlay mode preference
        currentCursorMode = UserDefaults.standard.integer(forKey: "cursorOverlayMode")

        // Create simple window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 778, height: 66),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Basic window setup
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.alphaValue = 0.98  // 2% transparent
        window.center()

        // Create simple draggable test view
        let testView = SimpleDraggableView(frame: NSRect(x: 0, y: 0, width: 778, height: 66))
        testView.wantsLayer = true
        testView.layer?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0).cgColor
        testView.layer?.cornerRadius = 12

        // Add close button with SF Symbol
        let closeButton = HoverButton(normalColor: .clear, hoverColor: NSColor(white: 0.25, alpha: 1.0), selectedColor: NSColor(white: 0.25, alpha: 1.0))
        closeButton.frame = NSRect(x: 8, y: 8, width: 50, height: 50)
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.layer?.cornerRadius = 6

        // Use SF Symbol for close icon
        if let closeImage = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Close") {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = closeImage.withSymbolConfiguration(config)
            closeButton.image = configuredImage
            closeButton.contentTintColor = NSColor.white
        }

        closeButton.target = NSApp
        closeButton.action = #selector(NSApplication.terminate(_:))
        testView.addSubview(closeButton)

        // Add vertical separator line after close button
        let separatorLine1 = NSView(frame: NSRect(x: 66, y: 8, width: 1, height: 50))
        separatorLine1.wantsLayer = true
        separatorLine1.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        testView.addSubview(separatorLine1)

        // Add Zoom button container with icon and label
        let zoomContainer = PassThroughView(frame: NSRect(x: 76, y: 15, width: 70, height: 50))
        zoomContainer.wantsLayer = true

        // Create the button with icon only (no text)
        let zoomButton = HoverButton(normalColor: .clear,
                                      hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                      selectedColor: NSColor(white: 0.25, alpha: 1.0))
        zoomButton.frame = NSRect(x: 0, y: -8, width: 70, height: 50)  // Moved down to center around content
        zoomButton.title = ""  // Remove default "Button" text
        zoomButton.bezelStyle = .regularSquare
        zoomButton.isBordered = false
        zoomButton.wantsLayer = true
        zoomButton.layer?.backgroundColor = NSColor.clear.cgColor
        zoomButton.layer?.cornerRadius = 6

        zoomButton.target = self
        zoomButton.action = #selector(showZoomMenu(_:))
        zoomContainer.addSubview(zoomButton)

        // Add icon as a separate view on top of the button so it doesn't disappear on hover
        if let magnifyImage = NSImage(systemSymbolName: "rectangle.and.text.magnifyingglass", accessibilityDescription: "Zoom") {
            magnifyImage.isTemplate = true  // Set as template BEFORE configuration
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = magnifyImage.withSymbolConfiguration(config)

            // Create a PassThroughImageView so mouse events pass through for dragging
            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))  // Lowered from 18 to 16
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white  // Pure white
            zoomContainer.addSubview(iconView)  // Added after button so it appears on top
        }

        // Add "Zoom" label inside the button container, below the icon
        let zoomLabelView = PassThroughTextField(labelWithString: "Zoom")
        zoomLabelView.font = NSFont.systemFont(ofSize: 10, weight: .regular)  // Increased from 9 to 10
        zoomLabelView.textColor = NSColor(white: 0.6, alpha: 1.0)
        zoomLabelView.alignment = .center
        zoomLabelView.frame = NSRect(x: 0, y: -4, width: 70, height: 12)  // Moved lower for more spacing
        zoomLabelView.isEditable = false
        zoomLabelView.isSelectable = false
        zoomLabelView.isBordered = false
        zoomLabelView.backgroundColor = .clear
        zoomContainer.addSubview(zoomLabelView)

        // Store reference to the label so we can update it
        self.zoomLabel = zoomLabelView

        // Set initial label based on saved zoom mode
        updateZoomLabel()

        testView.addSubview(zoomContainer)

        // Add vertical separator line after zoom button
        let separatorLine2 = NSView(frame: NSRect(x: 156, y: 8, width: 1, height: 50))
        separatorLine2.wantsLayer = true
        separatorLine2.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        testView.addSubview(separatorLine2)

        // Add Screen button container with icon and label
        let screenContainer = PassThroughView(frame: NSRect(x: 166, y: 15, width: 70, height: 50))
        screenContainer.wantsLayer = true

        // Create the screen button
        let screenBtn = HoverButton(normalColor: .clear,
                                     hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                     selectedColor: NSColor(white: 0.25, alpha: 1.0))
        screenBtn.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        screenBtn.title = ""
        screenBtn.bezelStyle = .regularSquare
        screenBtn.isBordered = false
        screenBtn.wantsLayer = true
        screenBtn.layer?.backgroundColor = NSColor.clear.cgColor  // Start unselected
        screenBtn.layer?.cornerRadius = 6
        screenBtn.isSelected = false  // Not selected by default

        screenBtn.target = self
        screenBtn.action = #selector(screenButtonClicked(_:))
        screenContainer.addSubview(screenBtn)
        screenButton = screenBtn  // Store reference

        // Add icon
        if let screenImage = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Screen") {
            screenImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = screenImage.withSymbolConfiguration(config)

            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            screenContainer.addSubview(iconView)
        }

        // Add "Screen" label
        let screenLabel = PassThroughTextField(labelWithString: "Screen")
        screenLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        screenLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        screenLabel.alignment = .center
        screenLabel.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        screenLabel.isEditable = false
        screenLabel.isSelectable = false
        screenLabel.isBordered = false
        screenLabel.backgroundColor = .clear
        screenContainer.addSubview(screenLabel)

        testView.addSubview(screenContainer)

        // Add Window button container with icon and label (no separator between Screen and Window)
        let windowContainer = PassThroughView(frame: NSRect(x: 244, y: 15, width: 70, height: 50))
        windowContainer.wantsLayer = true

        // Create the window button
        let windowBtn = HoverButton(normalColor: .clear,
                                     hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                     selectedColor: NSColor(white: 0.25, alpha: 1.0))
        windowBtn.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        windowBtn.title = ""
        windowBtn.bezelStyle = .regularSquare
        windowBtn.isBordered = false
        windowBtn.wantsLayer = true
        windowBtn.layer?.backgroundColor = NSColor.clear.cgColor  // Not selected initially
        windowBtn.layer?.cornerRadius = 6

        windowBtn.target = self
        windowBtn.action = #selector(windowButtonClicked(_:))
        windowContainer.addSubview(windowBtn)
        windowButton = windowBtn  // Store reference

        // Add icon
        if let windowImage = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window") {
            windowImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = windowImage.withSymbolConfiguration(config)

            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            windowContainer.addSubview(iconView)
        }

        // Add "Window" label
        let windowLabel = PassThroughTextField(labelWithString: "Window")
        windowLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        windowLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        windowLabel.alignment = .center
        windowLabel.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        windowLabel.isEditable = false
        windowLabel.isSelectable = false
        windowLabel.isBordered = false
        windowLabel.backgroundColor = .clear
        windowContainer.addSubview(windowLabel)

        testView.addSubview(windowContainer)

        // Add Selfie button container with icon and label
        let selfieContainer = PassThroughView(frame: NSRect(x: 322, y: 15, width: 70, height: 50))
        selfieContainer.wantsLayer = true

        let selfieBtn = HoverButton(normalColor: .clear,
                                    hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                    selectedColor: NSColor(white: 0.25, alpha: 1.0))
        selfieBtn.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        selfieBtn.title = ""
        selfieBtn.bezelStyle = .regularSquare
        selfieBtn.isBordered = false
        selfieBtn.wantsLayer = true
        selfieBtn.layer?.backgroundColor = NSColor.clear.cgColor
        selfieBtn.layer?.cornerRadius = 6
        selfieBtn.target = self
        selfieBtn.action = #selector(selfieButtonClicked(_:))
        selfieContainer.addSubview(selfieBtn)
        selfieButton = selfieBtn

        if let selfieImage = NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: "Selfie") {
            selfieImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = selfieImage.withSymbolConfiguration(config)

            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            selfieContainer.addSubview(iconView)
        }

        let selfieLabel = PassThroughTextField(labelWithString: "Selfie")
        selfieLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        selfieLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        selfieLabel.alignment = .center
        selfieLabel.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        selfieLabel.isEditable = false
        selfieLabel.isSelectable = false
        selfieLabel.isBordered = false
        selfieLabel.backgroundColor = .clear
        selfieContainer.addSubview(selfieLabel)

        testView.addSubview(selfieContainer)

        // Add Microphone button container with icon and label (no separator before mic)
        let micContainer = PassThroughView(frame: NSRect(x: 400, y: 15, width: 70, height: 50))
        micContainer.wantsLayer = true

        let micBtn = HoverButton(normalColor: .clear,
                                  hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                  selectedColor: NSColor(white: 0.25, alpha: 1.0))
        micBtn.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        micBtn.title = ""
        micBtn.bezelStyle = .regularSquare
        micBtn.isBordered = false
        micBtn.wantsLayer = true
        micBtn.layer?.backgroundColor = NSColor.clear.cgColor
        micBtn.layer?.cornerRadius = 6
        micBtn.target = self
        micBtn.action = #selector(microphoneButtonClicked(_:))
        micContainer.addSubview(micBtn)
        microphoneButton = micBtn

        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone") {
            micImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = micImage.withSymbolConfiguration(config)

            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            micContainer.addSubview(iconView)
            microphoneIconView = iconView
        }

        let micLabel = PassThroughTextField(labelWithString: "Mic On")
        micLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        micLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        micLabel.alignment = .center
        micLabel.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        micLabel.isEditable = false
        micLabel.isSelectable = false
        micLabel.isBordered = false
        micLabel.backgroundColor = .clear
        micContainer.addSubview(micLabel)
        microphoneLabel = micLabel

        testView.addSubview(micContainer)

        // Add Cursor mode button container with icon and label
        let cursorContainer = PassThroughView(frame: NSRect(x: 478, y: 15, width: 70, height: 50))
        cursorContainer.wantsLayer = true

        let cursorBtn = HoverButton(normalColor: .clear,
                                     hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                     selectedColor: NSColor(white: 0.25, alpha: 1.0))
        cursorBtn.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        cursorBtn.title = ""
        cursorBtn.bezelStyle = .regularSquare
        cursorBtn.isBordered = false
        cursorBtn.wantsLayer = true
        cursorBtn.layer?.backgroundColor = NSColor.clear.cgColor
        cursorBtn.layer?.cornerRadius = 6
        cursorBtn.target = self
        cursorBtn.action = #selector(cursorModeButtonClicked(_:))
        cursorContainer.addSubview(cursorBtn)
        cursorButton = cursorBtn

        if let cursorImage = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "Cursor") {
            cursorImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = cursorImage.withSymbolConfiguration(config)

            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            cursorContainer.addSubview(iconView)
            cursorIconView = iconView
        }

        let cursorLabelView = PassThroughTextField(labelWithString: "Normal")
        cursorLabelView.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        cursorLabelView.textColor = NSColor(white: 0.6, alpha: 1.0)
        cursorLabelView.alignment = .center
        cursorLabelView.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        cursorLabelView.isEditable = false
        cursorLabelView.isSelectable = false
        cursorLabelView.isBordered = false
        cursorLabelView.backgroundColor = .clear
        cursorContainer.addSubview(cursorLabelView)
        cursorLabel = cursorLabelView

        testView.addSubview(cursorContainer)

        // Add Record button container with icon and label
        let recordContainer = PassThroughView(frame: NSRect(x: 696, y: 15, width: 70, height: 50))
        recordContainer.wantsLayer = true

        // Create the record button with icon only (no text)
        let recordButton = HoverButton(normalColor: .clear,
                                        hoverColor: NSColor(white: 0.25, alpha: 1.0),
                                        selectedColor: NSColor(white: 0.25, alpha: 1.0))
        recordButton.frame = NSRect(x: 0, y: -8, width: 70, height: 50)
        recordButton.title = ""
        recordButton.bezelStyle = .regularSquare
        recordButton.isBordered = false
        recordButton.wantsLayer = true
        recordButton.layer?.backgroundColor = NSColor.clear.cgColor
        recordButton.layer?.cornerRadius = 6

        recordButton.target = self
        recordButton.action = #selector(recordButtonClicked(_:))
        recordContainer.addSubview(recordButton)

        // Add icon as a separate view on top of the button so it doesn't disappear on hover
        if let recordImage = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Record") {
            recordImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let configuredImage = recordImage.withSymbolConfiguration(config)

            // Create a PassThroughImageView so mouse events pass through for dragging
            let iconView = PassThroughImageView(frame: NSRect(x: 0, y: 16, width: 70, height: 24))
            iconView.image = configuredImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .white
            recordContainer.addSubview(iconView)
        }

        // Add "Record" label inside the button container, below the icon
        let recordLabel = PassThroughTextField(labelWithString: "Record")
        recordLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        recordLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        recordLabel.alignment = .center
        recordLabel.frame = NSRect(x: 0, y: -4, width: 70, height: 12)
        recordLabel.isEditable = false
        recordLabel.isSelectable = false
        recordLabel.isBordered = false
        recordLabel.backgroundColor = .clear
        recordContainer.addSubview(recordLabel)

        testView.addSubview(recordContainer)

        // Add vertical separator line before record button
        let separatorLine3 = NSView(frame: NSRect(x: 688, y: 8, width: 1, height: 50))
        separatorLine3.wantsLayer = true
        separatorLine3.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        testView.addSubview(separatorLine3)

        let viewController = NSViewController()
        viewController.view = testView
        window.contentViewController = viewController

        // Show the window
        window.makeKeyAndOrderFront(nil)

        // Store reference to control window so we can hide it during recording
        controlWindow = window

        windowController = MainWindowController(window: window)

        // Create MainViewController instance for recording functionality
        mainViewController = MainViewController()

        // Force load the view to initialize all IBOutlets
        // This is needed even though we won't display the old UI
        _ = mainViewController?.view

        // Sync recording mode from saved preference
        let savedMode = UserDefaults.standard.integer(forKey: "recordingMode")
        if savedMode == RecordingMode.selectedWindow.rawValue {
            recordingModeSelected = true
            isFullScreenMode = false
        } else {
            recordingModeSelected = true
            isFullScreenMode = true
        }
        updateRecordingModeButtons()

        // Sync selfie enabled state to MainViewController
        // Force view to load first so viewDidLoad() restores the saved state
        if let mvc = mainViewController {
            _ = mvc.view  // Trigger viewDidLoad() to restore saved state
            let isEnabled = mvc.isSelfieEnabled()
            selfieButton?.isSelected = isEnabled
            selfieButton?.layer?.backgroundColor = isEnabled ?
                NSColor(white: 0.25, alpha: 1.0).cgColor :
                NSColor.clear.cgColor
            print("AppDelegate: Restored selfie enabled state: \(isEnabled)")
        }

        // Sync microphone state
        updateMicrophoneButtonState()

        // Sync cursor mode state
        updateCursorButtonState()

        print("AppDelegate: Window shown with frame: \(window.frame)")

        // Add event monitor to enable dragging even when clicking on buttons
        setupDragMonitor(for: window)

        // Check permissions sequentially at startup
        checkPermissionsSequentially()
    }

    private func checkPermissionsSequentially() {
        // Step 1: Check screen recording permission
        checkScreenRecordingPermission { [weak self] in
            // Step 2: Check microphone permission (after screen recording is handled)
            self?.checkMicrophonePermission {
                print("AppDelegate: All permission checks completed")
            }
        }
    }

    private func checkScreenRecordingPermission(completion: @escaping () -> Void) {
        if !ScreenRecorderNew.checkPermission() {
            print("AppDelegate: Screen recording permission not granted, requesting...")
            ScreenRecorderNew.requestPermission()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText = "CaptureThis needs screen recording permission to capture your screen. Please enable it in System Settings and restart the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Continue")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }

                completion()
            }
        } else {
            print("AppDelegate: Screen recording permission already granted")
            completion()
        }
    }

    private func checkMicrophonePermission(completion: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("AppDelegate: Microphone authorization status: \(status.rawValue)")

        switch status {
        case .authorized:
            print("AppDelegate: Microphone permission already granted")
            completion()
        case .notDetermined:
            print("AppDelegate: Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("AppDelegate: Microphone permission granted")
                    } else {
                        print("AppDelegate: Microphone permission denied")
                        self?.showMicrophonePermissionAlert()
                    }
                    completion()
                }
            }
        case .denied, .restricted:
            print("AppDelegate: Microphone permission denied/restricted")
            showMicrophonePermissionAlert()
            completion()
        @unknown default:
            completion()
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "CaptureThis needs microphone access to record audio with your screen recording. Please enable it in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func recordButtonClicked(_ sender: NSButton) {
        print("Record button clicked! isRecordingActive: \(isRecordingActive)")

        guard let mvc = mainViewController else {
            print("Error: MainViewController not initialized")
            return
        }

        if isRecordingActive {
            print("Stopping recording...")
            // Call MainViewController's stop recording method
            mvc.stopRecording()
            // Note: isRecordingActive will be set to false by MainViewController

            // Show control window again after stopping
            showControlWindow()
        } else {
            // If user hasn't selected a recording mode, ensure full screen mode is set (default)
            if !recordingModeSelected {
                print("No recording mode selected, defaulting to full screen")
                isFullScreenMode = true
                mvc.selectFullScreenMode()
            }

            print("Starting recording with zoom mode: \(currentZoomMode), fullScreen: \(isFullScreenMode)")

            // Hide control window before starting recording
            hideControlWindow()

            // Call MainViewController's start recording method
            mvc.startRecording()
            // Note: isRecordingActive will be set to true by MainViewController's actuallyStartRecording()
        }
    }

    private func hideControlWindow() {
        print("AppDelegate: Hiding control window")
        if let window = controlWindow {
            // Make window completely transparent and move far off-screen
            window.alphaValue = 0.0
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        }
    }

    private func showControlWindow() {
        print("AppDelegate: Showing control window")
        if let window = controlWindow {
            // Restore window visibility and position
            window.alphaValue = 0.98  // Restore 2% transparency
            window.center()  // Center on screen
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func screenButtonClicked(_ sender: NSButton) {
        print("Screen button clicked!")
        showScreenSelectionMenu(sender)
    }

    private func showScreenSelectionMenu(_ sender: NSButton) {
        guard let mvc = mainViewController else { return }

        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 11)

        // Force dark appearance for menu
        if #available(macOS 10.14, *) {
            menu.appearance = NSAppearance(named: .darkAqua)
        }

        // Get available displays
        let displays = ScreenRecorderNew.availableDisplays()

        if displays.count <= 1 {
            // Only one display, just select it directly
            selectScreenMode(displayID: nil, displayName: nil)
            return
        }

        // Add header
        let headerItem = NSMenuItem(title: "Select Display:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Add available displays
        for display in displays {
            let resolution = "\(Int(display.frame.width))x\(Int(display.frame.height))"
            let title = "\(display.name) (\(resolution))"
            let item = NSMenuItem(title: title, action: #selector(selectDisplayMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display

            // Check if this is the currently selected display
            if let selectedID = mvc.selectedDisplayID {
                item.state = display.id == selectedID ? .on : .off
            } else {
                // No display selected, check main display
                item.state = display.isMain ? .on : .off
            }

            menu.addItem(item)
        }

        // Show the menu below the button
        let location = NSPoint(x: 0, y: sender.bounds.height + 5)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func selectDisplayMenuItem(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? ScreenRecorderNew.DisplayInfo else { return }
        selectScreenMode(displayID: display.id, displayName: display.name)
    }

    private func selectScreenMode(displayID: CGDirectDisplayID?, displayName: String?) {
        // Update mode
        recordingModeSelected = true
        isFullScreenMode = true

        // Update button states
        updateRecordingModeButtons()

        // Update MainViewController recording mode and selected display
        if let mvc = mainViewController {
            mvc.selectFullScreenMode()
            mvc.setSelectedDisplay(displayID, name: displayName)
        }

        print("AppDelegate: Selected screen mode with display: \(displayName ?? "Main Display")")
    }

    @objc private func windowButtonClicked(_ sender: NSButton) {
        print("Window button clicked!")

        // Only update if not already selected
        if recordingModeSelected && !isFullScreenMode {
            print("Window mode already selected")
            return
        }

        // Update mode
        recordingModeSelected = true
        isFullScreenMode = false

        // Update button states
        updateRecordingModeButtons()

        // Update MainViewController recording mode
        if let mvc = mainViewController {
            mvc.selectWindowMode()
        }
    }

    private func updateRecordingModeButtons() {
        // Update Screen button
        if let screenBtn = screenButton {
            screenBtn.isSelected = isFullScreenMode
            screenBtn.layer?.backgroundColor = isFullScreenMode ?
                NSColor(white: 0.25, alpha: 1.0).cgColor :
                NSColor.clear.cgColor
        }

        // Update Window button
        if let windowBtn = windowButton {
            windowBtn.isSelected = !isFullScreenMode
            windowBtn.layer?.backgroundColor = !isFullScreenMode ?
                NSColor(white: 0.25, alpha: 1.0).cgColor :
                NSColor.clear.cgColor
        }
    }

    @objc private func selfieButtonClicked(_ sender: NSButton) {
        showSelfieCameraMenu(sender)
    }

    private func showSelfieCameraMenu(_ sender: NSButton) {
        guard let mvc = mainViewController else { return }

        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 11)

        // Force dark appearance for menu
        if #available(macOS 10.14, *) {
            menu.appearance = NSAppearance(named: .darkAqua)
        }

        // Add enable/disable toggle
        let isEnabled = mvc.isSelfieEnabled()
        let toggleItem = NSMenuItem(title: isEnabled ? "Disable Selfie Camera" : "Enable Selfie Camera", action: #selector(toggleSelfieCamera), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Add mirror toggle
        let isMirrored = mvc.selfieCameraController.isMirrored
        let mirrorItem = NSMenuItem(title: "Mirror View", action: #selector(toggleSelfieMirror), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = isMirrored ? .on : .off
        menu.addItem(mirrorItem)

        menu.addItem(NSMenuItem.separator())

        // Add camera selection header
        let headerItem = NSMenuItem(title: "Select Camera:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Add available cameras
        let cameras = SelfieCameraController.availableCameraDevices()
        let selectedCamera = mvc.selfieCameraController.selectedCameraDevice
        let defaultFrontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

        for camera in cameras {
            let item = NSMenuItem(title: camera.localizedName, action: #selector(selectSelfieCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = camera
            // Check if this is the selected camera
            if let selected = selectedCamera {
                item.state = camera.uniqueID == selected.uniqueID ? .on : .off
            } else if let defaultCam = defaultFrontCamera, camera.uniqueID == defaultCam.uniqueID {
                item.state = .on // Default camera
            }
            menu.addItem(item)
        }

        // Virtual Background section
        menu.addItem(NSMenuItem.separator())

        let bgHeader = NSMenuItem(title: "Virtual Background:", action: nil, keyEquivalent: "")
        bgHeader.isEnabled = false
        menu.addItem(bgHeader)

        let currentMode = mvc.selfieCameraController.backgroundSettings.mode

        let noneItem = NSMenuItem(title: "No Background", action: #selector(selectVirtualBackground(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.tag = VirtualBackgroundMode.none.rawValue
        noneItem.state = currentMode == .none ? .on : .off
        menu.addItem(noneItem)

        let blurLightItem = NSMenuItem(title: "Blur - Light", action: #selector(selectVirtualBackground(_:)), keyEquivalent: "")
        blurLightItem.target = self
        blurLightItem.tag = VirtualBackgroundMode.blurLight.rawValue
        blurLightItem.state = currentMode == .blurLight ? .on : .off
        menu.addItem(blurLightItem)

        let blurMedItem = NSMenuItem(title: "Blur - Medium", action: #selector(selectVirtualBackground(_:)), keyEquivalent: "")
        blurMedItem.target = self
        blurMedItem.tag = VirtualBackgroundMode.blurMedium.rawValue
        blurMedItem.state = currentMode == .blurMedium ? .on : .off
        menu.addItem(blurMedItem)

        let blurStrongItem = NSMenuItem(title: "Blur - Strong", action: #selector(selectVirtualBackground(_:)), keyEquivalent: "")
        blurStrongItem.target = self
        blurStrongItem.tag = VirtualBackgroundMode.blurStrong.rawValue
        blurStrongItem.state = currentMode == .blurStrong ? .on : .off
        menu.addItem(blurStrongItem)

        menu.addItem(NSMenuItem.separator())

        let solidColorItem = NSMenuItem(title: "Solid Color...", action: #selector(selectSolidColorBackground), keyEquivalent: "")
        solidColorItem.target = self
        solidColorItem.state = currentMode == .solidColor ? .on : .off
        menu.addItem(solidColorItem)

        let customImageItem = NSMenuItem(title: "Custom Image...", action: #selector(selectCustomImageBackground), keyEquivalent: "")
        customImageItem.target = self
        customImageItem.state = currentMode == .customImage ? .on : .off
        menu.addItem(customImageItem)

        // Show the menu below the button
        let location = NSPoint(x: 0, y: sender.bounds.height + 5)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func toggleSelfieCamera() {
        guard let mvc = mainViewController else { return }
        let shouldEnable = !mvc.isSelfieEnabled()
        mvc.setSelfieEnabled(shouldEnable)

        if let selfieBtn = selfieButton {
            selfieBtn.isSelected = shouldEnable
            selfieBtn.layer?.backgroundColor = shouldEnable ?
                NSColor(white: 0.25, alpha: 1.0).cgColor :
                NSColor.clear.cgColor
        }
    }

    @objc private func toggleSelfieMirror() {
        guard let mvc = mainViewController else { return }
        mvc.selfieCameraController.setMirrored(!mvc.selfieCameraController.isMirrored)
    }

    @objc private func selectSelfieCamera(_ sender: NSMenuItem) {
        guard let camera = sender.representedObject as? AVCaptureDevice else { return }
        guard let mvc = mainViewController else { return }

        mvc.selfieCameraController.setSelectedCamera(camera)
        print("AppDelegate: Selected selfie camera: \(camera.localizedName)")
    }

    @objc private func selectVirtualBackground(_ sender: NSMenuItem) {
        guard let mvc = mainViewController else { return }
        guard let mode = VirtualBackgroundMode(rawValue: sender.tag) else { return }
        mvc.selfieCameraController.setVirtualBackground(mode)
        print("AppDelegate: Virtual background set to \(mode)")
    }

    @objc private func selectSolidColorBackground() {
        guard let mvc = mainViewController else { return }

        let colorPanel = NSColorPanel.shared
        colorPanel.mode = .wheel
        colorPanel.showsAlpha = false

        // Set current color if already using solid color
        if let hex = mvc.selfieCameraController.backgroundSettings.colorHex {
            colorPanel.color = NSColor(hex: hex)
        }

        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(solidColorChanged(_:)))
        colorPanel.makeKeyAndOrderFront(nil)

        // Set solid color mode immediately with current color
        let hex = colorPanel.color.toHex()
        mvc.selfieCameraController.setVirtualBackground(.solidColor, colorHex: hex)
    }

    @objc private func solidColorChanged(_ sender: NSColorPanel) {
        guard let mvc = mainViewController else { return }
        let hex = sender.color.toHex()
        mvc.selfieCameraController.setVirtualBackground(.solidColor, colorHex: hex)
    }

    @objc private func selectCustomImageBackground() {
        guard let mvc = mainViewController else { return }

        let settings = mvc.selfieCameraController.backgroundSettings
        let picker = BackgroundImagePickerWindow(
            currentMode: settings.mode,
            currentBundledIndex: settings.bundledImageIndex,
            currentBookmark: settings.imageBookmark
        )
        // Live preview — apply immediately on tile click
        let applyBackground: (VirtualBackgroundMode, Data?, Int?) -> Void = { [weak self] mode, bookmark, bundledIndex in
            guard let mvc = self?.mainViewController else { return }
            if let bookmark = bookmark {
                BackgroundImageBookmarkStore.addBookmark(bookmark)
                mvc.selfieCameraController.setVirtualBackground(mode, imageBookmark: bookmark)
            } else if let index = bundledIndex {
                mvc.selfieCameraController.setVirtualBackground(mode, bundledImageIndex: index)
            } else {
                mvc.selfieCameraController.setVirtualBackground(mode)
            }
        }
        picker.onPreviewBackground = applyBackground
        // Save — preview already applied, just log
        picker.onBackgroundSelected = { mode, bookmark, bundledIndex in
            if let index = bundledIndex {
                print("AppDelegate: Bundled background \(index) saved from picker")
            } else if bookmark != nil {
                print("AppDelegate: Custom background image saved from picker")
            }
        }
        // Cancel — revert to original settings
        picker.onCancelled = applyBackground
        picker.makeKeyAndOrderFront(nil)
        backgroundPickerWindow = picker
    }

    // MARK: - Microphone Actions
    @objc private func microphoneButtonClicked(_ sender: NSButton) {
        showMicrophoneMenu(sender)
    }

    private func showMicrophoneMenu(_ sender: NSButton) {
        guard let mvc = mainViewController else { return }

        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 11)

        // Force dark appearance for menu
        if #available(macOS 10.14, *) {
            menu.appearance = NSAppearance(named: .darkAqua)
        }

        // Add "Off" option
        let offItem = NSMenuItem(title: "Off (No Microphone)", action: #selector(selectNoMicrophone), keyEquivalent: "")
        offItem.target = self
        offItem.state = !mvc.isMicrophoneEnabled ? .on : .off
        menu.addItem(offItem)

        menu.addItem(NSMenuItem.separator())

        // Add header
        let headerItem = NSMenuItem(title: "Select Microphone:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Add available audio devices
        let devices = ScreenRecorderNew.availableAudioDevices()
        let selectedDevice = mvc.selectedAudioDevice
        let defaultDevice = AVCaptureDevice.default(for: .audio)

        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(selectMicrophoneDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            // Check if this is the selected device
            if mvc.isMicrophoneEnabled {
                if let selected = selectedDevice {
                    item.state = device.uniqueID == selected.uniqueID ? .on : .off
                } else if let defaultDev = defaultDevice, device.uniqueID == defaultDev.uniqueID {
                    item.state = .on // Default device
                }
            }
            menu.addItem(item)
        }

        // Show the menu below the button
        let location = NSPoint(x: 0, y: sender.bounds.height + 5)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func selectNoMicrophone() {
        guard let mvc = mainViewController else { return }
        mvc.setMicrophoneEnabled(false, device: nil)
        updateMicrophoneButtonState()
        print("AppDelegate: Microphone disabled")
    }

    @objc private func selectMicrophoneDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        guard let mvc = mainViewController else { return }

        mvc.setMicrophoneEnabled(true, device: device)
        updateMicrophoneButtonState()
        print("AppDelegate: Selected microphone: \(device.localizedName)")
    }

    private func updateMicrophoneButtonState() {
        guard let mvc = mainViewController else {
            print("AppDelegate: updateMicrophoneButtonState - mainViewController is nil")
            return
        }
        let isEnabled = mvc.isMicrophoneEnabled
        print("AppDelegate: updateMicrophoneButtonState - isEnabled=\(isEnabled), device=\(mvc.selectedAudioDevice?.localizedName ?? "default")")

        microphoneButton?.isSelected = isEnabled
        microphoneButton?.layer?.backgroundColor = isEnabled ?
            NSColor(white: 0.25, alpha: 1.0).cgColor :
            NSColor.clear.cgColor

        // Update icon
        let symbolName = isEnabled ? "mic.fill" : "mic.slash.fill"
        if let micImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Microphone") {
            micImage.isTemplate = true
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            microphoneIconView?.image = micImage.withSymbolConfiguration(config)
        }

        // Update label
        if isEnabled {
            let deviceName = mvc.selectedAudioDevice?.localizedName ?? "Mic On"
            let displayName = deviceName.count > 8 ? String(deviceName.prefix(6)) + "…" : deviceName
            microphoneLabel?.stringValue = displayName
        } else {
            microphoneLabel?.stringValue = "Mic Off"
        }
    }

    // MARK: - Cursor Mode Actions
    @objc private func cursorModeButtonClicked(_ sender: NSButton) {
        showCursorModeMenu(sender)
    }

    private func showCursorModeMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 11)

        if #available(macOS 10.14, *) {
            menu.appearance = NSAppearance(named: .darkAqua)
        }

        let normalItem = NSMenuItem(title: "Normal", action: #selector(cursorModeSelected(_:)), keyEquivalent: "")
        normalItem.target = self
        normalItem.tag = 0
        normalItem.state = (currentCursorMode == 0) ? .on : .off
        menu.addItem(normalItem)

        let highlightItem = NSMenuItem(title: "Click Highlight", action: #selector(cursorModeSelected(_:)), keyEquivalent: "")
        highlightItem.target = self
        highlightItem.tag = 1
        highlightItem.state = (currentCursorMode == 1) ? .on : .off
        menu.addItem(highlightItem)

        let bigPointerItem = NSMenuItem(title: "Big Pointer", action: #selector(cursorModeSelected(_:)), keyEquivalent: "")
        bigPointerItem.target = self
        bigPointerItem.tag = 2
        bigPointerItem.state = (currentCursorMode == 2) ? .on : .off
        menu.addItem(bigPointerItem)

        let location = NSPoint(x: 0, y: sender.bounds.height + 5)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func cursorModeSelected(_ sender: NSMenuItem) {
        currentCursorMode = sender.tag
        UserDefaults.standard.set(currentCursorMode, forKey: "cursorOverlayMode")
        updateCursorButtonState()

        // Sync with MainViewController
        if let mvc = mainViewController {
            mvc.setCursorOverlayMode(CursorOverlayMode(rawValue: currentCursorMode) ?? .normal)
        }

        print("AppDelegate: Cursor mode selected: \(sender.title) (mode: \(currentCursorMode))")
    }

    private func updateCursorButtonState() {
        let isActive = currentCursorMode != 0
        cursorButton?.isSelected = isActive
        cursorButton?.layer?.backgroundColor = isActive ?
            NSColor(white: 0.25, alpha: 1.0).cgColor :
            NSColor.clear.cgColor

        switch currentCursorMode {
        case 0:
            cursorLabel?.stringValue = "Normal"
        case 1:
            cursorLabel?.stringValue = "Highlight"
        case 2:
            cursorLabel?.stringValue = "Big Ptr"
        default:
            cursorLabel?.stringValue = "Cursor"
        }
    }

    @objc private func showZoomMenu(_ sender: NSButton) {
        // Create menu with dark styling
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 11)

        // Force dark appearance for menu
        if #available(macOS 10.14, *) {
            menu.appearance = NSAppearance(named: .darkAqua)
        }

        let noZoomItem = NSMenuItem(title: "No zoom", action: #selector(zoomModeSelected(_:)), keyEquivalent: "")
        noZoomItem.target = self
        noZoomItem.tag = 0
        noZoomItem.state = (currentZoomMode == 0) ? .on : .off
        menu.addItem(noZoomItem)

        let zoomInOutItem = NSMenuItem(title: "Zoom in/out", action: #selector(zoomModeSelected(_:)), keyEquivalent: "")
        zoomInOutItem.target = self
        zoomInOutItem.tag = 1
        zoomInOutItem.state = (currentZoomMode == 1) ? .on : .off
        menu.addItem(zoomInOutItem)

        let followMouseItem = NSMenuItem(title: "Follow mouse zoom", action: #selector(zoomModeSelected(_:)), keyEquivalent: "")
        followMouseItem.target = self
        followMouseItem.tag = 2
        followMouseItem.state = (currentZoomMode == 2) ? .on : .off
        menu.addItem(followMouseItem)

        // Show menu below button
        let buttonFrame = sender.frame
        let menuOrigin = NSPoint(x: buttonFrame.origin.x, y: buttonFrame.origin.y - 5)
        menu.popUp(positioning: nil, at: menuOrigin, in: sender.superview)
    }

    @objc private func zoomModeSelected(_ sender: NSMenuItem) {
        let selectedMode = sender.tag

        // Update current zoom mode
        currentZoomMode = selectedMode

        // Save to UserDefaults for persistence
        UserDefaults.standard.set(selectedMode, forKey: "zoomMode")

        print("Zoom mode selected: \(sender.title) (mode: \(selectedMode))")

        // Update the zoom button label
        updateZoomLabel()

        // TODO: When MainViewController integration happens, update its zoomMode property here
        // Example: mainViewController?.zoomMode = ZoomMode(rawValue: selectedMode) ?? .noZoom
    }

    private func updateZoomLabel() {
        // Update the zoom button label based on current zoom mode
        switch currentZoomMode {
        case 0:
            zoomLabel?.stringValue = "No Zoom"
        case 1:
            zoomLabel?.stringValue = "Zoom In/Out"
        case 2:
            zoomLabel?.stringValue = "Following"
        default:
            zoomLabel?.stringValue = "Zoom"
        }

        // Force label to refresh
        zoomLabel?.needsDisplay = true
        print("AppDelegate: Updated zoom label to '\(zoomLabel?.stringValue ?? "nil")'")
    }

    private func setupDragMonitor(for window: NSWindow) {
        // Simple drag monitor - only works on empty space, not on buttons
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self, weak window] event in
            guard let self = self, let window = window else { return event }
            guard event.window == window else { return event }

            if event.type == .leftMouseDown {
                self.initialMouseLocation = NSEvent.mouseLocation
                self.initialWindowOrigin = window.frame.origin
            } else if event.type == .leftMouseDragged {
                if let initialMouse = self.initialMouseLocation,
                   let initialOrigin = self.initialWindowOrigin {
                    let currentMouse = NSEvent.mouseLocation
                    let deltaX = currentMouse.x - initialMouse.x
                    let deltaY = currentMouse.y - initialMouse.y

                    if abs(deltaX) > 3 || abs(deltaY) > 3 {
                        let newOrigin = NSPoint(
                            x: initialOrigin.x + deltaX,
                            y: initialOrigin.y + deltaY
                        )
                        window.setFrameOrigin(newOrigin)
                    }
                }
            }

            return event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Simple check - if we're tracking that recording is active, block quit
        if isRecordingActive {
            print("AppDelegate: Recording in progress, showing confirmation dialog")

            let alert = NSAlert()
            alert.messageText = "Recording in Progress"
            alert.informativeText = "Quitting now will corrupt the current recording. Stop recording first using the menu bar icon."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // User chose "Cancel"
                return .terminateCancel
            }
            // User chose "Quit Anyway" - allow quit even though recording will be corrupted
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("AppDelegate: App terminating - cleaning up")
        // Clean up - just close preview window, don't change saved preference
        mainViewController?.selfieCameraController.closePreviewWindow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep app running for menu bar mode during recording
    }
}

// Simple draggable view
class SimpleDraggableView: NSView {
    // Dragging is now handled by AppDelegate's event monitor
    // This allows dragging even when clicking on buttons
}

// Non-interactive view that passes all mouse events through
class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let subviews handle hit testing, but if they return nil, we also return nil
        if let hitView = super.hitTest(point), hitView != self {
            return hitView
        }
        return nil
    }
}

// Non-interactive image view that passes all mouse events through
class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always return nil so mouse events pass through to views below
        return nil
    }
}

// Non-interactive text field that passes all mouse events through
class PassThroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always return nil so mouse events pass through to views below
        return nil
    }
}
