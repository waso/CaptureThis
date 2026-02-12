import Cocoa
import AVFoundation
import AVKit
import CoreGraphics

// Keep old enum for compatibility with VideoProcessor
enum TrackingMode: Int {
    case zoomOnClicks = 0
    case followCursor = 1
    case recordWindow = 2
}

enum ZoomMode: Int {
    case noZoom = 0
    case zoomOnClick = 1
    case followCursor = 2
}

enum RecordingMode: Int {
    case fullScreen = 0
    case selectedWindow = 1
}

class MainViewController: NSViewController {
    // UI Elements
    private var closeButton: NSButton!
    private var resolutionPopup: NSPopUpButton!
    private var fpsPopup: NSPopUpButton!

    // Zoom effect buttons (Group 1) - now containers with icon + label
    private var noZoomButton: ButtonContainer!
    private var zoomOnClickButton: ButtonContainer!
    private var followCursorButton: ButtonContainer!

    // Recording mode buttons (Group 2) - now containers with icon + label
    private var fullScreenButton: ButtonContainer!
    private var selectedWindowButton: ButtonContainer!

    // Speech-to-text button - now container with icon + label
    private var speechToTextButton: ButtonContainer!

    // Microphone button - with mute/unmute and device selection
    private var microphoneButton: ButtonContainer!

    private var leftSeparatorLine: NSView!
    private var middleSeparatorLine: NSView!
    private var rightSeparatorLine: NSView!
    private var separator2: NSView!
    private var separator3: NSView!
    private var separator4: NSView!  // Between zoom and recording mode groups
    private var timerLabel: NSTextField!
    private var recordButton: NSButton!
    private var stopButton: NSButton!
    private var recordLabel: NSTextField!
    private var stopLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var completionLabel: NSTextField!

    // Video Editor UI (integrated)
    private var editorContainerView: NSView!
    private var playerView: NSView!
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserverToken: Any?
    private var playPauseButton: NSButton!
    private var timelineSlider: NSSlider!
    private var currentTimeLabel: NSTextField!
    private var totalTimeLabel: NSTextField!
    private var trimStartSlider: NSSlider!
    private var trimEndSlider: NSSlider!
    private var trimStartLabel: NSTextField!
    private var trimEndLabel: NSTextField!
    private var canvasColorWell: NSColorWell!
    private var canvasColorLabel: NSTextField!
    private var exportEditedButton: NSButton!
    private var exportEditProgressIndicator: NSProgressIndicator!
    private var backToRecordingButton: NSButton!

    // Recording state
    private var lastExportedVideoURL: URL?
    private var videoAsset: AVAsset?
    private var videoDuration: CMTime = .zero
    private var trimStartTime: CMTime = .zero
    private var trimEndTime: CMTime = .zero
    private var isInEditorMode: Bool = false
    private var screenRecorder: ScreenRecorderNew?
    private var clickTracker: ClickTrackerNew?
    private var cursorTracker: CursorTrackerNew?
    private var drawingOverlay: DrawingOverlay?
    private var speechRecognizer: AppleSpeechRecognizer?
    private var subtitleOverlay: SubtitleOverlay?
    private var recordingStartTime: Date?
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0
    private var timerUpdateTimer: Timer?
    private var blinkTimer: Timer?
    private var menuBarEnsureVisibleTimer: Timer?
    private var menuBarBlinkTimer: Timer?
    private var clickCount: Int = 0
    private var zoomMode: ZoomMode = .noZoom  // Default to no zoom until compositor is fixed
    private var recordingMode: RecordingMode = .fullScreen
    private var selectedFPS: Int = 60
    private var selectedWindowID: CGWindowID?
    private var selectedWindowName: String?
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var selectedDisplayName: String?
    private var isRecording: Bool = false
    private var isPaused: Bool = false
    private var hasRecordedVideo: Bool = false
    private var isSpeechToTextEnabled: Bool = false
    private var windowSelector: MissionControlWindowSelector?  // Strong reference to prevent premature deallocation

    var selfieCameraController = SelfieCameraController()
    private var isSelfieEnabledFlag: Bool = false
    private var selfieVideoURL: URL?
    private var selfieOverlayEvents: [SelfieOverlayEvent] = []
    private var selfieStartOffset: TimeInterval = 0

    // Microphone state
    private(set) var isMicrophoneEnabled: Bool = true
    private(set) var selectedAudioDevice: AVCaptureDevice?

    // Menu bar item
    private var statusItem: NSStatusItem?
    private var menuBarMenu: NSMenu?
    private var normalRedCircleImage: NSImage?
    private var fadedRedCircleImage: NSImage?

    // Window recording indicator (overlay on recorded window)
    private var windowIndicatorOverlay: NSWindow?
    private var windowIndicatorImageView: NSImageView?
    private var windowIndicatorBlinkTimer: Timer?
    private var recordedWindowID: CGWindowID?
    private var windowPositionMonitor: Timer?
    private var menuBarVisibilityMonitor: Timer?

    // Floating recording indicator (backup when menu bar not visible)
    private var floatingIndicator: FloatingRecordingIndicator?

    override func loadView() {
        // Create draggable main view with compact height for recording controls
        let mainView = DraggableView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        print("MainViewController: loadView - Created view with frame: \(mainView.frame)")
        mainView.translatesAutoresizingMaskIntoConstraints = true
        mainView.autoresizingMask = []
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0).cgColor
        mainView.layer?.cornerRadius = 12
        self.view = mainView
        print("MainViewController: loadView - Set self.view, frame: \(self.view.frame)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Load saved recording mode
        loadRecordingModePreference()

        // Restore selfie enabled state
        let enabled = selfieCameraController.restoreEnabledState()
        isSelfieEnabledFlag = enabled
        if enabled {
            selfieCameraController.setEnabled(true)
        }

        // Restore microphone settings
        restoreMicrophoneSettings()

        // Restore selected display
        restoreSelectedDisplay()

        setupUI()

        // Update microphone button state after UI is created
        updateMicrophoneButtonState()

        // Debug: Print final microphone state
        print("MainViewController: viewDidLoad complete - isMicrophoneEnabled=\(isMicrophoneEnabled), selectedAudioDevice=\(selectedAudioDevice?.localizedName ?? "nil (will use default)")")
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Force window size after everything is loaded
        if let window = view.window {
            print("MainViewController: viewDidAppear - Current window frame: \(window.frame)")
            let currentOrigin = window.frame.origin
            window.setFrame(NSRect(x: currentOrigin.x, y: currentOrigin.y, width: 1000, height: 300), display: true)
            print("MainViewController: viewDidAppear - After setFrame: \(window.frame)")

            // Also set it again with a delay to override anything else
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.setFrame(NSRect(x: currentOrigin.x, y: currentOrigin.y, width: 1000, height: 300), display: true)
                print("MainViewController: viewDidAppear delayed - Final window frame: \(window.frame)")
            }
        }
    }

    private func setupUI() {
        // Enable instant tooltips (no delay)
        UserDefaults.standard.set(0.0, forKey: "NSInitialToolTipDelay")

        createContainerView()
    }

    private func createContainerView() {
        // SIMPLIFIED UI - Always record at 4K/60fps
        // Use floating indicator for timer and stop button

        // Close button (X)
        closeButton = createIconButton(title: "✕", size: 40)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        view.addSubview(closeButton)

        // Left separator (thin, with margins)
        leftSeparatorLine = NSView()
        leftSeparatorLine.wantsLayer = true
        leftSeparatorLine.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.3).cgColor
        view.addSubview(leftSeparatorLine)

        // Resolution/FPS popups - HIDDEN (always use 4K/60fps)
        resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        resolutionPopup.addItems(withTitles: ["4K"])
        resolutionPopup.selectItem(at: 0)
        resolutionPopup.isHidden = true
        view.addSubview(resolutionPopup)

        fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["60 FPS"])
        fpsPopup.selectItem(at: 0)
        fpsPopup.isHidden = true
        view.addSubview(fpsPopup)

        // Separator 2 (thin, with margins)
        separator2 = NSView()
        separator2.wantsLayer = true
        separator2.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.3).cgColor
        view.addSubview(separator2)

        separator3 = NSView()
        separator3.wantsLayer = true
        separator3.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.3).cgColor
        view.addSubview(separator3)

        // GROUP 1: Zoom Effect Buttons
        noZoomButton = createModeButton(title: "○", tooltip: "No Zoom")
        noZoomButton.button?.target = self
        noZoomButton.button?.action = #selector(noZoomSelected)
        view.addSubview(noZoomButton)

        zoomOnClickButton = createModeButton(title: "◉", tooltip: "Zoom on Clicks")
        zoomOnClickButton.button?.target = self
        zoomOnClickButton.button?.action = #selector(zoomOnClickSelected)
        view.addSubview(zoomOnClickButton)

        followCursorButton = createModeButton(title: "◎", tooltip: "Follow Cursor")
        followCursorButton.button?.target = self
        followCursorButton.button?.action = #selector(followCursorSelected)
        view.addSubview(followCursorButton)

        // Separator 4 (between zoom effect and recording mode groups)
        separator4 = NSView()
        separator4.wantsLayer = true
        separator4.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        view.addSubview(separator4)

        // GROUP 2: Recording Mode Buttons
        fullScreenButton = createModeButton(title: "□", tooltip: "Display")
        fullScreenButton.button?.target = self
        fullScreenButton.button?.action = #selector(fullScreenSelected)
        view.addSubview(fullScreenButton)

        selectedWindowButton = createModeButton(title: "▢", tooltip: "Window")
        selectedWindowButton.button?.target = self
        selectedWindowButton.button?.action = #selector(selectedWindowSelected)
        view.addSubview(selectedWindowButton)

        // Speech-to-text button
        speechToTextButton = createModeButton(title: "🎤", tooltip: "Subtitles")
        speechToTextButton.button?.target = self
        speechToTextButton.button?.action = #selector(speechToTextToggled)
        view.addSubview(speechToTextButton)

        // Microphone button (click shows device selection menu)
        microphoneButton = createModeButton(title: "🎙️", tooltip: "Mic On")
        microphoneButton.button?.target = self
        microphoneButton.button?.action = #selector(microphoneButtonClicked)
        view.addSubview(microphoneButton)

        // Right separator line (after recording mode buttons)
        rightSeparatorLine = NSView()
        rightSeparatorLine.wantsLayer = true
        rightSeparatorLine.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        view.addSubview(rightSeparatorLine)

        // Set initial selection
        updateButtonStates()
        updateZoomButtonLabels()

        // Timer label - HIDDEN (using floating indicator instead)
        timerLabel = createLabel(text: "00:00", fontSize: 16, weight: .medium, color: .white)
        timerLabel.alignment = .center
        timerLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        timerLabel.isHidden = true
        view.addSubview(timerLabel)

        // Record button (red circle with white border)
        recordButton = NSButton()
        recordButton.title = ""
        recordButton.isBordered = false
        recordButton.wantsLayer = true
        recordButton.layer?.backgroundColor = NSColor(red: 0.95, green: 0.27, blue: 0.23, alpha: 1.0).cgColor
        recordButton.layer?.cornerRadius = 16  // Circle (32/2)
        recordButton.layer?.borderWidth = 2
        recordButton.layer?.borderColor = NSColor.white.cgColor
        recordButton.target = self
        recordButton.action = #selector(startRecording)
        view.addSubview(recordButton)

        // Stop button - HIDDEN (using floating indicator instead)
        stopButton = NSButton()
        stopButton.title = ""
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0).cgColor
        stopButton.layer?.cornerRadius = 5
        stopButton.layer?.borderWidth = 2
        stopButton.layer?.borderColor = NSColor.white.cgColor
        stopButton.target = self
        stopButton.action = #selector(stopRecording)
        stopButton.isHidden = true
        view.addSubview(stopButton)

        // Labels under buttons (hidden)
        recordLabel = createLabel(text: "", fontSize: 9, weight: .regular, color: NSColor(white: 0.7, alpha: 1.0))
        recordLabel.isHidden = true
        view.addSubview(recordLabel)

        stopLabel = createLabel(text: "", fontSize: 9, weight: .regular, color: NSColor(white: 0.7, alpha: 1.0))
        stopLabel.isHidden = true
        view.addSubview(stopLabel)

        // Progress bar (hidden by default) - next to timer during export
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true

        // Style the progress bar with distinct colors
        progressIndicator.wantsLayer = true
        progressIndicator.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor  // Dark gray background
        progressIndicator.layer?.cornerRadius = 4
        view.addSubview(progressIndicator)

        // Completion label (shown after export completes)
        completionLabel = createLabel(text: "✓ Completed", fontSize: 13, weight: .semibold, color: NSColor.systemGreen)
        completionLabel.isHidden = true
        view.addSubview(completionLabel)

        // Setup video editor UI (hidden initially)
        setupVideoEditorUI()

        // Layout constraints
        layoutViews()
    }

    private func setupVideoEditorUI() {
        // Container for all editor UI (hidden initially, shown after recording)
        editorContainerView = NSView()
        editorContainerView.wantsLayer = true
        editorContainerView.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0).cgColor
        editorContainerView.isHidden = true
        view.addSubview(editorContainerView)

        // Video player view
        playerView = NSView()
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        editorContainerView.addSubview(playerView)

        // Playback controls
        playPauseButton = NSButton()
        playPauseButton.title = "▶"
        playPauseButton.bezelStyle = .rounded
        playPauseButton.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)
        editorContainerView.addSubview(playPauseButton)

        // Time labels
        currentTimeLabel = createLabel(text: "00:00", fontSize: 13, weight: .medium, color: .white)
        totalTimeLabel = createLabel(text: "00:00", fontSize: 13, weight: .medium, color: .white)
        editorContainerView.addSubview(currentTimeLabel)
        editorContainerView.addSubview(totalTimeLabel)

        // Timeline slider
        timelineSlider = NSSlider()
        timelineSlider.minValue = 0
        timelineSlider.maxValue = 100
        timelineSlider.doubleValue = 0
        timelineSlider.target = self
        timelineSlider.action = #selector(timelineSliderChanged)
        editorContainerView.addSubview(timelineSlider)

        // Trim controls
        let trimTitleLabel = createLabel(text: "Trim Video", fontSize: 14, weight: .semibold, color: .white)
        editorContainerView.addSubview(trimTitleLabel)

        trimStartLabel = createLabel(text: "Start: 00:00", fontSize: 12, weight: .regular, color: NSColor(white: 0.8, alpha: 1.0))
        editorContainerView.addSubview(trimStartLabel)

        trimStartSlider = NSSlider()
        trimStartSlider.minValue = 0
        trimStartSlider.maxValue = 100
        trimStartSlider.doubleValue = 0
        trimStartSlider.target = self
        trimStartSlider.action = #selector(trimStartChanged)
        editorContainerView.addSubview(trimStartSlider)

        trimEndLabel = createLabel(text: "End: 00:00", fontSize: 12, weight: .regular, color: NSColor(white: 0.8, alpha: 1.0))
        editorContainerView.addSubview(trimEndLabel)

        trimEndSlider = NSSlider()
        trimEndSlider.minValue = 0
        trimEndSlider.maxValue = 100
        trimEndSlider.doubleValue = 100
        trimEndSlider.target = self
        trimEndSlider.action = #selector(trimEndChanged)
        editorContainerView.addSubview(trimEndSlider)

        // Canvas color controls
        canvasColorLabel = createLabel(text: "Canvas Color:", fontSize: 14, weight: .semibold, color: .white)
        editorContainerView.addSubview(canvasColorLabel)

        canvasColorWell = NSColorWell()
        canvasColorWell.color = .black
        canvasColorWell.isBordered = true
        editorContainerView.addSubview(canvasColorWell)

        // Export button
        exportEditedButton = NSButton()
        exportEditedButton.title = "Export Edited Video"
        exportEditedButton.bezelStyle = .rounded
        exportEditedButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        exportEditedButton.target = self
        exportEditedButton.action = #selector(exportEditedVideo)
        editorContainerView.addSubview(exportEditedButton)

        // Export progress indicator
        exportEditProgressIndicator = NSProgressIndicator()
        exportEditProgressIndicator.style = .bar
        exportEditProgressIndicator.isIndeterminate = false
        exportEditProgressIndicator.minValue = 0
        exportEditProgressIndicator.maxValue = 100
        exportEditProgressIndicator.isHidden = true
        editorContainerView.addSubview(exportEditProgressIndicator)

        // Back to recording button
        backToRecordingButton = NSButton()
        backToRecordingButton.title = "← Back to Recording"
        backToRecordingButton.bezelStyle = .rounded
        backToRecordingButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        backToRecordingButton.target = self
        backToRecordingButton.action = #selector(backToRecording)
        editorContainerView.addSubview(backToRecordingButton)

        // Store reference to trim title label for constraints
        trimTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Layout editor UI
        layoutEditorUI(trimTitleLabel: trimTitleLabel)
    }

    @objc private func closeWindow() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func fpsChanged() {
        let fpsValues = [60, 30, 24]
        selectedFPS = fpsValues[fpsPopup.indexOfSelectedItem]
    }

    private func layoutEditorUI(trimTitleLabel: NSTextField) {
        [editorContainerView, playerView, playPauseButton, timelineSlider, currentTimeLabel, totalTimeLabel,
         trimStartSlider, trimEndSlider, trimStartLabel, trimEndLabel, canvasColorWell, canvasColorLabel,
         exportEditedButton, exportEditProgressIndicator, backToRecordingButton].forEach {
            $0?.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // Editor container (below main controls, full width)
            editorContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorContainerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            editorContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Video player (top of editor container)
            playerView.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            playerView.trailingAnchor.constraint(equalTo: editorContainerView.trailingAnchor, constant: -20),
            playerView.topAnchor.constraint(equalTo: editorContainerView.topAnchor, constant: 20),
            playerView.heightAnchor.constraint(equalToConstant: 400),

            // Playback controls
            playPauseButton.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            playPauseButton.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 15),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 32),

            currentTimeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            currentTimeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 50),

            timelineSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 8),
            timelineSlider.trailingAnchor.constraint(equalTo: totalTimeLabel.leadingAnchor, constant: -8),
            timelineSlider.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            totalTimeLabel.trailingAnchor.constraint(equalTo: editorContainerView.trailingAnchor, constant: -20),
            totalTimeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            totalTimeLabel.widthAnchor.constraint(equalToConstant: 50),

            // Trim controls
            trimTitleLabel.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            trimTitleLabel.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 20),

            trimStartLabel.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            trimStartLabel.topAnchor.constraint(equalTo: trimTitleLabel.bottomAnchor, constant: 12),
            trimStartLabel.widthAnchor.constraint(equalToConstant: 90),

            trimStartSlider.leadingAnchor.constraint(equalTo: trimStartLabel.trailingAnchor, constant: 8),
            trimStartSlider.trailingAnchor.constraint(equalTo: editorContainerView.trailingAnchor, constant: -20),
            trimStartSlider.centerYAnchor.constraint(equalTo: trimStartLabel.centerYAnchor),

            trimEndLabel.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            trimEndLabel.topAnchor.constraint(equalTo: trimStartLabel.bottomAnchor, constant: 15),
            trimEndLabel.widthAnchor.constraint(equalToConstant: 90),

            trimEndSlider.leadingAnchor.constraint(equalTo: trimEndLabel.trailingAnchor, constant: 8),
            trimEndSlider.trailingAnchor.constraint(equalTo: editorContainerView.trailingAnchor, constant: -20),
            trimEndSlider.centerYAnchor.constraint(equalTo: trimEndLabel.centerYAnchor),

            // Canvas color
            canvasColorLabel.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            canvasColorLabel.topAnchor.constraint(equalTo: trimEndLabel.bottomAnchor, constant: 20),

            canvasColorWell.leadingAnchor.constraint(equalTo: canvasColorLabel.trailingAnchor, constant: 8),
            canvasColorWell.centerYAnchor.constraint(equalTo: canvasColorLabel.centerYAnchor),
            canvasColorWell.widthAnchor.constraint(equalToConstant: 50),
            canvasColorWell.heightAnchor.constraint(equalToConstant: 26),

            // Export button
            exportEditedButton.centerXAnchor.constraint(equalTo: editorContainerView.centerXAnchor),
            exportEditedButton.topAnchor.constraint(equalTo: canvasColorLabel.bottomAnchor, constant: 25),
            exportEditedButton.widthAnchor.constraint(equalToConstant: 180),
            exportEditedButton.heightAnchor.constraint(equalToConstant: 36),

            // Export progress
            exportEditProgressIndicator.centerXAnchor.constraint(equalTo: editorContainerView.centerXAnchor),
            exportEditProgressIndicator.topAnchor.constraint(equalTo: exportEditedButton.bottomAnchor, constant: 12),
            exportEditProgressIndicator.widthAnchor.constraint(equalToConstant: 250),

            // Back to recording button
            backToRecordingButton.leadingAnchor.constraint(equalTo: editorContainerView.leadingAnchor, constant: 20),
            backToRecordingButton.bottomAnchor.constraint(equalTo: editorContainerView.bottomAnchor, constant: -15),
            backToRecordingButton.widthAnchor.constraint(equalToConstant: 160),
            backToRecordingButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func layoutViews() {
        [closeButton, leftSeparatorLine, resolutionPopup, separator2, fpsPopup, separator3,
         noZoomButton, zoomOnClickButton, followCursorButton, separator4,
         fullScreenButton, selectedWindowButton, speechToTextButton, microphoneButton, rightSeparatorLine,
         timerLabel, recordButton, stopButton, recordLabel, stopLabel, progressIndicator, completionLabel].forEach {
            $0?.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // Close button (left side)
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 50),
            closeButton.heightAnchor.constraint(equalToConstant: 50),

            // Left separator line - with margins
            leftSeparatorLine.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            leftSeparatorLine.topAnchor.constraint(equalTo: view.topAnchor, constant: 25),
            leftSeparatorLine.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -25),
            leftSeparatorLine.widthAnchor.constraint(equalToConstant: 1),

            // Resolution popup - full height
            resolutionPopup.leadingAnchor.constraint(equalTo: leftSeparatorLine.trailingAnchor, constant: 0),
            resolutionPopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            resolutionPopup.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
            resolutionPopup.widthAnchor.constraint(equalToConstant: 75),

            // Separator 2 - with margins
            separator2.leadingAnchor.constraint(equalTo: leftSeparatorLine.trailingAnchor, constant: 0),
            separator2.topAnchor.constraint(equalTo: view.topAnchor, constant: 25),
            separator2.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -25),
            separator2.widthAnchor.constraint(equalToConstant: 1),

            // FPS popup - full height
            fpsPopup.leadingAnchor.constraint(equalTo: separator2.trailingAnchor, constant: 8),
            fpsPopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            fpsPopup.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
            fpsPopup.widthAnchor.constraint(equalToConstant: 90),

            // Separator 3 - with margins
            separator3.leadingAnchor.constraint(equalTo: separator2.trailingAnchor, constant: 0),
            separator3.topAnchor.constraint(equalTo: view.topAnchor, constant: 25),
            separator3.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -25),
            separator3.widthAnchor.constraint(equalToConstant: 1),

            // GROUP 1: Zoom Effect Buttons (containers with icon + label)
            noZoomButton.leadingAnchor.constraint(equalTo: separator3.trailingAnchor, constant: 12),
            noZoomButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            noZoomButton.widthAnchor.constraint(equalToConstant: 80),
            noZoomButton.heightAnchor.constraint(equalToConstant: 80),

            zoomOnClickButton.leadingAnchor.constraint(equalTo: noZoomButton.trailingAnchor, constant: 15),
            zoomOnClickButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            zoomOnClickButton.widthAnchor.constraint(equalToConstant: 80),
            zoomOnClickButton.heightAnchor.constraint(equalToConstant: 80),

            followCursorButton.leadingAnchor.constraint(equalTo: zoomOnClickButton.trailingAnchor, constant: 15),
            followCursorButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            followCursorButton.widthAnchor.constraint(equalToConstant: 80),
            followCursorButton.heightAnchor.constraint(equalToConstant: 80),

            // Separator 4 - with margins
            separator4.leadingAnchor.constraint(equalTo: followCursorButton.trailingAnchor, constant: 8),
            separator4.topAnchor.constraint(equalTo: view.topAnchor, constant: 25),
            separator4.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -25),
            separator4.widthAnchor.constraint(equalToConstant: 1),

            // GROUP 2: Recording Mode Buttons (containers with icon + label)
            fullScreenButton.leadingAnchor.constraint(equalTo: separator4.trailingAnchor, constant: 12),
            fullScreenButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            fullScreenButton.widthAnchor.constraint(equalToConstant: 80),
            fullScreenButton.heightAnchor.constraint(equalToConstant: 80),

            selectedWindowButton.leadingAnchor.constraint(equalTo: fullScreenButton.trailingAnchor, constant: 15),
            selectedWindowButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            selectedWindowButton.widthAnchor.constraint(equalToConstant: 80),
            selectedWindowButton.heightAnchor.constraint(equalToConstant: 80),

            // Speech-to-text button (container with icon + label)
            speechToTextButton.leadingAnchor.constraint(equalTo: selectedWindowButton.trailingAnchor, constant: 15),
            speechToTextButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            speechToTextButton.widthAnchor.constraint(equalToConstant: 80),
            speechToTextButton.heightAnchor.constraint(equalToConstant: 80),

            // Microphone button (container with icon + label)
            microphoneButton.leadingAnchor.constraint(equalTo: speechToTextButton.trailingAnchor, constant: 15),
            microphoneButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            microphoneButton.widthAnchor.constraint(equalToConstant: 80),
            microphoneButton.heightAnchor.constraint(equalToConstant: 80),

            // Right separator line (after recording mode buttons) - with margins
            rightSeparatorLine.leadingAnchor.constraint(equalTo: microphoneButton.trailingAnchor, constant: 12),
            rightSeparatorLine.topAnchor.constraint(equalTo: view.topAnchor, constant: 25),
            rightSeparatorLine.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -25),
            rightSeparatorLine.widthAnchor.constraint(equalToConstant: 1),

            // Timer (hidden)
            timerLabel.leadingAnchor.constraint(equalTo: rightSeparatorLine.trailingAnchor, constant: 24),
            timerLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            timerLabel.widthAnchor.constraint(equalToConstant: 80),

            // Stop button (hidden)
            stopButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stopButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 48),
            stopButton.heightAnchor.constraint(equalToConstant: 48),

            // Record button (right after separator, remove unused space)
            recordButton.leadingAnchor.constraint(equalTo: rightSeparatorLine.trailingAnchor, constant: 16),
            recordButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 48),
            recordButton.heightAnchor.constraint(equalToConstant: 48),
            recordButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Progress bar (next to timer, only visible during export)
            // Uses flexible width to fit available space between timer and record button
            progressIndicator.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: 8),
            progressIndicator.trailingAnchor.constraint(equalTo: recordButton.leadingAnchor, constant: -12),
            progressIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),

            // Completion label (same position as progress bar, shown after export)
            completionLabel.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: 8),
            completionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            // Record label (hidden)
            recordLabel.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
            recordLabel.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 2),
            recordLabel.widthAnchor.constraint(equalToConstant: 40),

            // Stop label (hidden)
            stopLabel.centerXAnchor.constraint(equalTo: stopButton.centerXAnchor),
            stopLabel.topAnchor.constraint(equalTo: stopButton.bottomAnchor, constant: 2),
            stopLabel.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func createLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        return label
    }


    private func createIconButton(title: String, size: CGFloat) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1.0).cgColor
        button.layer?.cornerRadius = size / 2

        let attr = NSMutableAttributedString(string: title)
        attr.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: title.count))
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: size * 0.4), range: NSRange(location: 0, length: title.count))
        button.attributedTitle = attr

        return button
    }

    private func createModeButton(title: String, tooltip: String) -> ButtonContainer {
        // Create container view
        let container = ButtonContainer()
        container.wantsLayer = true

        // Create the icon button
        let button = HoverButton()
        button.title = title
        button.toolTip = tooltip
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 6
        button.font = NSFont.systemFont(ofSize: 28, weight: .regular)
        button.contentTintColor = NSColor(white: 0.7, alpha: 1.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        // Create the label below
        let label = NSTextField(labelWithString: tooltip)
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 0.6, alpha: 1.0)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        // Layout button and label vertically
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.widthAnchor.constraint(equalToConstant: 50),
            button.heightAnchor.constraint(equalToConstant: 50),

            label.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),

            container.widthAnchor.constraint(equalToConstant: 80),
            container.heightAnchor.constraint(equalToConstant: 80)
        ])

        // Store button and label references directly in the container property
        container.button = button
        container.label = label
        print("MainViewController: createModeButton - Created button with label '\(tooltip)', label exists: \(label != nil)")

        return container
    }

    private func setButtonEnabled(_ container: ButtonContainer, _ enabled: Bool) {
        container.button?.isEnabled = enabled
    }

    private func updateButtonStates() {
        // Update zoom effect buttons
        (noZoomButton.button as? HoverButton)?.isSelected = (zoomMode == .noZoom)
        (zoomOnClickButton.button as? HoverButton)?.isSelected = (zoomMode == .zoomOnClick)
        (followCursorButton.button as? HoverButton)?.isSelected = (zoomMode == .followCursor)

        // Update recording mode buttons
        (fullScreenButton.button as? HoverButton)?.isSelected = (recordingMode == .fullScreen)
        (selectedWindowButton.button as? HoverButton)?.isSelected = (recordingMode == .selectedWindow)

        print("MainViewController: updateButtonStates - recordingMode: \(recordingMode)")
        print("  fullScreenButton.isSelected: \((fullScreenButton.button as? HoverButton)?.isSelected ?? false)")
        print("  selectedWindowButton.isSelected: \((selectedWindowButton.button as? HoverButton)?.isSelected ?? false)")

        // Update speech-to-text button
        (speechToTextButton.button as? HoverButton)?.isSelected = isSpeechToTextEnabled
    }

    // Convert new modes to old TrackingMode for video export
    private func getTrackingMode() -> TrackingMode {
        // Map zoom mode to tracking mode (works for both full screen and selected window)
        switch zoomMode {
        case .noZoom:
            return .recordWindow  // No zoom is like window mode
        case .zoomOnClick:
            return .zoomOnClicks
        case .followCursor:
            return .followCursor
        }
    }

    // MARK: - Zoom Effect Actions
    @objc private func noZoomSelected() {
        zoomMode = .noZoom
        updateButtonStates()
        updateZoomButtonLabels()
    }

    @objc private func zoomOnClickSelected() {
        zoomMode = .zoomOnClick
        updateButtonStates()
        updateZoomButtonLabels()
    }

    @objc private func followCursorSelected() {
        zoomMode = .followCursor
        updateButtonStates()
        updateZoomButtonLabels()
    }

    private func updateZoomButtonLabels() {
        print("MainViewController: updateZoomButtonLabels called, zoomMode = \(zoomMode)")
        print("MainViewController: noZoomButton.label = \(String(describing: noZoomButton.label))")
        print("MainViewController: zoomOnClickButton.label = \(String(describing: zoomOnClickButton.label))")
        print("MainViewController: followCursorButton.label = \(String(describing: followCursorButton.label))")

        // Reset all to default labels first
        noZoomButton.label?.stringValue = "No Zoom"
        zoomOnClickButton.label?.stringValue = "Zoom on Clicks"
        followCursorButton.label?.stringValue = "Follow Cursor"

        // Update the selected button's label
        switch zoomMode {
        case .noZoom:
            noZoomButton.label?.stringValue = "No Zoom"
            print("MainViewController: Set noZoomButton label to 'No Zoom'")
        case .zoomOnClick:
            zoomOnClickButton.label?.stringValue = "Zoom on Clicks"
            print("MainViewController: Set zoomOnClickButton label to 'Zoom on Clicks'")
        case .followCursor:
            followCursorButton.label?.stringValue = "Following"
            print("MainViewController: Set followCursorButton label to 'Following'")
        }

        // Force the labels to refresh their display
        noZoomButton.label?.needsDisplay = true
        zoomOnClickButton.label?.needsDisplay = true
        followCursorButton.label?.needsDisplay = true

        print("MainViewController: After update - noZoomButton.label.stringValue = '\(noZoomButton.label?.stringValue ?? "nil")'")
        print("MainViewController: After update - zoomOnClickButton.label.stringValue = '\(zoomOnClickButton.label?.stringValue ?? "nil")'")
        print("MainViewController: After update - followCursorButton.label.stringValue = '\(followCursorButton.label?.stringValue ?? "nil")'")
    }

    // MARK: - Recording Mode Actions

    private func loadRecordingModePreference() {
        let savedMode = UserDefaults.standard.integer(forKey: "recordingMode")
        print("MainViewController: Loading recording mode - savedMode rawValue: \(savedMode)")
        if savedMode == RecordingMode.selectedWindow.rawValue {
            recordingMode = .selectedWindow
            print("MainViewController: Set to selectedWindow")
        } else {
            recordingMode = .fullScreen
            print("MainViewController: Set to fullScreen (default or saved)")
        }
        print("MainViewController: Loaded recording mode preference: \(recordingMode) (rawValue: \(recordingMode.rawValue))")
    }

    private func saveRecordingModePreference() {
        UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
        UserDefaults.standard.synchronize() // Force immediate save
        print("MainViewController: Saved recording mode preference: \(recordingMode) (rawValue: \(recordingMode.rawValue))")

        // Verify it was saved
        let verifyValue = UserDefaults.standard.integer(forKey: "recordingMode")
        print("MainViewController: Verified saved value: \(verifyValue)")
    }

    @objc private func fullScreenSelected() {
        print("MainViewController: fullScreenSelected() called!")
        print("  Stack trace: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n  "))")

        recordingMode = .fullScreen
        selectedWindowID = nil
        selectedWindowName = nil
        saveRecordingModePreference()
        updateButtonStates()
    }

    @objc func selectFullScreenMode() {
        fullScreenSelected()
    }

    @objc private func selectedWindowSelected() {
        print("MainViewController: selectedWindowSelected() called!")
        print("  Stack trace: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n  "))")

        // Just set the mode - window selection happens when recording starts
        recordingMode = .selectedWindow
        selectedWindowID = nil
        selectedWindowName = nil
        saveRecordingModePreference()
        updateButtonStates()
    }

    @objc func selectWindowMode() {
        selectedWindowSelected()
    }

    // MARK: - Speech-to-Text Action
    @objc private func speechToTextToggled() {
        isSpeechToTextEnabled.toggle()
        updateButtonStates()
        print("Speech-to-text \(isSpeechToTextEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Microphone Actions
    @objc private func microphoneButtonClicked() {
        showAudioDeviceMenu()
    }

    private func restoreMicrophoneSettings() {
        // Restore enabled state
        let savedEnabled = UserDefaults.standard.bool(forKey: "microphoneEnabled")
        let settingsSaved = UserDefaults.standard.bool(forKey: "microphoneSettingsSaved")

        // Default to enabled if never set
        if !settingsSaved {
            isMicrophoneEnabled = true
            print("MainViewController: Microphone settings not saved yet, defaulting to enabled")
        } else {
            isMicrophoneEnabled = savedEnabled
            print("MainViewController: Restored microphone enabled=\(savedEnabled)")
        }

        // Restore selected device
        if let savedID = UserDefaults.standard.string(forKey: "microphoneDeviceID") {
            let devices = ScreenRecorderNew.availableAudioDevices()
            selectedAudioDevice = devices.first { $0.uniqueID == savedID }
            print("MainViewController: Restored microphone device=\(selectedAudioDevice?.localizedName ?? "not found")")
        } else {
            print("MainViewController: No saved microphone device, will use default")
        }
    }

    private func saveMicrophoneSettings() {
        UserDefaults.standard.set(true, forKey: "microphoneSettingsSaved")
        UserDefaults.standard.set(isMicrophoneEnabled, forKey: "microphoneEnabled")
        if let device = selectedAudioDevice {
            UserDefaults.standard.set(device.uniqueID, forKey: "microphoneDeviceID")
        } else {
            UserDefaults.standard.removeObject(forKey: "microphoneDeviceID")
        }
    }

    private func updateMicrophoneButtonState() {
        if isMicrophoneEnabled {
            microphoneButton.button?.title = "🎙️"
            // Shorten device name for display if needed
            let deviceName = selectedAudioDevice?.localizedName ?? "Mic On"
            let displayName = deviceName.count > 12 ? String(deviceName.prefix(10)) + "…" : deviceName
            microphoneButton.label?.stringValue = displayName
            microphoneButton.button?.toolTip = "Microphone: \(deviceName)"
        } else {
            microphoneButton.button?.title = "🔇"
            microphoneButton.label?.stringValue = "Mic Off"
            microphoneButton.button?.toolTip = "Microphone disabled"
        }
        (microphoneButton.button as? HoverButton)?.isSelected = isMicrophoneEnabled
    }

    private func showAudioDeviceMenu() {
        guard let button = microphoneButton.button else { return }

        let menu = NSMenu()

        // Add "Off" option
        let offItem = NSMenuItem(title: "Off (No Microphone)", action: #selector(selectNoMicrophone), keyEquivalent: "")
        offItem.target = self
        offItem.state = !isMicrophoneEnabled ? .on : .off
        menu.addItem(offItem)

        menu.addItem(NSMenuItem.separator())

        // Add available audio devices
        let devices = ScreenRecorderNew.availableAudioDevices()
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(selectAudioDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            // Check if this is the selected device
            if isMicrophoneEnabled && selectedAudioDevice?.uniqueID == device.uniqueID {
                item.state = .on
            } else if isMicrophoneEnabled && selectedAudioDevice == nil && device == AVCaptureDevice.default(for: .audio) {
                item.state = .on // Default device
            }
            menu.addItem(item)
        }

        // Show the menu below the button
        let location = NSPoint(x: 0, y: button.bounds.height + 5)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func selectNoMicrophone() {
        isMicrophoneEnabled = false
        selectedAudioDevice = nil
        updateMicrophoneButtonState()
        saveMicrophoneSettings()
        print("Microphone disabled")
    }

    @objc private func selectAudioDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        selectedAudioDevice = device
        isMicrophoneEnabled = true
        updateMicrophoneButtonState()
        saveMicrophoneSettings()
        print("Selected audio device: \(device.localizedName)")
    }

    private func toggleMicrophoneDuringRecording() {
        guard isRecording, let recorder = screenRecorder else {
            print("MainViewController: Cannot toggle mic - not recording")
            return
        }

        // Toggle the mute state
        let newMuteState = !recorder.isAudioMuted
        recorder.isAudioMuted = newMuteState

        // Update the floating indicator
        floatingIndicator?.setMicrophoneOff(newMuteState)

        print("MainViewController: Microphone \(newMuteState ? "muted" : "unmuted") during recording")
    }

    @objc func startRecording() {
        print("MainViewController: startRecording() called")
        print("MainViewController: isRecording = \(isRecording)")
        print("MainViewController: recordButton.isEnabled = \(recordButton.isEnabled)")

        // Don't start if already recording
        guard !isRecording else {
            print("MainViewController: Already recording, ignoring start request")
            return
        }

        // Check for screen recording permission
        guard ScreenRecorderNew.checkPermission() else {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Please grant screen recording permission in System Settings > Privacy & Security > Screen Recording, then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        // If in selected window mode, always clear previous selection and show window picker
        if recordingMode == .selectedWindow {
            // Clear previous window selection to force user to pick again every time
            selectedWindowID = nil
            selectedWindowName = nil

            showWindowSelectionDialog { [weak self] windowID, windowName in
                guard let self = self, let windowID = windowID else {
                    // User cancelled - don't start recording
                    return
                }

                self.selectedWindowID = windowID
                self.selectedWindowName = windowName
                print("Selected window: \(windowName ?? "Unknown") (ID: \(windowID))")

                // Bring the selected window forward before starting recording
                self.bringWindowForward(windowID: windowID)

                // Add small delay to ensure window is fully activated before recording starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Now start recording with selected window
                    self.actuallyStartRecording()
                }
            }
            return
        }

        // Start recording immediately
        actuallyStartRecording()
    }

    private func actuallyStartRecording() {
        // Set recording state
        isRecording = true
        hasRecordedVideo = false

        // Notify app delegate that recording is active
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.isRecordingActive = true
        }

        // Update UI immediately (disable buttons)
        clickCount = 0
        resolutionPopup.isEnabled = false
        fpsPopup.isEnabled = false
        setButtonEnabled(noZoomButton, false)
        setButtonEnabled(zoomOnClickButton, false)
        setButtonEnabled(followCursorButton, false)
        setButtonEnabled(fullScreenButton, false)
        setButtonEnabled(selectedWindowButton, false)
        recordButton.isEnabled = false

        // Start blinking animation on record button
        startBlinkingRecordButton()

        // Setup menu bar and hide window FIRST, then start recording after window is hidden
        print("MainViewController: actuallyStartRecording() - about to setup menu bar and hide window")

        // Setup menu bar first (synchronously if already on main thread, or on main thread if not)
        if Thread.isMainThread {
            print("MainViewController: Setting up menu bar on main thread (synchronous)")
            setupMenuBar()
            print("MainViewController: Menu bar setup complete")

            // Start blinking the menu bar icon IMMEDIATELY
            startBlinkingMenuBarIcon()

            // Start timer to ensure menu bar stays visible
            ensureMenuBarVisible()

            // Show floating recording indicator as backup
            showFloatingIndicator()

            // Hide the window by making it fully transparent and moving it far off-screen
            // This keeps the window technically "visible" which may help status item persistence
            print("MainViewController: Hiding window by making transparent and moving off-screen")
            if let window = view.window {
                window.alphaValue = 0.0  // Fully transparent
                window.setFrame(NSRect(x: -10000, y: -10000, width: 1, height: 1), display: false)
            }

            // Wait for window to be fully hidden, THEN start actual recording
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startActualRecording()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                print("MainViewController: Setting up menu bar on main thread")
                self.setupMenuBar()

                // Start blinking the menu bar icon IMMEDIATELY
                self.startBlinkingMenuBarIcon()

                // Start timer to ensure menu bar stays visible
                self.ensureMenuBarVisible()

                // Show floating recording indicator as backup
                self.showFloatingIndicator()

                // Hide the window by making it fully transparent and moving it far off-screen
                // This keeps the window technically "visible" which may help status item persistence
                print("MainViewController: Hiding window by making transparent and moving off-screen")
                if let window = self.view.window {
                    window.alphaValue = 0.0  // Fully transparent
                    window.setFrame(NSRect(x: -10000, y: -10000, width: 1, height: 1), display: false)
                }

                // Wait for window to be fully hidden, THEN start actual recording
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startActualRecording()
                }
            }
        }
    }

    private func startActualRecording() {
        print("MainViewController: startActualRecording() - window is now hidden, starting recording")

        // Get resolution based on recording mode
        let resolution: CGSize
        if recordingMode == .selectedWindow, let windowID = selectedWindowID {
            // For window recording, scale to 4K quality (2880 width for X.com compatibility)
            if let windowBounds = getWindowBounds(windowID: windowID) {
                let windowAspect = windowBounds.width / windowBounds.height
                let targetWidth: CGFloat = 2880  // 4K width for X.com
                let targetHeight = targetWidth / windowAspect
                resolution = CGSize(
                    width: targetWidth,
                    height: targetHeight
                )
                print("MainViewController: Window recording - window size: \(windowBounds.width)x\(windowBounds.height), scaled to: \(resolution.width)x\(resolution.height)")
            } else {
                // Fallback to selected resolution if window bounds can't be determined
                resolution = getSelectedResolution()
            }
        } else {
            // For full screen recording, use selected resolution
            resolution = getSelectedResolution()
        }

        // CRITICAL: Set recording start time FIRST, before starting any tracking
        // This ensures cursor tracking and video use the same time reference
        recordingStartTime = Date()
        totalPausedDuration = 0  // Reset paused duration for new recording
        pauseStartTime = nil

        // Create screen recorder with frame-synchronized cursor tracking
        // Pass window ID if in selected window recording mode, or display ID for full screen
        let windowID = (recordingMode == .selectedWindow) ? selectedWindowID : nil
        let displayID = (recordingMode == .fullScreen) ? selectedDisplayID : nil
        screenRecorder = ScreenRecorderNew(resolution: resolution, windowID: windowID, displayID: displayID)

        // Exclude selfie preview window from screen recording so it's not baked into footage
        if isSelfieEnabledFlag, let selfieWinID = selfieCameraController.selfieWindowID {
            screenRecorder?.excludeWindowIDs = [selfieWinID]
        }

        // Configure microphone settings
        screenRecorder?.recordAudio = isMicrophoneEnabled
        screenRecorder?.audioDevice = selectedAudioDevice
        print("MainViewController: Recording with microphone \(isMicrophoneEnabled ? "enabled" : "disabled"), device: \(selectedAudioDevice?.localizedName ?? "default")")
        print("MainViewController: Recording display: \(selectedDisplayName ?? "Main Display")")

        // Read zoom mode from AppDelegate before starting tracking
        if let appDelegate = NSApp.delegate as? AppDelegate {
            let selectedZoomMode = appDelegate.currentZoomMode
            // Convert AppDelegate's Int zoom mode to MainViewController's ZoomMode enum
            switch selectedZoomMode {
            case 0: zoomMode = .noZoom
            case 1: zoomMode = .zoomOnClick
            case 2: zoomMode = .followCursor
            default: zoomMode = .noZoom
            }
            print("MainViewController: Read zoom mode from AppDelegate: \(zoomMode) (raw: \(selectedZoomMode))")
        }

        // Always start both trackers so user can switch zoom mode in editor
        let trackingWindowID = (recordingMode == .selectedWindow) ? selectedWindowID : nil

        clickTracker = ClickTrackerNew()
        clickTracker?.startTracking(windowID: trackingWindowID) { [weak self] clickEvent in
            self?.clickCount += 1
        }

        cursorTracker = CursorTrackerNew()
        cursorTracker?.startTracking(windowID: trackingWindowID)

        // Connect frame capture callback to both trackers
        // This ensures clicks/cursor are sampled at the EXACT moment each video frame is captured
        screenRecorder?.onFrameCaptured = { [weak self] timestamp in
            // Sample click tracker (only processes if there's a pending click)
            self?.clickTracker?.sampleClickAtFrameCapture(timestamp: timestamp)
            // Sample cursor tracker (only processes if in cursor mode)
            self?.cursorTracker?.sampleCursorAtFrameCapture(timestamp: timestamp)
        }

        // Start drawing overlay for Control+Draw feature
        let recordingBounds = getRecordingBounds()

        // Always create fresh overlays to avoid issues with stale window states
        drawingOverlay = DrawingOverlay(recordingBounds: recordingBounds)
        drawingOverlay?.start()

        // Window recording indicator disabled - using menu bar only
        // if recordingMode == .selectedWindow, let windowID = selectedWindowID {
        //     recordedWindowID = windowID
        //     showWindowRecordingIndicator(for: windowID)
        // }

        // Start speech-to-text if enabled
        if isSpeechToTextEnabled {
            // Always create fresh overlay to avoid issues with stale window states
            subtitleOverlay = SubtitleOverlay(recordingBounds: recordingBounds)
            subtitleOverlay?.start()

            speechRecognizer = AppleSpeechRecognizer()
            speechRecognizer?.delegate = self
            speechRecognizer?.startRecognition(recordingStartTime: recordingStartTime!)
        }

        // Synchronized recording start:
        // 1. Start all streams (screen + selfie camera)
        // 2. Wait for all to deliver their first frame ("ready")
        // 3. Enable writing on all simultaneously → both recordings start from the same moment
        let readyGroup = DispatchGroup()

        readyGroup.enter() // screen recorder
        screenRecorder?.onFirstFrameReady = {
            print("MainViewController: Screen recorder first frame ready")
            readyGroup.leave()
        }

        if isSelfieEnabledFlag {
            readyGroup.enter() // selfie camera
            selfieCameraController.startRecording(recordingStartTime: recordingStartTime!, recordingBounds: recordingBounds, onReady: {
                print("MainViewController: Selfie camera first frame ready")
                readyGroup.leave()
            })
        }

        // Start screen recording (frames arrive but aren't written yet)
        screenRecorder?.startRecording { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Recording Error"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
                return
            }
        }

        // When all streams are ready, start writing simultaneously
        readyGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.screenRecorder?.beginWriting()
            if self.isSelfieEnabledFlag {
                self.selfieCameraController.beginWriting()
            }
            print("MainViewController: All streams ready — writing started (synchronized)")
        }

        // Start timer
        startTimer()

        print("MainViewController: Recording started successfully")
    }

    @objc func stopRecording() {
        print("MainViewController: stopRecording() called")

        // Only stop if recording
        guard isRecording else {
            print("MainViewController: Not recording, ignoring stop request")
            return
        }

        print("MainViewController: Stopping recording...")

        // Set recording state
        isRecording = false
        hasRecordedVideo = true

        // Stop timers and button animations
        stopTimer()
        stopBlinkingRecordButton()

        // Notify app delegate that recording is no longer active
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.isRecordingActive = false
        }

        // Remove menu bar and restore main window
        print("MainViewController: Removing menu bar and restoring window")
        removeMenuBar()

        // Restore the window by making it visible and moving it back to center
        print("MainViewController: Restoring window")
        if let window = view.window {
            // Reset window style mask to borderless (no title bar)
            window.styleMask = [.borderless, .resizable]

            // Make it fully opaque again
            window.alphaValue = 1.0

            // Resize it back to normal size
            window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 300), display: true)

            // Move window back to center of screen
            window.center()

            // Bring it to front
            window.makeKeyAndOrderFront(nil)

            print("MainViewController: Window canBecomeKeyWindow: \(window.canBecomeKey)")
        }

        // Bring app to foreground
        NSApp.activate(ignoringOtherApps: true)
        print("MainViewController: Window restored")

        // STEP 1: Stop trackers
        print("MainViewController: STEP 1 - Stopping trackers...")
        clickTracker?.stopTracking()
        cursorTracker?.stopTracking()
        print("MainViewController: Trackers stopped")

        // STEP 2: Stop overlays
        print("MainViewController: STEP 2 - Stopping overlays...")
        drawingOverlay?.stop()
        speechRecognizer?.stopRecognition()
        subtitleOverlay?.stop()
        print("MainViewController: Overlays stopped")

        // STEP 3: Hide floating indicator (REFACTORED - simplified cleanup)
        print("MainViewController: STEP 3 - Hiding floating indicator...")
        hideFloatingIndicator()
        print("MainViewController: Floating indicator hidden")

        print("MainViewController: Stopping recording...")

        // Stop writing on all recorders simultaneously (synchronized stop)
        // This ensures both recordings have the same duration, so selfieStartOffset ≈ 0
        screenRecorder?.stopWriting()
        // Selfie writing is stopped inside stopRecording() below

        let completionGroup = DispatchGroup()
        var finalVideoURL: URL?

        if isSelfieEnabledFlag {
            completionGroup.enter()
            selfieCameraController.stopRecording { [weak self] selfieURL, events, offset in
                self?.selfieVideoURL = selfieURL
                self?.selfieOverlayEvents = events
                self?.selfieStartOffset = offset
                self?.selfieCameraController.closePreviewWindow()
                completionGroup.leave()
            }
        } else {
            selfieVideoURL = nil
            selfieOverlayEvents = []
            selfieStartOffset = 0
        }

        completionGroup.enter()
        screenRecorder?.stopRecording { [weak self] videoURL in
            guard let self = self else { return }

            print("MainViewController: Recording finished, video URL: \(videoURL?.path ?? "nil")")
            finalVideoURL = videoURL

            // STEP 4: Update UI
            print("MainViewController: STEP 4 - Updating UI...")
            DispatchQueue.main.async {
                self.resolutionPopup.isEnabled = true
                self.fpsPopup.isEnabled = true
                self.setButtonEnabled(self.noZoomButton, true)
                self.setButtonEnabled(self.zoomOnClickButton, true)
                self.setButtonEnabled(self.followCursorButton, true)
                self.setButtonEnabled(self.fullScreenButton, true)
                self.setButtonEnabled(self.selectedWindowButton, true)
                self.recordButton.isEnabled = true  // Re-enable record button
                print("MainViewController: UI updated")
            }
            completionGroup.leave()
        }

        completionGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            print("MainViewController: STEP 5 - Opening editor...")
            self.openEditorWithTempVideo(videoURL: finalVideoURL)
        }
    }

    private func openEditorWithTempVideo(videoURL: URL?) {
        print("MainViewController: openEditorWithTempVideo() called with URL: \(videoURL?.path ?? "nil")")

        // Verify we have a video URL
        guard let tempVideoURL = videoURL else {
            print("MainViewController: ERROR - No temp video URL provided")
            let alert = NSAlert()
            alert.messageText = "Editor Error"
            alert.informativeText = "Could not find the recorded video file."
            alert.alertStyle = .critical
            alert.runModal()
            resetToInitialState()
            return
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: tempVideoURL.path) else {
            print("MainViewController: ERROR - Temp video file does not exist at: \(tempVideoURL.path)")
            let alert = NSAlert()
            alert.messageText = "Editor Error"
            alert.informativeText = "The recorded video file could not be found at: \(tempVideoURL.path)"
            alert.alertStyle = .critical
            alert.runModal()
            resetToInitialState()
            return
        }

        print("MainViewController: Opening SEPARATE editor window with video: \(tempVideoURL.path)")

        // Create and show a SEPARATE editor window
        // Get click events and cursor positions
        let clickEvents = clickTracker?.getEvents() ?? []
        let cursorPositions = cursorTracker?.getPositions()
        let startTime = recordingStartTime ?? Date()

        // Store selfie overlay data for export
        if isSelfieEnabledFlag {
            UserDefaults.standard.set(selfieVideoURL?.path, forKey: "selfieVideoURL")
            UserDefaults.standard.set(selfieStartOffset, forKey: "selfieStartOffset")
            if let encoded = try? JSONEncoder().encode(selfieOverlayEvents) {
                UserDefaults.standard.set(encoded, forKey: "selfieOverlayEvents")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "selfieVideoURL")
            UserDefaults.standard.removeObject(forKey: "selfieStartOffset")
            UserDefaults.standard.removeObject(forKey: "selfieOverlayEvents")
        }

        let editorWindowController = EditorWindowController(
            videoURL: tempVideoURL,
            clickEvents: clickEvents,
            cursorPositions: cursorPositions,
            recordingStartTime: startTime,
            initialZoomMode: zoomMode,
            recordingMode: recordingMode
        )
        editorWindowController.showWindow(nil)

        print("MainViewController: Separate editor window opened successfully")
        print("MainViewController: Passed \(clickEvents.count) click events, \(cursorPositions?.count ?? 0) cursor positions, and zoom mode: \(zoomMode) to editor")
    }

    func setSelfieEnabled(_ enabled: Bool) {
        isSelfieEnabledFlag = enabled
        selfieCameraController.setEnabled(enabled)
    }

    func isSelfieEnabled() -> Bool {
        return isSelfieEnabledFlag
    }

    func setMicrophoneEnabled(_ enabled: Bool, device: AVCaptureDevice?) {
        isMicrophoneEnabled = enabled
        selectedAudioDevice = device
        saveMicrophoneSettings()
        updateMicrophoneButtonState()
    }

    func setSelectedDisplay(_ displayID: CGDirectDisplayID?, name: String?) {
        selectedDisplayID = displayID
        selectedDisplayName = name
        // Save selection to UserDefaults
        if let displayID = displayID {
            UserDefaults.standard.set(Int(displayID), forKey: "selectedDisplayID")
            UserDefaults.standard.set(name, forKey: "selectedDisplayName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedDisplayID")
            UserDefaults.standard.removeObject(forKey: "selectedDisplayName")
        }
        print("MainViewController: Selected display: \(name ?? "Main Display") (ID: \(displayID ?? CGMainDisplayID()))")
    }

    func restoreSelectedDisplay() {
        if let savedID = UserDefaults.standard.object(forKey: "selectedDisplayID") as? Int {
            selectedDisplayID = CGDirectDisplayID(savedID)
            selectedDisplayName = UserDefaults.standard.string(forKey: "selectedDisplayName")
            print("MainViewController: Restored display selection: \(selectedDisplayName ?? "Unknown") (ID: \(selectedDisplayID ?? 0))")
        }
    }

    private func autoExportVideo() {
        print("MainViewController: autoExportVideo() called - hasRecordedVideo: \(hasRecordedVideo), screenRecorder: \(screenRecorder != nil ? "exists" : "nil")")

        // Only export if we have a recorded video
        guard hasRecordedVideo, let recorder = screenRecorder else {
            print("MainViewController: ERROR - Cannot auto-export: hasRecordedVideo=\(hasRecordedVideo), screenRecorder=\(screenRecorder != nil)")
            return
        }

        // Format: vibe-recording-YYYYMMDD-HHMMSS
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "vibe-recording-\(timestamp).mp4"

        // Auto-save to Documents folder (EXACTLY as it was 2 days ago)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputURL = documentsPath.appendingPathComponent(filename)

        // Show progress bar (timer stays visible)
        progressIndicator.isHidden = false
        progressIndicator.doubleValue = 0

        // Get click events and cursor positions based on mode
        let clickEvents = clickTracker?.getEvents() ?? []
        let cursorPositions = cursorTracker?.getPositions()
        let mode = getTrackingMode()

        // Get subtitles for video compositing
        let subtitles = speechRecognizer?.getSubtitles()

        // Export subtitles if we have any (to same directory as video)
        if let recognizer = speechRecognizer, !recognizer.getSubtitles().isEmpty {
            let subtitlesFilename = "vibe-recording-\(timestamp)-subtitles.json"
            let videoDirectory = outputURL.deletingLastPathComponent()
            let subtitlesURL = videoDirectory.appendingPathComponent(subtitlesFilename)

            do {
                try recognizer.exportSubtitles(to: subtitlesURL)
                print("Exported subtitles to: \(subtitlesURL.path)")
            } catch {
                print("Failed to export subtitles: \(error)")
            }
        }

        // TEMPORARY FIX: Skip compositor to avoid GPU timeout - just copy the raw video
        print("MainViewController: ========================================")
        print("MainViewController: Using simple copy mode to avoid export hang")
        print("MainViewController: Output URL: \(outputURL.path)")
        print("MainViewController: Temp URL: \(recorder.recordedVideoURL?.path ?? "nil")")
        print("MainViewController: ========================================")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    print("MainViewController: Removing existing file at: \(outputURL.path)")
                    try FileManager.default.removeItem(at: outputURL)
                }

                // Simple copy - no compositor, no processing
                if let tempURL = recorder.recordedVideoURL {
                    print("MainViewController: Starting file copy from \(tempURL.path) to \(outputURL.path)")
                    try FileManager.default.copyItem(at: tempURL, to: outputURL)
                    print("MainViewController: ✓ Video copied successfully to: \(outputURL.path)")

                    DispatchQueue.main.async { [weak self] in
                        self?.progressIndicator.isHidden = true
                        self?.progressIndicator.doubleValue = 0

                        // Verify the output file exists before transitioning
                        guard FileManager.default.fileExists(atPath: outputURL.path) else {
                            print("MainViewController: ERROR - Exported file does not exist: \(outputURL.path)")
                            let alert = NSAlert()
                            alert.messageText = "Export Error"
                            alert.informativeText = "The video was exported but the file cannot be found."
                            alert.alertStyle = .critical
                            alert.runModal()
                            self?.resetToInitialState()
                            return
                        }

                        // Store the exported video URL for editing
                        self?.lastExportedVideoURL = outputURL

                        // Automatically transition to editor mode
                        self?.transitionToEditorMode(videoURL: outputURL)
                    }
                } else {
                    print("MainViewController: ERROR - recorder.recordedVideoURL is nil")
                    throw NSError(domain: "MainViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recorded video URL available"])
                }
            } catch {
                print("MainViewController: Copy failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.progressIndicator.isHidden = true
                    self?.progressIndicator.doubleValue = 0

                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Failed to copy video: \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.runModal()
                    self?.resetToInitialState()
                }
            }
        }

        return  // Exit early, skip the compositor path below

        // OLD PATH (commented out to avoid GPU timeout):
        /*
        recorder.exportWithZoom(clickEvents: clickEvents, cursorPositions: cursorPositions, trackingMode: mode, to: outputURL, startTime: recordingStartTime ?? Date(), subtitles: subtitles) { [weak self] progress in
            DispatchQueue.main.async {
                // Update progress bar with actual progress value (0-1 range)
                self?.progressIndicator.doubleValue = progress * 100
            }
        } completion: { [weak self] error in
            DispatchQueue.main.async {
                // Hide progress bar
                self?.progressIndicator.isHidden = true
                self?.progressIndicator.doubleValue = 0

                if let error = error {
                    print("MainViewController: Export failed with error: \(error.localizedDescription)")

                    // If export failed, try copying the raw recording as fallback
                    if let tempURL = self?.screenRecorder?.recordedVideoURL {
                        do {
                            // Copy raw recording to output location
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                try FileManager.default.removeItem(at: outputURL)
                            }
                            try FileManager.default.copyItem(at: tempURL, to: outputURL)
                            print("MainViewController: Fallback - copied raw recording to: \(outputURL.path)")

                            // Open the raw recording
                            NSWorkspace.shared.open(outputURL)

                            // Show "Completed" label
                            self?.completionLabel.isHidden = false

                            // Show warning that zoom effects couldn't be applied
                            let alert = NSAlert()
                            alert.messageText = "Export Completed (Without Zoom Effects)"
                            alert.informativeText = "The video was saved successfully, but zoom effects could not be applied. The raw recording has been saved instead."
                            alert.alertStyle = .warning
                            alert.runModal()

                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                self?.completionLabel.isHidden = true
                                self?.resetToInitialState()
                            }
                        } catch {
                            print("MainViewController: Fallback copy also failed: \(error.localizedDescription)")

                            // Show error alert
                            let alert = NSAlert()
                            alert.messageText = "Export Failed"
                            alert.informativeText = "Export failed: \(error.localizedDescription)\n\nRaw recording at: \(tempURL.path)"
                            alert.alertStyle = .critical
                            alert.runModal()
                            self?.resetToInitialState()
                        }
                    } else {
                        // No temp file available, show original error
                        let alert = NSAlert()
                        alert.messageText = "Export Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.runModal()
                        self?.resetToInitialState()
                    }
                } else {
                    print("MainViewController: Export complete, transitioning to editor mode")

                    // Verify the output file exists before transitioning
                    guard FileManager.default.fileExists(atPath: outputURL.path) else {
                        print("MainViewController: ERROR - Exported file does not exist: \(outputURL.path)")
                        let alert = NSAlert()
                        alert.messageText = "Export Error"
                        alert.informativeText = "The video was exported but the file cannot be found."
                        alert.alertStyle = .critical
                        alert.runModal()
                        self?.resetToInitialState()
                        return
                    }

                    // Store the exported video URL for editing
                    self?.lastExportedVideoURL = outputURL

                    // Automatically transition to editor mode
                    self?.transitionToEditorMode(videoURL: outputURL)
                }
            }
        }
        */
    }

    // MARK: - Video Editor Mode

    private func transitionToEditorMode(videoURL: URL) {
        print("MainViewController: transitionToEditorMode called with URL: \(videoURL.path)")

        guard !isInEditorMode else {
            print("MainViewController: Already in editor mode, skipping transition")
            return
        }

        guard let window = view.window else {
            print("MainViewController: ERROR - No window available for editor transition")
            showEditorError("Cannot show video editor: No window available")
            return
        }

        isInEditorMode = true

        // Expand window to accommodate editor
        let newFrame = NSRect(
            x: window.frame.origin.x,
            y: window.frame.origin.y - 670, // Expand downward
            width: 1000,
            height: 720 // 50 (controls) + 670 (editor)
        )

        print("MainViewController: Animating window from \(window.frame) to \(newFrame)")

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }

            print("MainViewController: Window animation complete, loading video in editor")

            // Show editor UI after animation
            self.editorContainerView.isHidden = false

            // Small delay to ensure UI is laid out before adding sublayer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.loadVideoInEditor(url: videoURL)
            }
        })

        print("MainViewController: Editor mode transition initiated")
    }

    @objc private func backToRecording() {
        // Clean up video player
        cleanupVideoPlayer()

        // Hide editor UI
        editorContainerView.isHidden = true
        isInEditorMode = false

        // Shrink window back to recording size
        if let window = view.window {
            let newFrame = NSRect(
                x: window.frame.origin.x,
                y: window.frame.origin.y + 420, // Shrink upward (adjusted for 300px height)
                width: 1000,
                height: 300
            )

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }, completionHandler: {
                // Reset to initial state
                self.resetToInitialState()
            })
        }

        print("MainViewController: Returned to recording mode")
    }

    private func loadVideoInEditor(url: URL) {
        print("MainViewController: Loading video in editor: \(url.path)")

        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("MainViewController: ERROR - Video file does not exist at path: \(url.path)")
            showEditorError("Video file not found")
            return
        }

        // Ensure playerView layer is properly configured
        if playerView.layer == nil {
            playerView.wantsLayer = true
            playerView.layer = CALayer()
        }

        // Load video asset
        videoAsset = AVAsset(url: url)

        guard let asset = videoAsset else {
            print("MainViewController: ERROR - Failed to load video asset")
            showEditorError("Failed to load video")
            return
        }

        // Create player item and player
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)

        guard let player = player else {
            print("MainViewController: ERROR - Failed to create player")
            showEditorError("Failed to create video player")
            return
        }

        // Create player layer with safety checks
        guard let layer = playerView.layer else {
            print("MainViewController: ERROR - playerView.layer is nil")
            showEditorError("Failed to initialize video view")
            return
        }

        // Create player layer
        let newPlayerLayer = AVPlayerLayer(player: player)
        newPlayerLayer.videoGravity = .resizeAspect

        // Ensure bounds are valid before setting frame
        let bounds = playerView.bounds
        if bounds.width > 0 && bounds.height > 0 {
            newPlayerLayer.frame = bounds
        } else {
            // Fallback to a reasonable default size
            print("MainViewController: WARNING - playerView bounds are zero, using default size")
            newPlayerLayer.frame = CGRect(x: 0, y: 0, width: 800, height: 450)
        }

        playerLayer = newPlayerLayer
        layer.addSublayer(newPlayerLayer)

        print("MainViewController: Player layer added successfully")

        // Get video duration
        Task {
            do {
                videoDuration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(videoDuration)

                print("MainViewController: Video duration loaded: \(durationSeconds)s")

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    // Update UI with duration
                    self.totalTimeLabel.stringValue = self.formatTime(durationSeconds)
                    self.trimEndTime = self.videoDuration
                    self.trimEndLabel.stringValue = "End: \(self.formatTime(durationSeconds))"

                    // Set up periodic time observer for playback
                    self.setupTimeObserver()

                    print("MainViewController: Video editor ready")
                }
            } catch {
                print("MainViewController: ERROR loading video duration: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.showEditorError("Failed to load video duration: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showEditorError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Video Editor Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Return to recording mode
            self?.backToRecording()
        }
    }

    private func setupTimeObserver() {
        // Update current time label every 0.1 seconds
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }

            let currentSeconds = CMTimeGetSeconds(time)
            let totalSeconds = CMTimeGetSeconds(self.videoDuration)

            // Update time label
            self.currentTimeLabel.stringValue = self.formatTime(currentSeconds)

            // Update timeline slider
            if totalSeconds > 0 {
                self.timelineSlider.doubleValue = (currentSeconds / totalSeconds) * 100
            }

            // Check if playback reached trim end point
            if time >= self.trimEndTime {
                self.player?.pause()
                self.updatePlayPauseButton(isPlaying: false)
            }
        }
    }

    private func cleanupVideoPlayer() {
        print("MainViewController: Cleaning up video player")

        // Remove time observer
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
            print("MainViewController: Time observer removed")
        }

        // Pause and release player
        player?.pause()
        player = nil
        print("MainViewController: Player released")

        // Remove player layer
        if let layer = playerLayer {
            layer.removeFromSuperlayer()
            playerLayer = nil
            print("MainViewController: Player layer removed")
        }

        // Release video asset
        videoAsset = nil
        videoDuration = .zero
        trimStartTime = .zero
        trimEndTime = .zero

        print("MainViewController: Video player cleanup complete")
    }

    // MARK: - Video Editor Controls

    @objc private func togglePlayPause() {
        guard let player = player else { return }

        if player.rate > 0 {
            // Currently playing, pause it
            player.pause()
            updatePlayPauseButton(isPlaying: false)
        } else {
            // Currently paused, play it
            // If at the end, seek back to trim start
            if let currentTime = player.currentItem?.currentTime(),
               currentTime >= trimEndTime {
                player.seek(to: trimStartTime)
            }
            player.play()
            updatePlayPauseButton(isPlaying: true)
        }
    }

    private func updatePlayPauseButton(isPlaying: Bool) {
        playPauseButton.title = isPlaying ? "⏸" : "▶"
    }

    @objc private func timelineSliderChanged() {
        guard let player = player else { return }

        let totalSeconds = CMTimeGetSeconds(videoDuration)
        let targetSeconds = (timelineSlider.doubleValue / 100.0) * totalSeconds
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        player.seek(to: targetTime)
    }

    @objc private func trimStartChanged() {
        let totalSeconds = CMTimeGetSeconds(videoDuration)
        let trimStartSeconds = (trimStartSlider.doubleValue / 100.0) * totalSeconds
        trimStartTime = CMTime(seconds: trimStartSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        trimStartLabel.stringValue = "Start: \(formatTime(trimStartSeconds))"

        // Ensure start is before end
        if trimStartTime > trimEndTime {
            trimEndTime = trimStartTime
            trimEndSlider.doubleValue = trimStartSlider.doubleValue
            trimEndLabel.stringValue = "End: \(formatTime(trimStartSeconds))"
        }

        // Seek to trim start
        player?.seek(to: trimStartTime)
    }

    @objc private func trimEndChanged() {
        let totalSeconds = CMTimeGetSeconds(videoDuration)
        let trimEndSeconds = (trimEndSlider.doubleValue / 100.0) * totalSeconds
        trimEndTime = CMTime(seconds: trimEndSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        trimEndLabel.stringValue = "End: \(formatTime(trimEndSeconds))"

        // Ensure end is after start
        if trimEndTime < trimStartTime {
            trimStartTime = trimEndTime
            trimStartSlider.doubleValue = trimEndSlider.doubleValue
            trimStartLabel.stringValue = "Start: \(formatTime(trimEndSeconds))"
        }
    }

    @objc private func exportEditedVideo() {
        guard let asset = videoAsset else {
            showError("No video loaded")
            return
        }

        // Pause playback
        player?.pause()
        updatePlayPauseButton(isPlaying: false)

        // Show progress
        exportEditProgressIndicator.isHidden = false
        exportEditProgressIndicator.doubleValue = 0
        exportEditedButton.isEnabled = false

        // Generate output filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "vibe-recording-\(timestamp)-edited.mp4"

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputURL = documentsPath.appendingPathComponent(filename)

        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Export with trim and canvas color
        exportVideoWithEdits(asset: asset, outputURL: outputURL) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.exportEditProgressIndicator.isHidden = true
                self.exportEditedButton.isEnabled = true

                if let error = error {
                    self.showError("Export failed: \(error.localizedDescription)")
                } else {
                    // Open the exported video
                    NSWorkspace.shared.open(outputURL)

                    // Show success message
                    let alert = NSAlert()
                    alert.messageText = "Export Complete!"
                    alert.informativeText = "Your edited video has been saved and opened."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            }
        }
    }

    private func exportVideoWithEdits(asset: AVAsset, outputURL: URL, completion: @escaping (Error?) -> Void) {
        // Create composition with trim
        let composition = AVMutableComposition()

        // Calculate time range for trim
        let timeRange = CMTimeRange(start: trimStartTime, end: trimEndTime)

        // Add video track
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"]))
            return
        }

        do {
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        } catch {
            completion(error)
            return
        }

        // Add audio track if exists
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            do {
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            } catch {
                print("MainViewController: Warning - failed to add audio track: \(error)")
            }
        }

        // Create video composition for canvas color (if not black)
        var videoComposition: AVMutableVideoComposition? = nil
        if canvasColorWell.color != .black {
            videoComposition = createVideoCompositionWithCanvasColor(composition: composition, videoTrack: compositionVideoTrack)
        }

        // Create export session
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        if let videoComposition = videoComposition {
            exportSession.videoComposition = videoComposition
        }

        // Monitor export progress
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak exportSession] timer in
            guard let session = exportSession else {
                timer.invalidate()
                return
            }

            DispatchQueue.main.async {
                self?.exportEditProgressIndicator.doubleValue = Double(session.progress) * 100
            }
        }

        // Start export
        exportSession.exportAsynchronously {
            timer.invalidate()

            switch exportSession.status {
            case .completed:
                completion(nil)
            case .failed:
                completion(exportSession.error)
            case .cancelled:
                completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
            default:
                completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown export status"]))
            }
        }
    }

    private func createVideoCompositionWithCanvasColor(composition: AVMutableComposition, videoTrack: AVMutableCompositionTrack) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)

        // Get video size
        let videoSize = videoTrack.naturalSize

        // Create layer instruction for canvas color
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, end: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        instruction.layerInstructions = [layerInstruction]

        videoComposition.instructions = [instruction]

        // Create layer composition for background color
        let backgroundLayer = CALayer()
        backgroundLayer.frame = CGRect(origin: .zero, size: videoSize)
        backgroundLayer.backgroundColor = canvasColorWell.color.cgColor

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(backgroundLayer)
        parentLayer.addSublayer(videoLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        return videoComposition
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func resetToInitialState() {
        // Clean up recording state
        screenRecorder = nil
        recordingStartTime = nil
        clickCount = 0
        isRecording = false
        hasRecordedVideo = false
        lastExportedVideoURL = nil

        // Clean up overlays properly - nil them out to force recreation next time
        // This prevents issues when switching between different window sizes
        drawingOverlay = nil
        subtitleOverlay = nil
        clickTracker = nil
        cursorTracker = nil
        speechRecognizer = nil

        // Stop blinking if still active
        stopBlinkingRecordButton()

        // Reset UI to initial state (timer resets to 00:00 but stays visible)
        timerLabel.stringValue = "00:00"
        recordButton.isEnabled = true
        resolutionPopup.isEnabled = true
        fpsPopup.isEnabled = true
        setButtonEnabled(noZoomButton, true)
        setButtonEnabled(zoomOnClickButton, true)
        setButtonEnabled(followCursorButton, true)
        setButtonEnabled(fullScreenButton, true)
        setButtonEnabled(selectedWindowButton, true)

        // Hide completion UI
        completionLabel.isHidden = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Update player layer frame when view resizes
        playerLayer?.frame = playerView.bounds
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cleanupVideoPlayer()
    }

    private func getSelectedResolution() -> CGSize {
        // Get the actual screen size and aspect ratio
        // Use selected display if set, otherwise main screen
        let screenSize: CGSize
        if let displayID = selectedDisplayID {
            let bounds = CGDisplayBounds(displayID)
            screenSize = bounds.size
        } else if let mainSize = NSScreen.main?.frame.size {
            screenSize = mainSize
        } else {
            return CGSize(width: 3840, height: 2160)
        }

        let screenAspectRatio = screenSize.width / screenSize.height

        switch resolutionPopup.indexOfSelectedItem {
        case 0: // 4K - cap at 2880px width for X.com compatibility, adjust height to maintain aspect ratio
            let targetWidth: CGFloat = 2880
            let targetHeight = targetWidth / screenAspectRatio
            return CGSize(width: targetWidth, height: targetHeight)
        case 1: // 1440p - maintain screen aspect ratio
            let height: CGFloat = 1440
            let width = height * screenAspectRatio
            return CGSize(width: width, height: height)
        case 2: // 1080p - maintain screen aspect ratio
            let height: CGFloat = 1080
            let width = height * screenAspectRatio
            return CGSize(width: width, height: height)
        default: // Native resolution
            return screenSize
        }
    }

    private func getRecordingBounds() -> CGRect {
        if recordingMode == .selectedWindow, let windowID = selectedWindowID {
            // Get bounds for selected window
            return getWindowBounds(windowID: windowID) ?? NSScreen.main?.frame ?? .zero
        } else {
            // Full screen recording - use selected display or main screen
            if let displayID = selectedDisplayID {
                return CGDisplayBounds(displayID)
            }
            return NSScreen.main?.frame ?? .zero
        }
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
        // We need to convert to bottom-left origin (matching NSEvent.mouseLocation)
        guard let mainScreen = NSScreen.main else { return nil }
        let mainScreenHeight = mainScreen.frame.height

        // Convert from top-left to bottom-left origin
        let bottomLeftY = mainScreenHeight - y - height

        return CGRect(x: x, y: bottomLeftY, width: width, height: height)
    }

    private func bringWindowForward(windowID: CGWindowID) {
        // Get window information to find the owning process
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let windowInfo = windowList.first,
              let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            print("MainViewController: Could not find owner PID for window \(windowID)")
            return
        }

        // Get the application for this PID
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
            print("MainViewController: Could not find running application for PID \(ownerPID)")
            return
        }

        // Activate the application to bring it forward
        let success = app.activate(options: [.activateIgnoringOtherApps])
        if success {
            print("MainViewController: Successfully brought window forward (PID: \(ownerPID), App: \(app.localizedName ?? "Unknown"))")
        } else {
            print("MainViewController: Failed to activate application for window \(windowID)")
        }
    }

    private func startTimer() {
        timerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            // Calculate elapsed time minus any paused duration
            let totalElapsed = Date().timeIntervalSince(startTime)
            let activeElapsed = Int(totalElapsed - self.totalPausedDuration)
            let minutes = activeElapsed / 60
            let seconds = activeElapsed % 60
            self.timerLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
            self.updateMenuBarTime()
        }
    }

    private func stopTimer() {
        timerUpdateTimer?.invalidate()
        timerUpdateTimer = nil
    }

    private func startBlinkingRecordButton() {
        // Blink the record button to indicate recording
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let layer = self.recordButton.layer else { return }

            // Toggle opacity
            let currentOpacity = layer.opacity
            layer.opacity = currentOpacity > 0.5 ? 0.3 : 1.0
        }
    }

    private func stopBlinkingRecordButton() {
        blinkTimer?.invalidate()
        blinkTimer = nil

        // Reset opacity to full
        recordButton.layer?.opacity = 1.0
    }

    // MARK: - Menu Bar

    private func createSolidRedCircleImage(size: CGFloat, alpha: CGFloat = 1.0) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        // Draw solid red circle with custom color #db0f00
        let customRed = NSColor(red: 0xdb/255.0, green: 0x0f/255.0, blue: 0x00/255.0, alpha: alpha)
        customRed.setFill()
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        circlePath.fill()

        image.unlockFocus()
        return image
    }

    private func setupMenuBar() {
        print("MainViewController: Setting up menu bar...")

        // Get app delegate to store status item there
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            print("MainViewController: ERROR - Could not get app delegate")
            return
        }

        // Remove any existing status item first to avoid duplicates
        if let existingItem = appDelegate.statusItem {
            print("MainViewController: Removing existing status item")
            NSStatusBar.system.removeStatusItem(existingItem)
            appDelegate.statusItem = nil
        }

        // Create status item in menu bar with fixed length
        // Fixed length of 80 should fit the icon + timer comfortably
        appDelegate.statusItem = NSStatusBar.system.statusItem(withLength: 80)

        guard let statusItem = appDelegate.statusItem else {
            print("MainViewController: ERROR - Failed to create status item")
            return
        }

        // Set autosave name to help persist the status item
        statusItem.autosaveName = "CaptureThisStatusItem"

        // Also keep local reference for convenience
        self.statusItem = statusItem

        guard let button = statusItem.button else {
            print("MainViewController: ERROR - Failed to get status item button")
            return
        }

        print("MainViewController: Status item created at memory address: \(Unmanaged.passUnretained(statusItem).toOpaque())")

        // Ensure status item is visible and persists even when app is not active
        statusItem.isVisible = true
        // Don't set any behavior - default behavior keeps item visible

        // Make button visible and enabled
        button.isEnabled = true
        button.isHidden = false

        // Set background color to make it more visible for debugging
        button.appearsDisabled = false

        // Create both normal and faded versions of the red circle image
        normalRedCircleImage = createSolidRedCircleImage(size: 16, alpha: 1.0)
        fadedRedCircleImage = createSolidRedCircleImage(size: 16, alpha: 0.3)
        button.image = normalRedCircleImage
        print("MainViewController: Created solid red circle icon (normal and faded versions)")

        // Add spacing between icon and text using monospaced digits to prevent shifting
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = "  00:00"  // Two spaces for padding between icon and text
        button.imagePosition = .imageLeading  // Icon on left, text on right

        // Create menu with pause and stop options
        let menu = NSMenu()

        let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePauseRecording), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingFromMenuBar), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        statusItem.menu = menu
        menuBarMenu = menu

        // Log detailed button information
        print("MainViewController: Button configured:")
        print("  - Title: '\(button.title)'")
        print("  - Image: \(button.image != nil ? "YES" : "NO")")
        print("  - Visible: \(statusItem.isVisible)")
        print("  - Enabled: \(button.isEnabled)")
        print("  - Button frame: \(button.frame)")
        print("  - Button bounds: \(button.bounds)")
        print("  - Status item length: \(statusItem.length)")

        print("MainViewController: Menu bar setup complete - statusItem retained: \(self.statusItem != nil)")
        print("MainViewController: ⚠️ LOOK FOR RED CIRCLE (🔴) ON THE RIGHT SIDE OF YOUR MENU BAR ⚠️")
        print("MainViewController: Click the red circle to stop recording")
    }

    private func removeMenuBar() {
        // Stop the ensure-visible timer if running
        menuBarEnsureVisibleTimer?.invalidate()
        menuBarEnsureVisibleTimer = nil

        // Stop blinking timer
        stopBlinkingMenuBarIcon()

        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            self.menuBarMenu = nil
        }
    }

    private func startBlinkingMenuBarIcon() {
        // Blink the menu bar icon to indicate recording (only icon, not text)
        menuBarBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem?.button else { return }

            // Toggle between normal and faded circle images (text stays at full opacity)
            if button.image == self.normalRedCircleImage {
                button.image = self.fadedRedCircleImage
            } else {
                button.image = self.normalRedCircleImage
            }
        }
        print("MainViewController: Menu bar icon blinking started")
    }

    private func stopBlinkingMenuBarIcon() {
        menuBarBlinkTimer?.invalidate()
        menuBarBlinkTimer = nil

        // Reset icon to normal (full opacity)
        statusItem?.button?.image = normalRedCircleImage
        print("MainViewController: Menu bar icon blinking stopped")
    }

    private func ensureMenuBarVisible() {
        // Start a timer that periodically ensures the status item stays visible
        // Keep this running for the ENTIRE recording duration
        // NOTE: We do NOT re-activate the app - status items should be visible even when app is inactive
        var checkCount = 0
        menuBarEnsureVisibleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            checkCount += 1

            // Only enforce visibility while recording
            if !self.isRecording {
                print("MainViewController: Not recording, stopping visibility enforcement")
                timer.invalidate()
                self.menuBarEnsureVisibleTimer = nil
                return
            }

            // Ensure status item is visible (but don't re-activate the app!)
            if let statusItem = self.statusItem {
                if !statusItem.isVisible {
                    print("MainViewController: ⚠️ Menu bar icon became hidden, forcing visibility")
                    statusItem.isVisible = true
                }

                // Log less frequently to reduce console spam
                // Only log every 10 seconds (every 5th check)
                if checkCount % 5 == 0 {
                    print("MainViewController: Menu bar monitoring - visible: \(statusItem.isVisible)")
                }
            }
        }

        print("MainViewController: Started continuous menu bar visibility enforcement (status item only, not app activation)")
    }

    private func updateMenuBarTime() {
        // Update the menu bar button title with current recording time
        guard let startTime = recordingStartTime else { return }
        // Calculate elapsed time minus any paused duration
        let totalElapsed = Date().timeIntervalSince(startTime)
        let activeElapsed = Int(totalElapsed - totalPausedDuration)
        let minutes = activeElapsed / 60
        let seconds = activeElapsed % 60

        // Update title with spacing
        let timeString = String(format: "  %02d:%02d", minutes, seconds)  // Two spaces for padding
        statusItem?.button?.title = timeString

        // Also update floating indicator
        floatingIndicator?.updateTime(String(format: "%02d:%02d", minutes, seconds))
    }

    @objc private func togglePauseRecording() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    private func pauseRecording() {
        guard isRecording && !isPaused else { return }

        isPaused = true
        pauseStartTime = Date()  // Track when pause started
        print("MainViewController: Recording paused")

        // Pause the screen recorder
        screenRecorder?.pause()

        // Stop timer counting
        stopTimer()

        // Stop blinking - make red dot faded/disabled
        stopBlinkingMenuBarIcon()
        if let button = statusItem?.button {
            button.image = fadedRedCircleImage  // Faded red (0.3 alpha) to show NOT recording
        }

        // Update floating indicator to faded/disabled state
        floatingIndicator?.stopBlinking()
        floatingIndicator?.setDisabled(true)  // Faded red dot
        floatingIndicator?.setPaused(true)

        // Update menu item text
        if let menu = menuBarMenu {
            menu.items.first?.title = "Resume Recording"
        }
    }

    private func resumeRecording() {
        guard isRecording && isPaused else { return }

        // Calculate and accumulate paused duration
        if let pauseStart = pauseStartTime {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
            print("MainViewController: Accumulated paused duration: \(totalPausedDuration) seconds")
        }

        isPaused = false
        print("MainViewController: Recording resumed")

        // Resume the screen recorder
        screenRecorder?.resume()

        // Restart timer counting
        startTimer()

        // Start blinking again with normal red color
        if let button = statusItem?.button {
            button.image = normalRedCircleImage  // Back to normal red
        }
        startBlinkingMenuBarIcon()

        // Update floating indicator back to active state
        floatingIndicator?.setDisabled(false)  // Normal red dot
        floatingIndicator?.startBlinking()
        floatingIndicator?.setPaused(false)

        // Update menu item text
        if let menu = menuBarMenu {
            menu.items.first?.title = "Pause Recording"
        }
    }

    @objc private func stopRecordingFromMenuBar() {
        stopRecording()
    }

    // MARK: - Floating Recording Indicator

    private func showFloatingIndicator() {
        // Always show floating indicator as reliable backup
        // macOS menu bar visibility detection is unreliable across different configurations
        // The indicator is small (160x40px) and provides always-available controls
        print("MainViewController: Showing floating indicator")
        createFloatingIndicator()
    }

    private func createFloatingIndicator() {
        // Create floating indicator window - show mic off indicator if microphone is disabled
        let micOff = !isMicrophoneEnabled
        floatingIndicator = FloatingRecordingIndicator(microphoneOff: micOff)

        // Set callbacks
        floatingIndicator?.onPause = { [weak self] in
            print("MainViewController: Pause button clicked on floating indicator")
            self?.togglePauseRecording()
        }

        floatingIndicator?.onStop = { [weak self] in
            print("MainViewController: Stop button clicked on floating indicator")
            self?.stopRecording()
        }

        floatingIndicator?.onMicToggle = { [weak self] in
            print("MainViewController: Mic button clicked on floating indicator")
            self?.toggleMicrophoneDuringRecording()
        }

        // Position in top-right corner of main screen
        // Window is always 220 wide (includes mic indicator)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 220 - 20  // 220 width + 20 padding
            let y = screenFrame.maxY - 60   // 40 height + 20 padding
            floatingIndicator?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Show the floating indicator
        floatingIndicator?.orderFrontRegardless()

        print("MainViewController: Floating indicator shown")
    }

    private func hideFloatingIndicator() {
        guard let indicator = floatingIndicator else {
            print("MainViewController: No floating indicator to hide")
            return
        }

        print("MainViewController: Hiding floating indicator...")

        // Stop the timer only
        indicator.cleanup()

        // Just hide the window, don't close it
        indicator.orderOut(nil)

        // Release reference after a delay to ensure window is fully hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.floatingIndicator = nil
            print("MainViewController: Floating indicator reference released")
        }

        print("MainViewController: Floating indicator hidden")
    }

    // MARK: - Window Recording Indicator

    private func showWindowRecordingIndicator(for windowID: CGWindowID) {
        // Get the window bounds
        guard let windowBounds = getWindowBounds(windowID: windowID) else {
            print("MainViewController: Failed to get window bounds for indicator")
            return
        }

        // Create border overlay that wraps around the recorded window
        let borderWidth: CGFloat = 4
        let padding: CGFloat = 0  // Border sits right on the edge

        // Border frame should be slightly larger than window to create border effect
        let borderFrame = NSRect(
            x: windowBounds.origin.x - borderWidth,
            y: windowBounds.origin.y - borderWidth,
            width: windowBounds.width + (borderWidth * 2),
            height: windowBounds.height + (borderWidth * 2)
        )

        windowIndicatorOverlay = NSWindow(
            contentRect: borderFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        guard let overlay = windowIndicatorOverlay else { return }

        // Configure overlay window
        overlay.level = .floating - 1  // Just behind the recorded window
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true  // Don't interfere with window interactions
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Create content view with custom drawing
        let contentView = BorderView(frame: NSRect(x: 0, y: 0, width: borderFrame.width, height: borderFrame.height))
        contentView.borderWidth = borderWidth

        // Add red circle indicator in top-right corner of border
        let indicatorSize: CGFloat = 20
        let indicatorPadding: CGFloat = 8
        let indicatorX = borderFrame.width - indicatorSize - indicatorPadding
        let indicatorY = borderFrame.height - indicatorSize - indicatorPadding

        windowIndicatorImageView = NSImageView(frame: NSRect(x: indicatorX, y: indicatorY, width: indicatorSize, height: indicatorSize))
        windowIndicatorImageView?.image = createSolidRedCircleImage(size: indicatorSize, alpha: 1.0)
        windowIndicatorImageView?.wantsLayer = true
        windowIndicatorImageView?.layer?.shadowColor = NSColor.black.cgColor
        windowIndicatorImageView?.layer?.shadowOpacity = 0.5
        windowIndicatorImageView?.layer?.shadowRadius = 2
        windowIndicatorImageView?.layer?.shadowOffset = CGSize(width: 0, height: -1)
        contentView.addSubview(windowIndicatorImageView!)

        overlay.contentView = contentView
        overlay.orderBack(nil)  // Send to back so it's behind the window

        // Start blinking
        startWindowIndicatorBlink()

        // Monitor window position changes
        startMonitoringWindowPosition()

        print("MainViewController: Showed window recording border with indicator on window \(windowID)")
    }

    private func startWindowIndicatorBlink() {
        windowIndicatorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Toggle between normal and faded images
            if self.windowIndicatorImageView?.alphaValue == 1.0 {
                self.windowIndicatorImageView?.alphaValue = 0.3
            } else {
                self.windowIndicatorImageView?.alphaValue = 1.0
            }
        }
    }

    private func stopWindowIndicatorBlink() {
        windowIndicatorBlinkTimer?.invalidate()
        windowIndicatorBlinkTimer = nil
        windowIndicatorImageView?.alphaValue = 1.0
    }

    private func startMonitoringWindowPosition() {
        // Monitor window position every 0.1 seconds to keep indicator aligned
        windowPositionMonitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateWindowIndicatorPosition()
        }
    }

    private func stopMonitoringWindowPosition() {
        windowPositionMonitor?.invalidate()
        windowPositionMonitor = nil
    }

    private func updateWindowIndicatorPosition() {
        guard let windowID = recordedWindowID,
              let overlay = windowIndicatorOverlay,
              let windowBounds = getWindowBounds(windowID: windowID) else {
            return
        }

        // Update border position to wrap around window
        let borderWidth: CGFloat = 4
        let borderFrame = NSRect(
            x: windowBounds.origin.x - borderWidth,
            y: windowBounds.origin.y - borderWidth,
            width: windowBounds.width + (borderWidth * 2),
            height: windowBounds.height + (borderWidth * 2)
        )

        // Only update if position or size changed (avoid unnecessary updates)
        if overlay.frame != borderFrame {
            overlay.setFrame(borderFrame, display: false)

            // Update indicator position within the new border
            let indicatorSize: CGFloat = 20
            let indicatorPadding: CGFloat = 8
            let indicatorX = borderFrame.width - indicatorSize - indicatorPadding
            let indicatorY = borderFrame.height - indicatorSize - indicatorPadding

            windowIndicatorImageView?.frame = NSRect(x: indicatorX, y: indicatorY, width: indicatorSize, height: indicatorSize)
        }
    }

    private func hideWindowRecordingIndicator() {
        stopWindowIndicatorBlink()
        stopMonitoringWindowPosition()

        windowIndicatorOverlay?.close()
        windowIndicatorOverlay = nil
        windowIndicatorImageView = nil
        recordedWindowID = nil

        print("MainViewController: Hid window recording indicator")
    }

    // MARK: - Border View for Window Recording

    private class BorderView: NSView {
        var borderWidth: CGFloat = 4

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // Draw red border around the entire view
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(borderWidth)

            // Create border path (inset by half border width for crisp edges)
            let borderRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            context.stroke(borderRect)
        }
    }

    // MARK: - Window Selection
    private func showWindowSelectionDialog(completion: @escaping (CGWindowID?, String?) -> Void) {
        // Clean up previous selector if it exists
        if let existingSelector = windowSelector {
            existingSelector.cleanup()
            windowSelector = nil
        }

        // Use Mission Control-style grid selection
        let selector = MissionControlWindowSelector()
        windowSelector = selector  // Keep strong reference

        selector.onWindowSelected = { [weak self] windowID, appName in
            completion(windowID, appName)
            // Clean up after selection
            self?.windowSelector = nil
        }
        selector.onCancelled = { [weak self] in
            completion(nil, nil)
            // Clean up after cancellation
            self?.windowSelector = nil
        }
        selector.show()
    }
}

// MARK: - Draggable View
class DraggableView: NSView {
    private var initialLocation: NSPoint?

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 1000, height: 300)
    }

    override func mouseDown(with event: NSEvent) {
        initialLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window,
              let initialLocation = initialLocation else { return }

        let currentLocation = event.locationInWindow
        let newOrigin = NSPoint(
            x: window.frame.origin.x + (currentLocation.x - initialLocation.x),
            y: window.frame.origin.y + (currentLocation.y - initialLocation.y)
        )

        window.setFrameOrigin(newOrigin)
    }
}

// MARK: - Tooltip Button with instant display
class TooltipButton: NSButton {
    private var tooltipWindow: NSWindow?
    private var tooltipLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private let tooltipText: String

    init(tooltip: String) {
        self.tooltipText = tooltip
        super.init(frame: .zero)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        self.tooltipText = ""
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )

        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        showTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideTooltip()
    }

    private func showTooltip() {
        // Clean up any existing tooltip first
        hideTooltip()

        guard let window = self.window else { return }

        // Create tooltip label
        let label = NSTextField(labelWithString: tooltipText)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .white
        label.backgroundColor = NSColor(white: 0.2, alpha: 0.95)
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center

        // Calculate size
        label.sizeToFit()
        let padding: CGFloat = 8
        let labelSize = NSSize(
            width: label.frame.width + padding * 2,
            height: label.frame.height + padding
        )

        // Position tooltip above button
        let buttonFrameInWindow = convert(bounds, to: nil)
        let buttonFrameInScreen = window.convertToScreen(buttonFrameInWindow)

        let tooltipX = buttonFrameInScreen.origin.x + (buttonFrameInScreen.width - labelSize.width) / 2
        let tooltipY = buttonFrameInScreen.origin.y + buttonFrameInScreen.height + 5

        let tooltipFrame = NSRect(
            x: tooltipX,
            y: tooltipY,
            width: labelSize.width,
            height: labelSize.height
        )

        // Create tooltip window
        let tooltip = NSWindow(
            contentRect: tooltipFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        tooltip.backgroundColor = .clear
        tooltip.isOpaque = false
        tooltip.level = .statusBar
        tooltip.ignoresMouseEvents = true
        tooltip.hasShadow = false  // CRITICAL: No shadow to avoid animations
        tooltip.isReleasedWhenClosed = false  // Important: prevent auto-release
        tooltip.animationBehavior = .none  // CRITICAL: Disable ALL animations

        // Create container view with rounded corners
        let containerView = NSView(frame: NSRect(origin: .zero, size: labelSize))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
        containerView.layer?.cornerRadius = 4

        // Position label in container
        label.frame = NSRect(
            x: padding,
            y: (labelSize.height - label.frame.height) / 2,
            width: label.frame.width,
            height: label.frame.height
        )

        containerView.addSubview(label)
        tooltip.contentView = containerView

        self.tooltipWindow = tooltip
        self.tooltipLabel = label

        tooltip.orderFront(nil)
    }

    private func hideTooltip() {
        if let window = tooltipWindow {
            window.orderOut(nil)
            // DON'T set contentView = nil or close window - just hide it
            // This prevents animation crashes
        }
        // Keep references alive to reuse tooltip
    }
}

// MARK: - Speech Recognition Delegate
extension MainViewController: AppleSpeechRecognizerDelegate {
    func didReceiveTranscript(_ text: String, isFinal: Bool) {
        DispatchQueue.main.async { [weak self] in
            // Show subtitle on screen
            // Final subtitles (complete sentences) stay for 3 seconds
            // Interim subtitles (partial) stay visible (very long duration since they keep updating)
            self?.subtitleOverlay?.showSubtitle(text, duration: isFinal ? 3.0 : 60.0)

            print("Subtitle: \(text) (final: \(isFinal))")
        }
    }

    func didEncounterError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            print("Speech recognition error: \(error.localizedDescription)")

            let alert = NSAlert()
            alert.messageText = "Speech Recognition Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()

            // Disable speech-to-text on error
            self?.isSpeechToTextEnabled = false
            self?.updateButtonStates()
        }
    }
}

// MARK: - Hover Button
// Container view for button with label
class ButtonContainer: NSView {
    var button: HoverButton?
    var label: NSTextField?
}

class HoverButton: NSButton {
    private var normalColor: NSColor
    private var hoverColor: NSColor
    private var selectedColor: NSColor
    private var trackingArea: NSTrackingArea?
    var isSelected: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    init(normalColor: NSColor = NSColor(white: 0.2, alpha: 1.0),
         hoverColor: NSColor = NSColor(white: 0.25, alpha: 1.0),
         selectedColor: NSColor = NSColor(white: 0.35, alpha: 1.0)) {
        self.normalColor = normalColor
        self.hoverColor = hoverColor
        self.selectedColor = selectedColor
        super.init(frame: .zero)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        self.normalColor = NSColor(white: 0.2, alpha: 1.0)
        self.hoverColor = NSColor(white: 0.25, alpha: 1.0)
        self.selectedColor = NSColor(white: 0.35, alpha: 1.0)
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        // Enable layer backing so we can animate backgroundColor
        wantsLayer = true
        layer?.cornerRadius = 4

        updateTrackingAreas()

        // Set initial appearance
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled {
            animateBackgroundColor(to: isSelected ? selectedColor : hoverColor)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateAppearance(animated: true)
    }

    private func animateBackgroundColor(to color: NSColor) {
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer?.backgroundColor
        animation.toValue = color.cgColor
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "backgroundColor")
        layer?.backgroundColor = color.cgColor
    }

    private func updateAppearance(animated: Bool = false) {
        let targetColor = isSelected ? selectedColor : normalColor

        print("HoverButton.updateAppearance: isSelected=\(isSelected), animated=\(animated), layer exists=\(layer != nil), wantsLayer=\(wantsLayer)")

        if animated {
            animateBackgroundColor(to: targetColor)
        } else {
            layer?.backgroundColor = targetColor.cgColor
        }

        print("  -> Set background to \(isSelected ? "selectedColor" : "normalColor"): \(targetColor)")
    }
}
