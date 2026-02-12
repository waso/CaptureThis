import Cocoa
import AVFoundation

// Custom view for editor - allows resizing
class EditorContainerView: NSView {
    // Return noIntrinsicMetric to allow the window to be freely resized
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

class EditorViewController: NSViewController {
    private var videoURL: URL
    private var clickEvents: [ClickEventNew]
    private var cursorPositions: [CursorPositionNew]?
    private var recordingStartTime: Date
    private var playerView: NSView!
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var previewContainerLayer: CALayer?
    private var previewBackgroundLayer: CALayer?
    private var playPauseButton: NSButton!
    private var timelineView: TimelineView!
    private var timelineScrollBar: TimelineScrollBar!
    private var canvasColorWell: NSColorWell!
    private var canvasColorLabel: NSTextField!
    private var zoomModeLabel: NSTextField!
    private var zoomModePopup: NSPopUpButton!
    private var bladeToolButton: NSButton!
    private var exportButton: NSButton!
    private var exportProgressIndicator: NSProgressIndicator!
    private var exitButton: NSButton!
    private var rightPanel: NSView!
    private var rightPanelTitle: NSTextField!
    private var backgroundSectionLabel: NSTextField!
    private var colorsLabel: NSTextField!
    private var imagesLabel: NSTextField!
    private var colorsStackRow1: NSStackView!
    private var colorsStackRow2: NSStackView!
    private var imagesStackRow1: NSStackView!
    private var imagesStackRow2: NSStackView!
    private var imagesStackRow3: NSStackView!
    private var borderToggle: NSSwitch!
    private var selfieToggle: NSSwitch!
    private var borderWidthSlider: NSSlider!
    private var borderWidthLabel: NSTextField!
    private var borderSectionDivider: NSView!
    private var borderSectionLabel: NSTextField!
    private var selfieSectionLabel: NSTextField!
    private var audioSectionLabel: NSTextField!
    private var audioToggle: NSSwitch!
    private var exportMuted: Bool = false

    private var videoAsset: AVAsset?
    private var videoDuration: CMTime = .zero
    private var trimStartTime: CMTime = .zero
    private var trimEndTime: CMTime = .zero
    private var timeObserverToken: Any?

    // Zoom properties
    private var zoomMode: ZoomMode = .noZoom
    private var zoomFactor: CGFloat = 1.0
    private var panX: CGFloat = 0.0  // -1 to 1 (left to right)
    private var panY: CGFloat = 0.0  // -1 to 1 (bottom to top)

    // Recording mode (used to determine if borders should be added)
    private var recordingMode: RecordingMode = .fullScreen

    private var selfieVideoURL: URL?
    private var selfieOverlayEvents: [SelfieOverlayEvent] = []
    private var selfieStartOffset: TimeInterval = 0
    private var selfieOverlayEnabled: Bool = true

    // Selfie drag/resize state
    private enum SelfieDragMode { case none, move, resize }
    private enum SelfieResizeEdge { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }
    private var previewInteractionView: PreviewInteractionView!
    private var selfieDragIndicator: CALayer?  // Lightweight visual indicator during drag
    private var selfieDragOffset: CGPoint = .zero
    private var dragStartNormRect: CGRect = .zero  // Selfie rect at drag start (normalized)
    private var selfieDragMode: SelfieDragMode = .none
    private var resizeAnchorNorm: CGPoint = .zero  // Fixed corner in normalized coords during resize
    private var selfieAspectRatio: CGFloat = 4.0 / 3.0  // Width/height ratio of the selfie

    private let backgroundColors: [NSColor] = [
        NSColor.black,
        NSColor.white,
        NSColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1.0),
        NSColor(red: 0.10, green: 0.45, blue: 0.90, alpha: 1.0),
        NSColor(red: 0.18, green: 0.80, blue: 0.55, alpha: 1.0),
        NSColor(red: 0.95, green: 0.76, blue: 0.18, alpha: 1.0),
        NSColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1.0),
        NSColor(red: 0.76, green: 0.24, blue: 0.90, alpha: 1.0),
        NSColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0),
        NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0),
        NSColor(red: 0.03, green: 0.55, blue: 0.46, alpha: 1.0),
        NSColor(red: 0.15, green: 0.10, blue: 0.35, alpha: 1.0)
    ]
    private var backgroundImages: [NSImage] = []
    private var selectedBackgroundColorIndex: Int = 0
    private var selectedBackgroundImageIndex: Int? = nil
    private var borderEnabled: Bool = true
    private var borderWidth: CGFloat = 100
    private var useCustomBackgroundColor: Bool = false
    private var customBackgroundColor: NSColor = .black

    init(videoURL: URL, clickEvents: [ClickEventNew] = [], cursorPositions: [CursorPositionNew]? = nil, recordingStartTime: Date = Date(), initialZoomMode: ZoomMode = .noZoom, recordingMode: RecordingMode = .fullScreen) {
        self.videoURL = videoURL
        self.clickEvents = clickEvents
        self.cursorPositions = cursorPositions
        self.recordingStartTime = recordingStartTime
        self.zoomMode = initialZoomMode
        self.recordingMode = recordingMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let mainView = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0).cgColor
        // Allow the view to resize with the window
        mainView.autoresizingMask = [.width, .height]
        view = mainView
        // Don't set preferredContentSize - allow free resizing
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backgroundImages = generateBackgroundImages()
        selectedBackgroundImageIndex = backgroundImages.isEmpty ? nil : 0
        setupUI()
        loadSelfieOverlayData()
        zoomModePopup.selectItem(at: zoomMode.rawValue)
        loadVideo()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Update player layer frame when view resizes
        updatePreviewDecorations()
        updateSelfieIndicatorPosition()
    }

    private func setupUI() {
        // Video player view (left side) - with resizing support
        playerView = NSView()
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.layer?.cornerRadius = 10
        view.addSubview(playerView)

        // Selfie drag interaction overlay (transparent, sits on top of playerView)
        previewInteractionView = PreviewInteractionView()
        previewInteractionView.wantsLayer = true
        playerView.addSubview(previewInteractionView)
        setupSelfieInteraction()

        // Playback controls
        playPauseButton = NSButton()
        playPauseButton.title = "▶"
        playPauseButton.bezelStyle = .rounded
        playPauseButton.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)
        view.addSubview(playPauseButton)

        // Timeline view (new custom timeline with blade tool)
        timelineView = TimelineView()
        timelineView.delegate = self
        timelineView.wantsLayer = true
        timelineView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        timelineView.layer?.cornerRadius = 8
        view.addSubview(timelineView)

        // Timeline scroll bar (below timeline)
        timelineScrollBar = TimelineScrollBar()
        timelineScrollBar.translatesAutoresizingMaskIntoConstraints = false
        timelineScrollBar.onScrollPositionChanged = { [weak self] scrollPosition in
            guard let self = self else { return }
            let maxPanOffset = max(0, (self.timelineView.bounds.width * self.timelineView.zoomLevel) - self.timelineView.bounds.width)
            let newPanOffset = scrollPosition * maxPanOffset
            self.timelineView.setPanOffset(newPanOffset)
        }
        view.addSubview(timelineScrollBar)

        // Blade tool button (toggle: click to activate, click again to deactivate)
        bladeToolButton = NSButton()
        bladeToolButton.title = "✂ Blade Tool"
        bladeToolButton.bezelStyle = .texturedRounded
        bladeToolButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        bladeToolButton.target = self
        bladeToolButton.action = #selector(toggleBladeTool)
        bladeToolButton.setButtonType(.pushOnPushOff)
        bladeToolButton.state = .off
        view.addSubview(bladeToolButton)

        // Right panel (export + settings)
        rightPanel = NSView()
        rightPanel.wantsLayer = true
        rightPanel.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        rightPanel.layer?.cornerRadius = 12
        rightPanel.layer?.borderWidth = 1
        rightPanel.layer?.borderColor = NSColor(white: 0.2, alpha: 1.0).cgColor
        view.addSubview(rightPanel)

        rightPanelTitle = createLabel(text: "Export", fontSize: 14, weight: .semibold, color: .white)
        rightPanel.addSubview(rightPanelTitle)

        // Canvas color controls
        backgroundSectionLabel = createLabel(text: "Background", fontSize: 13, weight: .semibold, color: .white)
        rightPanel.addSubview(backgroundSectionLabel)

        colorsLabel = createLabel(text: "Colors", fontSize: 12, weight: .medium, color: NSColor(white: 0.85, alpha: 1.0))
        rightPanel.addSubview(colorsLabel)

        colorsStackRow1 = NSStackView()
        colorsStackRow1.orientation = .horizontal
        colorsStackRow1.distribution = .fillEqually
        colorsStackRow1.spacing = 6
        rightPanel.addSubview(colorsStackRow1)

        colorsStackRow2 = NSStackView()
        colorsStackRow2.orientation = .horizontal
        colorsStackRow2.distribution = .fillEqually
        colorsStackRow2.spacing = 6
        rightPanel.addSubview(colorsStackRow2)

        for (index, color) in backgroundColors.enumerated() {
            let button = createColorSwatch(color: color, index: index)
            if index < 6 {
                colorsStackRow1.addArrangedSubview(button)
            } else {
                colorsStackRow2.addArrangedSubview(button)
            }
        }

        imagesLabel = createLabel(text: "Images", fontSize: 12, weight: .medium, color: NSColor(white: 0.85, alpha: 1.0))
        rightPanel.addSubview(imagesLabel)

        imagesStackRow1 = NSStackView()
        imagesStackRow1.orientation = .horizontal
        imagesStackRow1.distribution = .fillEqually
        imagesStackRow1.spacing = 6
        rightPanel.addSubview(imagesStackRow1)

        imagesStackRow2 = NSStackView()
        imagesStackRow2.orientation = .horizontal
        imagesStackRow2.distribution = .fillEqually
        imagesStackRow2.spacing = 6
        rightPanel.addSubview(imagesStackRow2)

        imagesStackRow3 = NSStackView()
        imagesStackRow3.orientation = .horizontal
        imagesStackRow3.distribution = .fillEqually
        imagesStackRow3.spacing = 6
        rightPanel.addSubview(imagesStackRow3)

        // Distribute images: 4 per row across 3 rows (12 total)
        for (index, image) in backgroundImages.enumerated() {
            let button = createImageSwatch(image: image, index: index)
            if index < 4 {
                imagesStackRow1.addArrangedSubview(button)
            } else if index < 8 {
                imagesStackRow2.addArrangedSubview(button)
            } else {
                imagesStackRow3.addArrangedSubview(button)
            }
        }

        // --- Border section ---
        borderSectionDivider = createSectionDivider()
        rightPanel.addSubview(borderSectionDivider)

        borderSectionLabel = createLabel(text: "Border", fontSize: 13, weight: .semibold, color: .white)
        rightPanel.addSubview(borderSectionLabel)

        borderToggle = NSSwitch()
        borderToggle.state = borderEnabled ? .on : .off
        borderToggle.target = self
        borderToggle.action = #selector(borderToggleChanged)
        rightPanel.addSubview(borderToggle)

        borderWidthLabel = createLabel(text: "Width: \(Int(borderWidth))", fontSize: 12, weight: .medium, color: NSColor(white: 0.65, alpha: 1.0))
        rightPanel.addSubview(borderWidthLabel)

        borderWidthSlider = NSSlider(value: Double(borderWidth), minValue: 1, maxValue: 300, target: self, action: #selector(borderWidthChanged))
        borderWidthSlider.isContinuous = true
        borderWidthSlider.numberOfTickMarks = 0
        rightPanel.addSubview(borderWidthSlider)

        // Hidden color well — still used internally for custom color tracking
        canvasColorWell = NSColorWell()
        canvasColorWell.color = .black
        canvasColorWell.target = self
        canvasColorWell.action = #selector(customColorPicked)

        // --- Selfie Camera section ---
        selfieSectionLabel = createLabel(text: "Selfie Camera", fontSize: 13, weight: .semibold, color: .white)
        selfieSectionLabel.isHidden = true
        rightPanel.addSubview(selfieSectionLabel)

        selfieToggle = NSSwitch()
        selfieToggle.state = .on
        selfieToggle.target = self
        selfieToggle.action = #selector(selfieToggleChanged)
        selfieToggle.isHidden = true
        rightPanel.addSubview(selfieToggle)

        // --- Audio section ---
        audioSectionLabel = createLabel(text: "Audio", fontSize: 13, weight: .semibold, color: .white)
        rightPanel.addSubview(audioSectionLabel)

        audioToggle = NSSwitch()
        audioToggle.state = .on  // on = audio enabled (not muted)
        audioToggle.target = self
        audioToggle.action = #selector(audioToggleChanged)
        rightPanel.addSubview(audioToggle)

        // --- Zoom Mode section ---
        zoomModeLabel = createLabel(text: "Zoom Mode", fontSize: 13, weight: .semibold, color: .white)
        rightPanel.addSubview(zoomModeLabel)

        zoomModePopup = NSPopUpButton()
        zoomModePopup.addItem(withTitle: "No Zoom")
        zoomModePopup.addItem(withTitle: "Zoom on Clicks")
        zoomModePopup.addItem(withTitle: "Follow Cursor")
        zoomModePopup.target = self
        zoomModePopup.action = #selector(zoomModeChanged)
        rightPanel.addSubview(zoomModePopup)

        // Export button - prominent call-to-action
        exportButton = NSButton()
        exportButton.bezelStyle = .regularSquare
        exportButton.target = self
        exportButton.action = #selector(exportEditedVideo)
        exportButton.wantsLayer = true
        exportButton.layer?.cornerRadius = 10
        exportButton.layer?.backgroundColor = NSColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1.0).cgColor
        exportButton.isBordered = false

        // Use attributed title for white text
        let exportTitle = NSAttributedString(
            string: "Export Video",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 16, weight: .bold)
            ]
        )
        exportButton.attributedTitle = exportTitle
        rightPanel.addSubview(exportButton)

        // Export progress indicator
        exportProgressIndicator = NSProgressIndicator()
        exportProgressIndicator.style = .bar
        exportProgressIndicator.isIndeterminate = false
        exportProgressIndicator.minValue = 0
        exportProgressIndicator.maxValue = 100
        exportProgressIndicator.isHidden = true
        rightPanel.addSubview(exportProgressIndicator)

        // Exit button - explicit quit option
        exitButton = NSButton()
        exitButton.bezelStyle = .regularSquare
        exitButton.target = self
        exitButton.action = #selector(exitApplication)
        exitButton.wantsLayer = true
        exitButton.layer?.cornerRadius = 8
        exitButton.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1.0).cgColor
        exitButton.layer?.borderWidth = 1
        exitButton.layer?.borderColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        exitButton.isBordered = false

        let exitTitle = NSAttributedString(
            string: "Exit",
            attributes: [
                .foregroundColor: NSColor(white: 0.8, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
        exitButton.attributedTitle = exitTitle
        rightPanel.addSubview(exitButton)

        // Layout
        layoutUI()
    }

    private func layoutUI() {
        // Subviews use Auto Layout
        [playerView, previewInteractionView, playPauseButton, timelineView,
         selfieToggle, selfieSectionLabel,
         audioToggle, audioSectionLabel,
         zoomModeLabel, zoomModePopup, bladeToolButton,
         exportButton, exportProgressIndicator, exitButton, rightPanel, rightPanelTitle,
         backgroundSectionLabel, colorsLabel, colorsStackRow1, colorsStackRow2,
         imagesLabel, imagesStackRow1, imagesStackRow2, imagesStackRow3,
         borderToggle, borderSectionDivider, borderSectionLabel, borderWidthLabel, borderWidthSlider].forEach {
            $0?.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // Video player - flexible size, fills space between left edge and right panel
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            playerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            playerView.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -16),
            playerView.bottomAnchor.constraint(equalTo: bladeToolButton.topAnchor, constant: -12),

            // Selfie interaction overlay - matches playerView bounds
            previewInteractionView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            previewInteractionView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            previewInteractionView.topAnchor.constraint(equalTo: playerView.topAnchor),
            previewInteractionView.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),

            // Blade tool button - below video player
            bladeToolButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bladeToolButton.bottomAnchor.constraint(equalTo: playPauseButton.topAnchor, constant: -12),
            bladeToolButton.widthAnchor.constraint(equalToConstant: 110),
            bladeToolButton.heightAnchor.constraint(equalToConstant: 32),

            // Play/pause button - near bottom left
            playPauseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            playPauseButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 40),
            playPauseButton.heightAnchor.constraint(equalToConstant: 40),

            // Timeline view - next to play button
            timelineView.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 12),
            timelineView.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -16),
            timelineView.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            timelineView.heightAnchor.constraint(equalToConstant: 100),

            // Timeline scroll bar - directly below timeline
            timelineScrollBar.leadingAnchor.constraint(equalTo: timelineView.leadingAnchor),
            timelineScrollBar.trailingAnchor.constraint(equalTo: timelineView.trailingAnchor),
            timelineScrollBar.topAnchor.constraint(equalTo: timelineView.bottomAnchor, constant: 4),
            timelineScrollBar.heightAnchor.constraint(equalToConstant: 16),

            // Right panel - fixed width on right side
            rightPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            rightPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            rightPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            rightPanel.widthAnchor.constraint(equalToConstant: 300),

            rightPanelTitle.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            rightPanelTitle.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 14),

            // Background section
            backgroundSectionLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            backgroundSectionLabel.topAnchor.constraint(equalTo: rightPanelTitle.bottomAnchor, constant: 14),

            colorsLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            colorsLabel.topAnchor.constraint(equalTo: backgroundSectionLabel.bottomAnchor, constant: 10),

            colorsStackRow1.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            colorsStackRow1.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            colorsStackRow1.topAnchor.constraint(equalTo: colorsLabel.bottomAnchor, constant: 6),
            colorsStackRow1.heightAnchor.constraint(equalToConstant: 24),

            colorsStackRow2.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            colorsStackRow2.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            colorsStackRow2.topAnchor.constraint(equalTo: colorsStackRow1.bottomAnchor, constant: 6),
            colorsStackRow2.heightAnchor.constraint(equalToConstant: 24),

            imagesLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            imagesLabel.topAnchor.constraint(equalTo: colorsStackRow2.bottomAnchor, constant: 12),

            imagesStackRow1.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            imagesStackRow1.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            imagesStackRow1.topAnchor.constraint(equalTo: imagesLabel.bottomAnchor, constant: 6),
            imagesStackRow1.heightAnchor.constraint(equalToConstant: 38),

            imagesStackRow2.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            imagesStackRow2.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            imagesStackRow2.topAnchor.constraint(equalTo: imagesStackRow1.bottomAnchor, constant: 6),
            imagesStackRow2.heightAnchor.constraint(equalToConstant: 38),

            imagesStackRow3.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            imagesStackRow3.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            imagesStackRow3.topAnchor.constraint(equalTo: imagesStackRow2.bottomAnchor, constant: 6),
            imagesStackRow3.heightAnchor.constraint(equalToConstant: 38),

            // --- Border section ---
            borderSectionDivider.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            borderSectionDivider.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            borderSectionDivider.topAnchor.constraint(equalTo: imagesStackRow3.bottomAnchor, constant: 14),
            borderSectionDivider.heightAnchor.constraint(equalToConstant: 1),

            borderSectionLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            borderSectionLabel.topAnchor.constraint(equalTo: borderSectionDivider.bottomAnchor, constant: 12),

            borderToggle.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            borderToggle.centerYAnchor.constraint(equalTo: borderSectionLabel.centerYAnchor),

            borderWidthLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            borderWidthLabel.topAnchor.constraint(equalTo: borderSectionLabel.bottomAnchor, constant: 10),

            borderWidthSlider.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            borderWidthSlider.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            borderWidthSlider.topAnchor.constraint(equalTo: borderWidthLabel.bottomAnchor, constant: 6),

            // --- Selfie Camera section ---
            selfieSectionLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            selfieSectionLabel.topAnchor.constraint(equalTo: borderWidthSlider.bottomAnchor, constant: 14),

            selfieToggle.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            selfieToggle.centerYAnchor.constraint(equalTo: selfieSectionLabel.centerYAnchor),

            // --- Audio section ---
            audioSectionLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            audioSectionLabel.topAnchor.constraint(equalTo: selfieSectionLabel.bottomAnchor, constant: 14),

            audioToggle.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            audioToggle.centerYAnchor.constraint(equalTo: audioSectionLabel.centerYAnchor),

            // --- Zoom Mode section ---
            zoomModeLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            zoomModeLabel.topAnchor.constraint(equalTo: audioSectionLabel.bottomAnchor, constant: 14),

            zoomModePopup.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            zoomModePopup.centerYAnchor.constraint(equalTo: zoomModeLabel.centerYAnchor),
            zoomModePopup.widthAnchor.constraint(equalToConstant: 150),

            // Exit button - right panel, very bottom
            exitButton.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            exitButton.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            exitButton.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -16),
            exitButton.heightAnchor.constraint(equalToConstant: 36),

            // Export button - right panel, above exit button (prominent size)
            exportButton.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            exportButton.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            exportButton.bottomAnchor.constraint(equalTo: exitButton.topAnchor, constant: -10),
            exportButton.heightAnchor.constraint(equalToConstant: 52),

            // Export progress - right panel, above export button
            exportProgressIndicator.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            exportProgressIndicator.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -16),
            exportProgressIndicator.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -12),
        ])
    }

    private func createLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.alignment = .left
        return label
    }

    private func createSectionDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        return divider
    }

    private func createColorSwatch(color: NSColor, index: Int) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = (selectedBackgroundImageIndex == nil && index == selectedBackgroundColorIndex) ? 2 : 0
        button.layer?.borderColor = NSColor.white.cgColor
        button.tag = index
        button.target = self
        button.action = #selector(colorSwatchClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func createImageSwatch(image: NSImage, index: Int) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.borderWidth = (selectedBackgroundImageIndex == index) ? 2 : 0
        button.layer?.borderColor = NSColor.white.cgColor
        button.layer?.masksToBounds = true
        button.image = image
        button.imageScaling = .scaleProportionallyUpOrDown
        button.imagePosition = .imageOnly
        button.tag = index
        button.target = self
        button.action = #selector(imageSwatchClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 38)
        ])
        return button
    }

    private func updateColorSwatchSelection() {
        let allColorButtons = colorsStackRow1.arrangedSubviews + colorsStackRow2.arrangedSubviews
        for (idx, view) in allColorButtons.enumerated() {
            view.layer?.borderWidth = (!useCustomBackgroundColor && selectedBackgroundImageIndex == nil && idx == selectedBackgroundColorIndex) ? 2 : 0
        }
    }

    private func updateImageSwatchSelection() {
        let allImageButtons = imagesStackRow1.arrangedSubviews + imagesStackRow2.arrangedSubviews + imagesStackRow3.arrangedSubviews
        for (idx, view) in allImageButtons.enumerated() {
            view.layer?.borderWidth = (selectedBackgroundImageIndex == idx) ? 2 : 0
        }
    }

    @objc private func colorSwatchClicked(_ sender: NSButton) {
        selectedBackgroundColorIndex = sender.tag
        selectedBackgroundImageIndex = nil
        useCustomBackgroundColor = false
        borderEnabled = true
        borderToggle.state = .on
        canvasColorWell.color = backgroundColors[selectedBackgroundColorIndex]
        updateColorSwatchSelection()
        updateImageSwatchSelection()
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func imageSwatchClicked(_ sender: NSButton) {
        selectedBackgroundImageIndex = sender.tag
        borderEnabled = true
        borderToggle.state = .on
        updateColorSwatchSelection()
        updateImageSwatchSelection()
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func borderToggleChanged() {
        borderEnabled = (borderToggle.state == .on)
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func selfieToggleChanged() {
        selfieOverlayEnabled = (selfieToggle.state == .on)
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func audioToggleChanged() {
        exportMuted = (audioToggle.state == .off)
        player?.isMuted = exportMuted
    }

    @objc private func borderWidthChanged() {
        borderWidth = CGFloat(borderWidthSlider.doubleValue)
        borderWidthLabel.stringValue = "Width: \(Int(borderWidth))"
        if !borderEnabled {
            borderEnabled = true
            borderToggle.state = .on
        }
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func customColorPicked() {
        useCustomBackgroundColor = true
        selectedBackgroundImageIndex = nil
        customBackgroundColor = canvasColorWell.color
        borderEnabled = true
        borderToggle.state = .on
        updateColorSwatchSelection()
        updateImageSwatchSelection()
        updatePreviewComposition()
        updatePreviewDecorations()
    }

    @objc private func exitApplication() {
        print("EditorViewController: Exit button clicked - cleaning up temp files")
        cleanupTempFiles()
        print("EditorViewController: Terminating app")
        NSApplication.shared.terminate(nil)
    }

    private func cleanupTempFiles() {
        // Remove screen recording temp file
        let fm = FileManager.default
        if fm.fileExists(atPath: videoURL.path) {
            do {
                try fm.removeItem(at: videoURL)
                print("EditorViewController: Removed screen temp: \(videoURL.lastPathComponent)")
            } catch {
                print("EditorViewController: Failed to remove screen temp: \(error.localizedDescription)")
            }
        }

        // Remove selfie camera temp file
        if let selfieURL = selfieVideoURL, fm.fileExists(atPath: selfieURL.path) {
            do {
                try fm.removeItem(at: selfieURL)
                print("EditorViewController: Removed selfie temp: \(selfieURL.lastPathComponent)")
            } catch {
                print("EditorViewController: Failed to remove selfie temp: \(error.localizedDescription)")
            }
        }

        // Remove any segmented temp files from export
        let tempDir = fm.temporaryDirectory
        if let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasSuffix("-segmented.mp4") {
                try? fm.removeItem(at: file)
                print("EditorViewController: Removed segmented temp: \(file.lastPathComponent)")
            }
        }
    }


    private func generateBackgroundImages() -> [NSImage] {
        let size = NSSize(width: 320, height: 180)
        // 12 gradient combinations for variety
        let gradients: [(NSColor, NSColor)] = [
            // Row 1: Cool tones
            (NSColor(red: 0.04, green: 0.12, blue: 0.18, alpha: 1.0), NSColor(red: 0.24, green: 0.12, blue: 0.36, alpha: 1.0)),  // Dark blue to purple
            (NSColor(red: 0.08, green: 0.10, blue: 0.20, alpha: 1.0), NSColor(red: 0.10, green: 0.48, blue: 0.72, alpha: 1.0)),  // Navy to blue
            (NSColor(red: 0.05, green: 0.15, blue: 0.25, alpha: 1.0), NSColor(red: 0.20, green: 0.60, blue: 0.80, alpha: 1.0)),  // Dark teal to cyan
            (NSColor(red: 0.12, green: 0.08, blue: 0.22, alpha: 1.0), NSColor(red: 0.45, green: 0.25, blue: 0.70, alpha: 1.0)),  // Deep purple to violet

            // Row 2: Warm tones
            (NSColor(red: 0.20, green: 0.06, blue: 0.12, alpha: 1.0), NSColor(red: 0.90, green: 0.42, blue: 0.22, alpha: 1.0)),  // Dark red to orange
            (NSColor(red: 0.25, green: 0.12, blue: 0.08, alpha: 1.0), NSColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1.0)),  // Brown to gold
            (NSColor(red: 0.22, green: 0.08, blue: 0.18, alpha: 1.0), NSColor(red: 0.85, green: 0.35, blue: 0.55, alpha: 1.0)),  // Dark magenta to pink
            (NSColor(red: 0.18, green: 0.10, blue: 0.05, alpha: 1.0), NSColor(red: 0.70, green: 0.50, blue: 0.25, alpha: 1.0)),  // Dark brown to tan

            // Row 3: Nature & neutrals
            (NSColor(red: 0.12, green: 0.22, blue: 0.12, alpha: 1.0), NSColor(red: 0.12, green: 0.62, blue: 0.52, alpha: 1.0)),  // Forest to teal
            (NSColor(red: 0.08, green: 0.18, blue: 0.15, alpha: 1.0), NSColor(red: 0.30, green: 0.75, blue: 0.45, alpha: 1.0)),  // Dark green to lime
            (NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0), NSColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1.0)),  // Black to gray
            (NSColor(red: 0.08, green: 0.04, blue: 0.16, alpha: 1.0), NSColor(red: 0.56, green: 0.20, blue: 0.86, alpha: 1.0)),  // Deep indigo to purple
        ]

        return gradients.enumerated().map { index, colors in
            let image = NSImage(size: size)
            image.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            let base = NSGradient(starting: colors.0, ending: colors.1)
            let angle = CGFloat(30 + (index * 8))
            base?.draw(in: rect, angle: angle)
            image.unlockFocus()
            return image
        }
    }

    private func updatePreviewDecorations() {
        guard let playerViewLayer = playerView.layer,
              let container = previewContainerLayer,
              let background = previewBackgroundLayer,
              let asset = videoAsset,
              let videoTrack = asset.tracks(withMediaType: .video).first else { return }

        let videoSize = videoTrack.naturalSize
        let border = borderEnabled ? borderWidth : 0
        let canvasSize = CGSize(width: videoSize.width + border * 2, height: videoSize.height + border * 2)

        let available = playerViewLayer.bounds
        let scale = min(available.width / canvasSize.width, available.height / canvasSize.height)
        let renderSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let origin = CGPoint(
            x: (available.width - renderSize.width) / 2,
            y: (available.height - renderSize.height) / 2
        )

        // Disable implicit animations for instant resize (no lag)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        container.frame = CGRect(origin: origin, size: renderSize)
        background.frame = container.bounds

        let resolvedColor = useCustomBackgroundColor ? customBackgroundColor : backgroundColors[selectedBackgroundColorIndex]
        if let index = selectedBackgroundImageIndex,
           index < backgroundImages.count,
           let cgImage = backgroundImages[index].cgImage(forProposedRect: nil, context: nil, hints: nil) {
            background.contents = cgImage
            background.contentsGravity = .resizeAspectFill
            background.backgroundColor = nil
            // Also set playerView background to a dark color for image backgrounds
            playerViewLayer.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0).cgColor
        } else {
            background.contents = nil
            background.backgroundColor = resolvedColor.cgColor
            // Match playerView background to selected color so no black bars show
            playerViewLayer.backgroundColor = resolvedColor.cgColor
        }

        // Player layer fills the entire container — the compositor handles borders,
        // rounded corners, and background within its rendered output.
        playerLayer?.frame = container.bounds

        CATransaction.commit()
    }

    private func loadVideo() {
        print("EditorViewController: Loading video: \(videoURL.path)")

        // Verify file exists
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            print("EditorViewController: ERROR - Video file does not exist")
            showError("Video file not found")
            return
        }

        // Ensure playerView layer is properly configured
        if playerView.layer == nil {
            playerView.wantsLayer = true
            playerView.layer = CALayer()
        }

        // Load video asset
        videoAsset = AVAsset(url: videoURL)

        guard let asset = videoAsset else {
            print("EditorViewController: ERROR - Failed to load video asset")
            showError("Failed to load video")
            return
        }
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("EditorViewController: ERROR - No video track found")
            showError("No video track found")
            return
        }

        // Create player item and player
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)

        guard let player = player, let layer = playerView.layer else {
            print("EditorViewController: ERROR - Failed to create player or layer")
            showError("Failed to initialize video player")
            return
        }

        // Create preview container and background layers
        let container = CALayer()
        let background = CALayer()
        container.addSublayer(background)

        // Create player layer
        let newPlayerLayer = AVPlayerLayer(player: player)
        newPlayerLayer.videoGravity = .resizeAspect
        container.addSublayer(newPlayerLayer)

        previewContainerLayer = container
        previewBackgroundLayer = background
        playerLayer = newPlayerLayer
        layer.addSublayer(container)

        print("EditorViewController: Player layer added successfully")

        // Get video duration
        Task {
            do {
                let assetDuration = try await asset.load(.duration)
                let trackDuration = videoTrack.timeRange.duration
                let trackSeconds = CMTimeGetSeconds(trackDuration)
                let assetSeconds = CMTimeGetSeconds(assetDuration)

                if trackSeconds.isFinite && trackSeconds > 0 {
                    videoDuration = trackDuration
                } else {
                    videoDuration = assetDuration
                }

                let durationSeconds = CMTimeGetSeconds(videoDuration)

                print("EditorViewController: Video duration: \(durationSeconds)s")

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    self.trimEndTime = self.videoDuration

                    // Recompute selfie offset from actual media durations.
                    // Both recordings stop at approximately the same time, so:
                    //   startOffset = screenDuration - selfieDuration
                    // This is far more accurate than wall-clock Date() estimates
                    // which suffer from variable startup/callback latencies.
                    if let selfieURL = self.selfieVideoURL, !self.selfieOverlayEvents.isEmpty {
                        let selfieAsset = AVAsset(url: selfieURL)
                        if let selfieTrack = selfieAsset.tracks(withMediaType: .video).first {
                            let selfieDuration = CMTimeGetSeconds(selfieTrack.timeRange.duration)
                            let oldOffset = self.selfieStartOffset
                            self.selfieStartOffset = durationSeconds - selfieDuration
                            print("EditorViewController: Recomputed selfie offset from durations: screen=\(durationSeconds)s, selfie=\(selfieDuration)s, offset=\(self.selfieStartOffset)s (was \(oldOffset)s)")
                        }
                    }

                    // Setup timeline view
                    self.timelineView.sourceDuration = durationSeconds
                    self.setupTimelineMarkers()

                    self.setupTimeObserver()

                    self.updatePreviewComposition()
                    self.updatePreviewDecorations()

                    print("EditorViewController: Video editor ready")
                }
            } catch {
                print("EditorViewController: ERROR loading video duration: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.showError("Failed to load video duration: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updatePreviewComposition() {
        guard let playerItem = player?.currentItem else { return }

        if zoomMode == .noZoom && !borderEnabled {
            playerItem.videoComposition = nil
            return
        }

        applyZoomCompositionForPreview()
    }

    private func applyZoomCompositionForPreview() {
        guard let asset = videoAsset,
              let videoTrack = asset.tracks(withMediaType: .video).first,
              let playerItem = player?.currentItem else {
            print("EditorViewController: Cannot apply zoom composition - missing asset or player")
            return
        }

        let videoSize = videoTrack.naturalSize
        let duration = asset.duration
        let canvasSize: CGSize
        if borderEnabled {
            let border = max(1, borderWidth) * 2
            canvasSize = CGSize(width: videoSize.width + border, height: videoSize.height + border)
        } else {
            canvasSize = videoSize
        }

        print("EditorViewController: Applying zoom composition for preview - mode: \(zoomMode), clicks: \(clickEvents.count), cursors: \(cursorPositions?.count ?? 0)")

        // Group clicks for zoom-on-click mode
        let clickGroups = zoomMode == .zoomOnClick ? groupClicks(clickEvents, maxTimeDiff: 3.0) : []

        // Convert zoom mode to tracking mode
        let trackingMode: TrackingMode
        switch zoomMode {
        case .zoomOnClick:
            trackingMode = .zoomOnClicks
        case .followCursor:
            trackingMode = .followCursor
        case .noZoom:
            trackingMode = .recordWindow
        }

        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.customVideoCompositorClass = ZoomVideoCompositor.self

        // Create instruction for the entire duration
        let resolvedColor = useCustomBackgroundColor ? customBackgroundColor : backgroundColors[selectedBackgroundColorIndex]
        let backgroundColor = selectedBackgroundImageIndex == nil ? CIColor(color: resolvedColor) : nil
        let backgroundImage: CIImage?
        if let index = selectedBackgroundImageIndex {
            let image = backgroundImages[index]
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                backgroundImage = CIImage(cgImage: cgImage)
            } else {
                backgroundImage = nil
            }
        } else {
            backgroundImage = nil
        }

        // Load selfie asset for preview (uses AVAssetImageGenerator, not composition track)
        var previewSelfieAsset: AVAsset? = nil
        var previewSelfieVideoSize: CGSize? = nil
        if selfieOverlayEnabled, let selfieURL = selfieVideoURL, !selfieOverlayEvents.isEmpty {
            let sAsset = AVAsset(url: selfieURL)
            if let sTrack = sAsset.tracks(withMediaType: .video).first {
                previewSelfieAsset = sAsset
                previewSelfieVideoSize = sTrack.naturalSize
                print("EditorViewController: Loaded selfie asset for preview - size: \(sTrack.naturalSize)")
            }
        }

        let instruction = ZoomCompositionInstruction(
            trackID: videoTrack.trackID,
            sourceTrackID: videoTrack.trackID,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            videoSize: videoSize,
            clickGroups: clickGroups,
            cursorPositions: cursorPositions ?? [],
            trackingMode: trackingMode,
            recordingStartTime: recordingStartTime,
            subtitles: [],  // No subtitles in preview
            timingOffset: 0.0,
            addBorders: false,
            selfieAsset: previewSelfieAsset,
            selfieOverlayEvents: selfieOverlayEvents,
            selfieVideoSize: previewSelfieVideoSize,
            selfieStartOffset: selfieStartOffset,
            backgroundColor: backgroundColor,
            backgroundImage: backgroundImage,
            borderEnabled: borderEnabled,
            borderWidth: borderWidth,
            canvasSize: canvasSize
        )

        videoComposition.instructions = [instruction]

        // Apply composition to player item
        playerItem.videoComposition = videoComposition

        print("EditorViewController: Zoom composition applied to preview")
    }

    private func groupClicks(_ events: [ClickEventNew], maxTimeDiff: TimeInterval) -> [[ClickEventNew]] {
        guard !events.isEmpty else { return [] }

        var groups: [[ClickEventNew]] = []
        var currentGroup: [ClickEventNew] = [events[0]]

        for i in 1..<events.count {
            let timeDiff = events[i].captureTimestamp.timeIntervalSince(events[i - 1].captureTimestamp)

            if timeDiff < maxTimeDiff {
                currentGroup.append(events[i])
            } else {
                groups.append(currentGroup)
                currentGroup = [events[i]]
            }
        }

        groups.append(currentGroup)
        return groups
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.016, preferredTimescale: CMTimeScale(NSEC_PER_SEC)) // ~60fps
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }

            let sourceTime = CMTimeGetSeconds(time)

            // Convert source time to display time for timeline
            if let displayTime = self.sourceTimeToDisplayTime(sourceTime) {
                // Update timeline view with display time
                self.timelineView.currentTime = displayTime

                // Check if we've reached the end of current segment
                if let currentSegment = self.findSegmentContaining(sourceTime: sourceTime) {
                    let segmentEnd = currentSegment.sourceEndTime
                    if sourceTime >= segmentEnd - 0.05 { // Small threshold to avoid overshooting
                        // Try to jump to next segment
                        if let nextSegment = self.getNextSegment(after: currentSegment) {
                            let nextSourceTime = CMTime(seconds: nextSegment.sourceStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                            self.player?.seek(to: nextSourceTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        } else {
                            // No more segments, pause playback
                            self.player?.pause()
                            self.updatePlayPauseButton(isPlaying: false)
                        }
                    }
                }
            } else {
                // Source time is in a deleted segment, skip to next valid segment
                if let nextSegment = self.getNextSegment(afterSourceTime: sourceTime) {
                    let nextSourceTime = CMTime(seconds: nextSegment.sourceStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                    self.player?.seek(to: nextSourceTime, toleranceBefore: .zero, toleranceAfter: .zero)
                } else {
                    // No more segments, pause
                    self.player?.pause()
                    self.updatePlayPauseButton(isPlaying: false)
                }
            }

            if time >= self.trimEndTime {
                self.player?.pause()
                self.updatePlayPauseButton(isPlaying: false)
            }
        }
    }

    @objc private func togglePlayPause() {
        guard let player = player else { return }

        if player.rate > 0 {
            player.pause()
            updatePlayPauseButton(isPlaying: false)
        } else {
            // Remove selfie drag indicator — compositor takes over during playback
            removeSelfieIndicatorIfNeeded()

            // Check if we need to restart from beginning
            let currentSourceTime = CMTimeGetSeconds(player.currentItem?.currentTime() ?? .zero)
            let segments = timelineView.segments

            // If at end or in a deleted segment, restart from first segment
            if segments.isEmpty == false {
                let lastSegment = segments.last!
                if currentSourceTime >= lastSegment.sourceEndTime - 0.1 || sourceTimeToDisplayTime(currentSourceTime) == nil {
                    // Restart from first segment
                    let firstSegment = segments.first!
                    let startTime = CMTime(seconds: firstSegment.sourceStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                    player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            player.play()
            updatePlayPauseButton(isPlaying: true)
        }
    }

    private func updatePlayPauseButton(isPlaying: Bool) {
        playPauseButton.title = isPlaying ? "⏸" : "▶"
    }


    @objc private func zoomModeChanged() {
        zoomMode = ZoomMode(rawValue: zoomModePopup.indexOfSelectedItem) ?? .noZoom
        print("EditorViewController: Zoom mode changed to \(zoomMode)")

        updatePreviewComposition()

        // Update timeline markers when zoom mode changes
        setupTimelineMarkers()
    }

    @objc private func toggleBladeTool() {
        // Toggle blade tool state
        timelineView.isBladeToolActive = (bladeToolButton.state == .on)

        // Update button appearance
        if timelineView.isBladeToolActive {
            bladeToolButton.contentTintColor = NSColor.systemYellow
            print("EditorViewController: Blade tool activated")
        } else {
            bladeToolButton.contentTintColor = nil
            print("EditorViewController: Blade tool deactivated (selection mode)")
        }
    }

    @objc private func exportEditedVideo() {
        print("EditorViewController: Export button clicked")

        guard let asset = videoAsset else {
            showError("No video loaded")
            return
        }

        // Pause playback
        player?.pause()
        updatePlayPauseButton(isPlaying: false)

        // Show progress
        exportProgressIndicator.isHidden = false
        exportProgressIndicator.doubleValue = 0
        exportButton.isEnabled = false

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

        // Determine which export method to use
        // Use VideoProcessor for:
        // - Zoom modes (zoomOnClick, followCursor)
        // - Borders/backgrounds
        // - Selfie overlay
        let needsZoomProcessing = zoomMode != .noZoom
        let needsBorders = borderEnabled
        let needsSelfieOverlay = selfieOverlayEnabled && !selfieOverlayEvents.isEmpty && selfieVideoURL != nil
        let needsVideoProcessor = needsZoomProcessing || needsBorders || needsSelfieOverlay

        print("EditorViewController: Export - zoomMode: \(zoomMode), clickEvents: \(clickEvents.count), cursorPositions: \(cursorPositions?.count ?? 0)")
        print("EditorViewController: Export decision - needsZoom: \(needsZoomProcessing), needsBorders: \(needsBorders), using VideoProcessor: \(needsVideoProcessor)")

        if needsVideoProcessor {
            print("EditorViewController: Using VideoProcessor for zoom/selfie export")
            // Use VideoProcessor for automatic zoom modes (even if no events - will just not zoom)
            exportVideoWithVideoProcessor(outputURL: outputURL) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    self.exportProgressIndicator.isHidden = true
                    self.exportButton.isEnabled = true

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
        } else {
            print("EditorViewController: Using simple export (no zoom processing)")
            // Use simple export for manual zoom or no zoom
            exportVideoWithEdits(asset: asset, outputURL: outputURL) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.exportProgressIndicator.isHidden = true
                self.exportButton.isEnabled = true

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
    }

    private func exportVideoWithVideoProcessor(outputURL: URL, completion: @escaping (Error?) -> Void) {
        print("EditorViewController: exportVideoWithVideoProcessor called")
        print("EditorViewController: - Click events: \(clickEvents.count)")
        print("EditorViewController: - Cursor positions: \(cursorPositions?.count ?? 0)")
        print("EditorViewController: - Zoom mode: \(zoomMode)")
        print("EditorViewController: - Recording mode: \(recordingMode)")

        // Get active segments from timeline (respects blade tool cuts)
        let activeSegments = timelineView.getActiveSegments()
        print("EditorViewController: - Active segments: \(activeSegments.count)")

        guard !activeSegments.isEmpty else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active segments to export"]))
            return
        }

        // Check if we need to create a pre-edited video with segments
        let needsSegmentEdit = activeSegments.count > 1 ||
            activeSegments.first?.sourceStartTime != 0 ||
            abs((activeSegments.last?.sourceEndTime ?? 0) - CMTimeGetSeconds(videoDuration)) > 0.1

        print("EditorViewController: - Needs segment edit: \(needsSegmentEdit)")

        if needsSegmentEdit {
            // Create a temporary video with only the active segments
            let tempSegmentedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-segmented.mp4")

            createVideoFromSegments(segments: activeSegments, outputURL: tempSegmentedURL) { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    completion(error)
                    return
                }

                // Now process the segmented video with zoom
                self.processVideoWithZoom(inputURL: tempSegmentedURL, outputURL: outputURL, completion: completion)
            }
        } else {
            // Use original video directly (no cuts made)
            processVideoWithZoom(inputURL: videoURL, outputURL: outputURL, completion: completion)
        }
    }

    private func createVideoFromSegments(segments: [TimelineSegment], outputURL: URL, completion: @escaping (Error?) -> Void) {
        let asset = AVAsset(url: videoURL)
        let composition = AVMutableComposition()

        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"]))
            return
        }

        var compositionAudioTracks: [(source: AVAssetTrack, composition: AVMutableCompositionTrack)] = []
        if !exportMuted {
            for audioTrack in asset.tracks(withMediaType: .audio) {
                if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    compositionAudioTracks.append((source: audioTrack, composition: compositionAudioTrack))
                }
            }
        }

        var insertTime: CMTime = .zero

        do {
            for segment in segments {
                let startTime = CMTime(seconds: segment.sourceStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let endTime = CMTime(seconds: segment.sourceEndTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let timeRange = CMTimeRange(start: startTime, end: endTime)

                print("EditorViewController: Creating segment \(segment.sourceStartTime)s - \(segment.sourceEndTime)s at \(CMTimeGetSeconds(insertTime))s")

                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)

                for pair in compositionAudioTracks {
                    try pair.composition.insertTimeRange(timeRange, of: pair.source, at: insertTime)
                }

                insertTime = CMTimeAdd(insertTime, timeRange.duration)
            }
        } catch {
            completion(error)
            return
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                print("EditorViewController: Segmented video created successfully")
                completion(nil)
            } else {
                completion(exportSession.error ?? NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Segment export failed"]))
            }
        }
    }

    private func trimVideo(from inputURL: URL, to outputURL: URL, start: CMTime, end: CMTime, completion: @escaping (Error?) -> Void) {
        let asset = AVAsset(url: inputURL)
        let composition = AVMutableComposition()
        let timeRange = CMTimeRange(start: start, end: end)

        do {
            if let videoTrack = asset.tracks(withMediaType: .video).first,
               let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            }

            if !exportMuted {
                for audioTrack in asset.tracks(withMediaType: .audio) {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                    }
                }
            }

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
                return
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4

            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    completion(nil)
                } else {
                    completion(exportSession.error ?? NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Trim failed"]))
                }
            }
        } catch {
            completion(error)
        }
    }

    private func processVideoWithZoom(inputURL: URL, outputURL: URL, completion: @escaping (Error?) -> Void) {
        print("EditorViewController: processVideoWithZoom called")

        let trackingMode: TrackingMode
        switch zoomMode {
        case .zoomOnClick:
            trackingMode = .zoomOnClicks
        case .followCursor:
            trackingMode = .followCursor
        case .noZoom:
            // Shouldn't get here, but handle it anyway
            trackingMode = .recordWindow
        }

        print("EditorViewController: Calling VideoProcessor.processVideo with:")
        print("  - inputURL: \(inputURL)")
        print("  - outputURL: \(outputURL)")
        print("  - clickEvents count: \(clickEvents.count)")
        print("  - trackingMode: \(trackingMode)")
        print("  - addBorders: \(recordingMode == .selectedWindow)")

        let adjustedSelfieOffset = selfieStartOffset - CMTimeGetSeconds(trimStartTime)
        let resolvedColor = useCustomBackgroundColor ? customBackgroundColor : backgroundColors[selectedBackgroundColorIndex]
        let backgroundColor = selectedBackgroundImageIndex == nil ? resolvedColor : nil
        let backgroundImage = selectedBackgroundImageIndex != nil ? backgroundImages[selectedBackgroundImageIndex ?? 0] : nil

        // Only include selfie video if there are overlay events configured
        // Otherwise the selfie track causes export issues
        let effectiveSelfieURL = (!selfieOverlayEnabled || selfieOverlayEvents.isEmpty) ? nil : selfieVideoURL
        print("EditorViewController: Selfie overlay events: \(selfieOverlayEvents.count), using selfie: \(effectiveSelfieURL != nil)")

        let processor = VideoProcessor()
        processor.processVideo(
            inputURL: inputURL,
            outputURL: outputURL,
            clickEvents: clickEvents,
            cursorPositions: cursorPositions,
            trackingMode: trackingMode,
            recordingStartTime: recordingStartTime,
            subtitles: nil,
            addBorders: false,
            selfieVideoURL: effectiveSelfieURL,
            selfieOverlayEvents: selfieOverlayEvents,
            selfieStartOffset: adjustedSelfieOffset,
            backgroundColor: backgroundColor,
            backgroundImage: backgroundImage,
            borderEnabled: borderEnabled,
            borderWidth: borderWidth,
            muteAudio: exportMuted,
            progress: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.exportProgressIndicator.doubleValue = progress * 100
                }
            },
            completion: completion
        )
    }

    private func loadSelfieOverlayData() {
        // Only load selfie data if the video file actually exists
        // This prevents stale data from previous sessions causing issues
        if let path = UserDefaults.standard.string(forKey: "selfieVideoURL") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                selfieVideoURL = url
                selfieStartOffset = UserDefaults.standard.double(forKey: "selfieStartOffset")

                if let data = UserDefaults.standard.data(forKey: "selfieOverlayEvents") {
                    if let decoded = try? JSONDecoder().decode([SelfieOverlayEvent].self, from: data) {
                        selfieOverlayEvents = decoded
                        print("EditorViewController: Loaded selfie overlay with \(decoded.count) events from URL: \(path)")
                    }
                }
            } else {
                // Clear stale selfie data
                print("EditorViewController: Selfie video file not found, clearing stale data")
                UserDefaults.standard.removeObject(forKey: "selfieVideoURL")
                UserDefaults.standard.removeObject(forKey: "selfieStartOffset")
                UserDefaults.standard.removeObject(forKey: "selfieOverlayEvents")
            }
        }

        // Show selfie section only when selfie data is available
        let hasSelfie = selfieVideoURL != nil && !selfieOverlayEvents.isEmpty
        selfieToggle.isHidden = !hasSelfie
        selfieSectionLabel.isHidden = !hasSelfie
    }

    private func exportVideoWithEdits(asset: AVAsset, outputURL: URL, completion: @escaping (Error?) -> Void) {
        // Create composition with segments
        let composition = AVMutableComposition()

        // Get active segments (non-deleted) from timeline
        let activeSegments = timelineView.getActiveSegments()
        guard !activeSegments.isEmpty else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active segments to export"]))
            return
        }

        print("EditorViewController: Exporting \(activeSegments.count) segments")

        // Add video track
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"]))
            return
        }

        // Add all audio tracks (source may have system audio + mic audio as separate tracks)
        var compositionAudioTracks: [(source: AVAssetTrack, composition: AVMutableCompositionTrack)] = []
        if !exportMuted {
            let audioTracks = asset.tracks(withMediaType: .audio)
            for audioTrack in audioTracks {
                if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    compositionAudioTracks.append((source: audioTrack, composition: compositionAudioTrack))
                }
            }
        }
        print("EditorViewController: Added \(compositionAudioTracks.count) audio track(s) to composition\(exportMuted ? " (muted)" : "")")

        // Insert each active segment
        var insertTime: CMTime = .zero

        do {
            for segment in activeSegments {
                let startTime = CMTime(seconds: segment.sourceStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let endTime = CMTime(seconds: segment.sourceEndTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let timeRange = CMTimeRange(start: startTime, end: endTime)

                print("EditorViewController: Inserting segment \(segment.sourceStartTime)s - \(segment.sourceEndTime)s at \(CMTimeGetSeconds(insertTime))s")

                // Insert video
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)

                // Insert all audio tracks
                for pair in compositionAudioTracks {
                    try pair.composition.insertTimeRange(timeRange, of: pair.source, at: insertTime)
                }

                insertTime = CMTimeAdd(insertTime, timeRange.duration)
            }
        } catch {
            completion(error)
            return
        }

        // Create video composition for canvas color (if not black) or zoom (if not 1.0)
        var videoComposition: AVMutableVideoComposition? = nil
        let needsCanvasColor = canvasColorWell.color != .black
        let needsZoom = zoomFactor != 1.0

        if needsCanvasColor || needsZoom {
            // Create base video composition
            videoComposition = AVMutableVideoComposition(propertiesOf: composition)

            // Get video size
            let videoSize = compositionVideoTrack.naturalSize

            // Create instruction and layer instruction
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, end: composition.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)

            // Apply zoom transformation if needed
            if needsZoom {
                var transform = compositionVideoTrack.preferredTransform
                let scale = zoomFactor
                let maxPanX = videoSize.width * (scale - 1.0) / (2.0 * scale)
                let maxPanY = videoSize.height * (scale - 1.0) / (2.0 * scale)
                let translateX = -panX * maxPanX
                let translateY = panY * maxPanY
                transform = transform.scaledBy(x: scale, y: scale)
                transform = transform.translatedBy(x: translateX / scale, y: -translateY / scale)
                layerInstruction.setTransform(transform, at: .zero)
            }

            instruction.layerInstructions = [layerInstruction]
            videoComposition!.instructions = [instruction]

            // Apply canvas color if needed
            if needsCanvasColor {
                let backgroundLayer = CALayer()
                backgroundLayer.frame = CGRect(origin: .zero, size: videoSize)
                backgroundLayer.backgroundColor = canvasColorWell.color.cgColor

                let videoLayer = CALayer()
                videoLayer.frame = CGRect(origin: .zero, size: videoSize)

                let parentLayer = CALayer()
                parentLayer.frame = CGRect(origin: .zero, size: videoSize)
                parentLayer.addSublayer(backgroundLayer)
                parentLayer.addSublayer(videoLayer)

                videoComposition!.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
            }
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
                self?.exportProgressIndicator.doubleValue = Double(session.progress) * 100
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

    private func updateAutomaticZoom(at time: CMTime) {
        guard let playerLayer = playerLayer, let asset = videoAsset else {
            print("EditorViewController: updateAutomaticZoom - playerLayer or asset is nil")
            return
        }

        // Get video size
        let videoSize: CGSize
        if let track = asset.tracks(withMediaType: .video).first {
            videoSize = track.naturalSize
        } else {
            print("EditorViewController: updateAutomaticZoom - no video track found")
            return
        }

        let currentTimeSeconds = CMTimeGetSeconds(time)

        // Calculate zoom state
        let zoomState = getZoomState(at: time, videoSize: videoSize)

        // Log every second
        if Int(currentTimeSeconds * 10) % 10 == 0 {
            print("EditorViewController: updateAutomaticZoom at \(String(format: "%.1f", currentTimeSeconds))s - isZooming: \(zoomState.isZooming), progress: \(zoomState.progress), bbox: \(zoomState.boundingBox != nil ? "yes" : "no")")
        }

        if zoomState.isZooming, let bbox = zoomState.boundingBox {
            // Apply zoom transformation
            applyZoomTransform(to: playerLayer, zoomState: zoomState, bbox: bbox, videoSize: videoSize)
        } else {
            // Reset to no zoom
            CATransaction.begin()
            CATransaction.setDisableActions(true) // Disable implicit animations for smoother transition
            playerLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private func applyZoomTransform(to layer: AVPlayerLayer, zoomState: ZoomState, bbox: BoundingBox, videoSize: CGSize) {
        let progress = zoomState.progress
        let bounds = layer.bounds

        // Calculate zoom factor
        let fullWidth = videoSize.width
        let fullHeight = videoSize.height
        let zoomFactorX = fullWidth / bbox.width
        let zoomFactorY = fullHeight / bbox.height
        let zoomFactor = min(zoomFactorX, zoomFactorY, 2.2)

        let currentZoom = 1.0 + (zoomFactor - 1.0) * progress

        // Calculate center position
        let fullCenterX = fullWidth / 2
        let fullCenterY = fullHeight / 2
        let targetCenterX = bbox.centerX
        let targetCenterY = bbox.centerY

        let currentCenterX = fullCenterX + (targetCenterX - fullCenterX) * progress
        let currentCenterY = fullCenterY + (targetCenterY - fullCenterY) * progress

        // Calculate translation to center the zoom on the target
        let translateX = (fullWidth / 2 - currentCenterX) * currentZoom
        let translateY = (fullHeight / 2 - currentCenterY) * currentZoom

        // Build transform
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, translateX, translateY, 0)
        transform = CATransform3DScale(transform, currentZoom, currentZoom, 1.0)

        // Apply transform without animation for smoother real-time playback
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    private func getZoomState(at time: CMTime, videoSize: CGSize) -> ZoomState {
        let currentTimeSeconds = CMTimeGetSeconds(time)

        if zoomMode == .followCursor {
            return getCursorFollowState(at: currentTimeSeconds, videoSize: videoSize)
        }

        if zoomMode == .zoomOnClick {
            return getZoomOnClickState(at: currentTimeSeconds, videoSize: videoSize)
        }

        return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
    }

    private func getZoomOnClickState(at currentTimeSeconds: TimeInterval, videoSize: CGSize) -> ZoomState {
        let zoomInDuration: TimeInterval = 1.0
        let holdDuration: TimeInterval = 0.4
        let zoomOutDuration: TimeInterval = 1.0

        // Group clicks that happen close together
        let clickGroups = groupClicks(clickEvents, maxTimeDiff: 3.0)

        // Log once when first called
        if currentTimeSeconds < 0.1 {
            print("EditorViewController: getZoomOnClickState - found \(clickGroups.count) click groups from \(clickEvents.count) events")
        }

        for group in clickGroups {
            guard let firstClick = group.first else { continue }

            let triggerTime = firstClick.captureTimestamp.timeIntervalSince(recordingStartTime)
            let timeDiff = currentTimeSeconds - triggerTime

            let zoomStartTime: TimeInterval = 0.0
            let zoomEndTime = zoomInDuration + holdDuration + zoomOutDuration

            if timeDiff >= zoomStartTime && timeDiff <= zoomEndTime {
                print("EditorViewController: ZOOM ACTIVE! time=\(String(format: "%.2f", currentTimeSeconds))s, triggerTime=\(String(format: "%.2f", triggerTime))s, timeDiff=\(String(format: "%.2f", timeDiff))s")

                let boundingBox = calculateBoundingBox(for: group, videoSize: videoSize)

                var progress: CGFloat = 0

                if timeDiff < zoomInDuration {
                    progress = CGFloat(timeDiff / zoomInDuration)
                    progress = easeInOutCubic(progress)
                } else if timeDiff < zoomInDuration + holdDuration {
                    progress = 1.0
                } else {
                    let outProgress = (timeDiff - zoomInDuration - holdDuration) / zoomOutDuration
                    progress = 1.0 - easeInOutCubic(CGFloat(outProgress))
                }

                return ZoomState(isZooming: true, progress: progress, boundingBox: boundingBox)
            }
        }

        return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
    }

    private func getCursorFollowState(at currentTimeSeconds: TimeInterval, videoSize: CGSize) -> ZoomState {
        guard let cursorPositions = cursorPositions, !cursorPositions.isEmpty else {
            return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
        }

        let targetTime = recordingStartTime.addingTimeInterval(currentTimeSeconds)

        // Find closest cursor position
        var closestPosition: CursorPositionNew?
        var minDiff: TimeInterval = .infinity

        for position in cursorPositions {
            let diff = abs(position.captureTimestamp.timeIntervalSince(targetTime))
            if diff < minDiff {
                minDiff = diff
                closestPosition = position
            }
        }

        guard let position = closestPosition else {
            return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
        }

        // Convert cursor position to video coordinates
        let x = (position.x / position.screenWidth) * videoSize.width
        let y = (position.y / position.screenHeight) * videoSize.height

        // Create zoom area around cursor
        let zoomAreaSize: CGFloat = 400.0
        let boundingBox = BoundingBox(
            centerX: x,
            centerY: y,
            width: zoomAreaSize,
            height: zoomAreaSize
        )

        return ZoomState(isZooming: true, progress: 1.0, boundingBox: boundingBox)
    }

    private func calculateBoundingBox(for clicks: [ClickEventNew], videoSize: CGSize) -> BoundingBox {
        guard !clicks.isEmpty else {
            return BoundingBox(centerX: videoSize.width / 2, centerY: videoSize.height / 2, width: 400, height: 400)
        }

        var minX: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var minY: CGFloat = .infinity
        var maxY: CGFloat = -.infinity

        for click in clicks {
            let x = (click.x / click.screenWidth) * videoSize.width
            let y = (click.y / click.screenHeight) * videoSize.height

            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        let width = max(maxX - minX, 100)
        let height = max(maxY - minY, 100)
        let padding: CGFloat = 150

        return BoundingBox(
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            width: width + padding,
            height: height + padding
        )
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Editor Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    // MARK: - Timeline Setup

    private func setupTimelineMarkers() {
        // Set click event times
        let clickTimes = clickEvents.map { event in
            event.captureTimestamp.timeIntervalSince(recordingStartTime)
        }
        timelineView.clickEventTimes = clickTimes

        // Calculate and set zoom regions if in zoom mode
        if zoomMode == .zoomOnClick {
            var zoomRegions: [ZoomRegion] = []

            let clickGroups = groupClicks(clickEvents, maxTimeDiff: 3.0)

            let zoomInDuration: TimeInterval = 1.0
            let preClickPause: TimeInterval = 0.4
            let postClickPause: TimeInterval = 0.4
            let zoomOutDuration: TimeInterval = 1.0

            for group in clickGroups {
                guard !group.isEmpty else { continue }

                let firstClick = group[0]
                let lastClick = group[group.count - 1]

                let firstTriggerTime = firstClick.captureTimestamp.timeIntervalSince(recordingStartTime)
                let lastTriggerTime = lastClick.captureTimestamp.timeIntervalSince(recordingStartTime)

                // Zoom in region
                let zoomInStart = firstTriggerTime - (zoomInDuration + preClickPause)
                let zoomInEnd = firstTriggerTime - preClickPause
                zoomRegions.append(ZoomRegion(
                    startTime: zoomInStart,
                    endTime: zoomInEnd,
                    type: .zoomIn
                ))

                // Hold region (during clicks)
                let holdStart = firstTriggerTime - preClickPause
                let holdEnd = lastTriggerTime + postClickPause
                zoomRegions.append(ZoomRegion(
                    startTime: holdStart,
                    endTime: holdEnd,
                    type: .hold
                ))

                // Zoom out region
                let zoomOutStart = lastTriggerTime + postClickPause
                let zoomOutEnd = zoomOutStart + zoomOutDuration
                zoomRegions.append(ZoomRegion(
                    startTime: zoomOutStart,
                    endTime: zoomOutEnd,
                    type: .zoomOut
                ))
            }

            timelineView.zoomRegions = zoomRegions
        }
    }

    // MARK: - Selfie Drag Interaction

    private func setupSelfieInteraction() {
        previewInteractionView.onMouseDown = { [weak self] location in
            self?.handleSelfieMouseDown(at: location) ?? false
        }
        previewInteractionView.onMouseDragged = { [weak self] location in
            self?.handleSelfieMouseDragged(to: location)
        }
        previewInteractionView.onMouseUp = { [weak self] location in
            self?.handleSelfieMouseUp(at: location)
        }
        previewInteractionView.onMouseMoved = { [weak self] location in
            self?.handleSelfieMouseMoved(at: location)
        }
    }

    /// Detect which edge/corner of the selfie rect the point is on, or nil if in the interior.
    private func selfieResizeEdge(at point: CGPoint, viewRect: CGRect) -> SelfieResizeEdge? {
        let t: CGFloat = 10  // border hit thickness
        let outerRect = viewRect.insetBy(dx: -t, dy: -t)
        let innerRect = viewRect.insetBy(dx: t, dy: t)
        guard outerRect.contains(point) && !innerRect.contains(point) else { return nil }

        let nearLeft = point.x < viewRect.origin.x + t
        let nearRight = point.x > viewRect.maxX - t
        let nearBottom = point.y < viewRect.origin.y + t  // macOS: y=0 is bottom
        let nearTop = point.y > viewRect.maxY - t

        // Corners (check first since they overlap two edges)
        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        // Edges
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        if nearRight { return .right }
        return nil
    }

    /// Returns the appropriate resize cursor for the given edge/corner.
    private func resizeCursor(for edge: SelfieResizeEdge) -> NSCursor {
        switch edge {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return makeDiagonalCursor(nwse: true)
        case .topRight, .bottomLeft:
            return makeDiagonalCursor(nwse: false)
        }
    }

    /// Creates a diagonal resize cursor (NW-SE or NE-SW).
    private func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            if nwse {
                path.move(to: NSPoint(x: 2, y: 14)); path.line(to: NSPoint(x: 14, y: 2))
            } else {
                path.move(to: NSPoint(x: 2, y: 2)); path.line(to: NSPoint(x: 14, y: 14))
            }
            path.lineWidth = 2; path.stroke()
            // Arrowheads
            NSColor.black.setFill()
            let h1 = NSBezierPath(); let h2 = NSBezierPath()
            if nwse {
                h1.move(to: NSPoint(x: 2, y: 14)); h1.line(to: NSPoint(x: 7, y: 14)); h1.line(to: NSPoint(x: 2, y: 9)); h1.close()
                h2.move(to: NSPoint(x: 14, y: 2)); h2.line(to: NSPoint(x: 9, y: 2)); h2.line(to: NSPoint(x: 14, y: 7)); h2.close()
            } else {
                h1.move(to: NSPoint(x: 2, y: 2)); h1.line(to: NSPoint(x: 7, y: 2)); h1.line(to: NSPoint(x: 2, y: 7)); h1.close()
                h2.move(to: NSPoint(x: 14, y: 14)); h2.line(to: NSPoint(x: 9, y: 14)); h2.line(to: NSPoint(x: 14, y: 9)); h2.close()
            }
            h1.fill(); h2.fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
    }

    private func handleSelfieMouseDown(at point: CGPoint) -> Bool {
        guard selfieOverlayEnabled,
              let viewRect = currentSelfieViewRect(),
              let normRect = currentSelfieNormalizedRect() else { return false }
        let hitRect = viewRect.insetBy(dx: -10, dy: -10)
        guard hitRect.contains(point) else { return false }

        // Pause playback during drag
        player?.pause()
        updatePlayPauseButton(isPlaying: false)

        dragStartNormRect = normRect
        selfieAspectRatio = normRect.width / normRect.height

        // Decide mode: border/corner = resize, interior = move
        if let edge = selfieResizeEdge(at: point, viewRect: viewRect) {
            selfieDragMode = .resize
            // Anchor is the opposite corner/edge midpoint
            switch edge {
            case .topLeft:     resizeAnchorNorm = CGPoint(x: normRect.maxX, y: normRect.origin.y)
            case .topRight:    resizeAnchorNorm = CGPoint(x: normRect.origin.x, y: normRect.origin.y)
            case .bottomLeft:  resizeAnchorNorm = CGPoint(x: normRect.maxX, y: normRect.maxY)
            case .bottomRight: resizeAnchorNorm = CGPoint(x: normRect.origin.x, y: normRect.maxY)
            case .top:         resizeAnchorNorm = CGPoint(x: normRect.midX, y: normRect.origin.y)
            case .bottom:      resizeAnchorNorm = CGPoint(x: normRect.midX, y: normRect.maxY)
            case .left:        resizeAnchorNorm = CGPoint(x: normRect.maxX, y: normRect.midY)
            case .right:       resizeAnchorNorm = CGPoint(x: normRect.origin.x, y: normRect.midY)
            }
        } else {
            selfieDragMode = .move
            selfieDragOffset = CGPoint(x: point.x - viewRect.origin.x, y: point.y - viewRect.origin.y)
        }

        // Remove any existing indicator from a previous drag
        selfieDragIndicator?.removeFromSuperlayer()

        // Create a drag indicator with the actual selfie snapshot
        let indicator = CALayer()
        indicator.frame = viewRect
        indicator.cornerRadius = min(viewRect.width, viewRect.height) * 0.12
        indicator.masksToBounds = true
        indicator.borderWidth = 2
        indicator.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        // Grab a frame from the selfie video for the indicator
        if let selfieURL = selfieVideoURL,
           let currentTime = player?.currentItem?.currentTime() {
            let selfieAsset = AVAsset(url: selfieURL)
            let generator = AVAssetImageGenerator(asset: selfieAsset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            let selfieTime = CMTime(seconds: max(0, CMTimeGetSeconds(currentTime) - selfieStartOffset), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: selfieTime, actualTime: nil) {
                indicator.contents = cgImage
                indicator.contentsGravity = .resizeAspectFill
            }
        }

        playerView.layer?.addSublayer(indicator)
        selfieDragIndicator = indicator

        NSCursor.closedHand.set()
        return true
    }

    private func handleSelfieMouseDragged(to point: CGPoint) {
        guard let canvasRect = videoRectInPlayerView() else { return }

        if selfieDragMode == .resize {
            handleSelfieResizeDrag(to: point, canvasRect: canvasRect)
        } else {
            handleSelfieMoveDrag(to: point, canvasRect: canvasRect)
        }
    }

    private func handleSelfieMoveDrag(to point: CGPoint, canvasRect: CGRect) {
        let selfieW = dragStartNormRect.width
        let selfieH = dragStartNormRect.height
        let viewW = selfieW * canvasRect.width
        let viewH = selfieH * canvasRect.height

        let newViewX = point.x - selfieDragOffset.x
        let newViewY = point.y - selfieDragOffset.y

        let clampedX = max(canvasRect.origin.x, min(newViewX, canvasRect.maxX - viewW))
        let clampedY = max(canvasRect.origin.y, min(newViewY, canvasRect.maxY - viewH))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selfieDragIndicator?.frame = CGRect(x: clampedX, y: clampedY, width: viewW, height: viewH)
        CATransaction.commit()
    }

    private func handleSelfieResizeDrag(to point: CGPoint, canvasRect: CGRect) {
        // Convert mouse and anchor to normalized coords
        let mouseNormX = (point.x - canvasRect.origin.x) / canvasRect.width
        let mouseNormY = (point.y - canvasRect.origin.y) / canvasRect.height

        // Distance from anchor to mouse determines the new size
        let dx = abs(mouseNormX - resizeAnchorNorm.x)
        let dy = abs(mouseNormY - resizeAnchorNorm.y)

        // Use the larger axis to determine size, then constrain by aspect ratio
        var newW: CGFloat
        var newH: CGFloat
        if dx / selfieAspectRatio > dy {
            newW = dx
            newH = dx / selfieAspectRatio
        } else {
            newH = dy
            newW = dy * selfieAspectRatio
        }

        // Enforce minimum size (5% of canvas)
        let minSize: CGFloat = 0.05
        newW = max(minSize * selfieAspectRatio, min(newW, 1.0))
        newH = max(minSize, min(newH, 1.0))

        // Position: anchor is the fixed corner, the rect extends toward the mouse
        let newX = mouseNormX < resizeAnchorNorm.x ? resizeAnchorNorm.x - newW : resizeAnchorNorm.x
        let newY = mouseNormY < resizeAnchorNorm.y ? resizeAnchorNorm.y - newH : resizeAnchorNorm.y

        // Clamp to canvas bounds
        let clampedX = max(0, min(newX, 1.0 - newW))
        let clampedY = max(0, min(newY, 1.0 - newH))

        // Convert to view coords
        let viewFrame = CGRect(
            x: canvasRect.origin.x + clampedX * canvasRect.width,
            y: canvasRect.origin.y + clampedY * canvasRect.height,
            width: newW * canvasRect.width,
            height: newH * canvasRect.height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selfieDragIndicator?.frame = viewFrame
        selfieDragIndicator?.cornerRadius = min(viewFrame.width, viewFrame.height) * 0.12
        CATransaction.commit()
    }

    private func handleSelfieMouseUp(at point: CGPoint) {
        guard let canvasRect = videoRectInPlayerView(),
              let indicator = selfieDragIndicator else {
            selfieDragMode = .none
            NSCursor.arrow.set()
            return
        }

        // Convert final indicator frame to normalized coords
        let normW = indicator.frame.width / canvasRect.width
        let normH = indicator.frame.height / canvasRect.height
        var normX = (indicator.frame.origin.x - canvasRect.origin.x) / canvasRect.width
        var normY = (indicator.frame.origin.y - canvasRect.origin.y) / canvasRect.height
        normX = max(0, min(normX, 1.0 - normW))
        normY = max(0, min(normY, 1.0 - normH))

        // Remove the white border to look like the actual overlay
        indicator.borderWidth = 0

        // Commit the new position and size
        selfieOverlayEvents = [SelfieOverlayEvent(
            time: 0, x: normX, y: normY,
            width: normW, height: normH
        )]

        applyZoomCompositionForPreview()

        selfieDragMode = .none
        print("EditorViewController: Selfie \(selfieDragMode == .resize ? "resized" : "moved") to (\(normX), \(normY)) size (\(normW), \(normH))")
        NSCursor.arrow.set()
    }

    /// Remove the selfie drag indicator (called when playback starts so compositor takes over)
    private func removeSelfieIndicatorIfNeeded() {
        selfieDragIndicator?.removeFromSuperlayer()
        selfieDragIndicator = nil
    }

    /// Reposition the selfie indicator when the view resizes
    private func updateSelfieIndicatorPosition() {
        guard let indicator = selfieDragIndicator,
              let viewRect = currentSelfieViewRect() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = viewRect
        indicator.cornerRadius = min(viewRect.width, viewRect.height) * 0.12
        CATransaction.commit()
    }

    private func handleSelfieMouseMoved(at point: CGPoint) {
        guard selfieOverlayEnabled else { NSCursor.arrow.set(); return }
        guard selfieDragMode == .none else { return }  // Don't change cursor during active drag
        if let viewRect = currentSelfieViewRect() {
            if let edge = selfieResizeEdge(at: point, viewRect: viewRect) {
                resizeCursor(for: edge).set()
                return
            }
            let hitRect = viewRect.insetBy(dx: -10, dy: -10)
            if hitRect.contains(point) {
                NSCursor.openHand.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    // MARK: - Coordinate Conversion

    /// Compute the absolute frame of the full canvas (including borders) within playerView.
    /// The container layer is sized to the canvas (video + borders), so selfie normalized
    /// coordinates (relative to the canvas) map correctly to this rect.
    private func videoRectInPlayerView() -> CGRect? {
        guard let container = previewContainerLayer else { return nil }
        return container.frame
    }


    /// Convert a view point (in playerView coords) to normalized 0..1 video coords
    private func viewPointToNormalized(_ point: CGPoint) -> CGPoint? {
        guard let videoRect = videoRectInPlayerView() else { return nil }
        return CGPoint(
            x: (point.x - videoRect.origin.x) / videoRect.width,
            y: (point.y - videoRect.origin.y) / videoRect.height
        )
    }

    /// Get the current selfie overlay rect in normalized video coords based on playback time
    private func currentSelfieNormalizedRect() -> CGRect? {
        guard !selfieOverlayEvents.isEmpty else { return nil }
        guard let currentTime = player?.currentItem?.currentTime() else { return nil }
        let timeSeconds = CMTimeGetSeconds(currentTime)

        let sorted = selfieOverlayEvents.sorted { $0.time < $1.time }
        var last = sorted[0]
        for event in sorted {
            if event.time <= timeSeconds {
                last = event
            } else {
                break
            }
        }

        return CGRect(x: last.x, y: last.y, width: last.width, height: last.height)
    }

    /// Get the selfie rect in playerView coordinates (for hit-testing)
    private func currentSelfieViewRect() -> CGRect? {
        guard let normRect = currentSelfieNormalizedRect(),
              let canvasRect = videoRectInPlayerView() else { return nil }
        return CGRect(
            x: canvasRect.origin.x + normRect.origin.x * canvasRect.width,
            y: canvasRect.origin.y + normRect.origin.y * canvasRect.height,
            width: normRect.width * canvasRect.width,
            height: normRect.height * canvasRect.height
        )
    }

    deinit {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
        }
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        print("EditorViewController: Cleaned up")
    }
}

// MARK: - PreviewInteractionView

/// Transparent overlay on the video preview that intercepts mouse events for selfie dragging.
private class PreviewInteractionView: NSView {
    var onMouseDown: ((CGPoint) -> Bool)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?

    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if onMouseDown?(location) == true {
            isDragging = true
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { super.mouseDragged(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        onMouseDragged?(location)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { super.mouseUp(with: event); return }
        isDragging = false
        let location = convert(event.locationInWindow, from: nil)
        onMouseUp?(location)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// MARK: - TimelineViewDelegate

extension EditorViewController: TimelineViewDelegate {
    func timelineView(_ timeline: TimelineView, didSeekToTime displayTime: TimeInterval) {
        // Convert display time to source time
        if let sourceTime = displayTimeToSourceTime(displayTime) {
            let targetTime = CMTime(seconds: sourceTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            // Use zero tolerance for pixel-perfect seeking to exact time (not nearest keyframe)
            player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            print("EditorViewController: Seeking to display time \(displayTime)s -> source time \(sourceTime)s")
        }
    }

    func timelineView(_ timeline: TimelineView, didUpdateSegments segments: [TimelineSegment]) {
        // Segments have been updated (cuts added/removed or segments deleted)
        // Note: All segments in the array are active - deleted segments are removed from the array
        print("EditorViewController: Timeline segments updated - \(segments.count) segments, edited duration: \(timeline.editedDuration)s")
    }

    func timelineViewDidTogglePlayPause(_ timeline: TimelineView) {
        togglePlayPause()
    }

    func timelineView(_ timeline: TimelineView, didChangeBladeToolState isActive: Bool) {
        // Sync button state when blade tool is toggled via keyboard shortcut
        bladeToolButton.state = isActive ? .on : .off
        bladeToolButton.contentTintColor = isActive ? NSColor.systemYellow : nil
    }

    func timelineView(_ timeline: TimelineView, didChangeZoomOrPan zoomLevel: CGFloat, panOffset: CGFloat) {
        // Update scroll bar when timeline zoom or pan changes
        let scrollInfo = timeline.getScrollInfo()
        timelineScrollBar.updateScrollState(visibleFraction: scrollInfo.visibleFraction, scrollPosition: scrollInfo.scrollPosition)
    }
}

// MARK: - Time Conversion Helpers

extension EditorViewController {
    /// Convert source time (position in original video) to display time (position on timeline)
    private func sourceTimeToDisplayTime(_ sourceTime: TimeInterval) -> TimeInterval? {
        let segments = timelineView.segments

        for segment in segments {
            if sourceTime >= segment.sourceStartTime && sourceTime <= segment.sourceEndTime {
                let offsetInSegment = sourceTime - segment.sourceStartTime
                return segment.displayStartTime + offsetInSegment
            }
        }

        return nil // Source time is in a deleted segment
    }

    /// Convert display time (position on timeline) to source time (position in original video)
    private func displayTimeToSourceTime(_ displayTime: TimeInterval) -> TimeInterval? {
        let segments = timelineView.segments

        for segment in segments {
            if displayTime >= segment.displayStartTime && displayTime <= segment.displayEndTime {
                let offsetInSegment = displayTime - segment.displayStartTime
                return segment.sourceStartTime + offsetInSegment
            }
        }

        return nil
    }

    /// Find the segment containing the given source time
    private func findSegmentContaining(sourceTime: TimeInterval) -> TimelineSegment? {
        let segments = timelineView.segments

        for segment in segments {
            if sourceTime >= segment.sourceStartTime && sourceTime <= segment.sourceEndTime {
                return segment
            }
        }

        return nil
    }

    /// Get the next segment after the given segment
    private func getNextSegment(after segment: TimelineSegment) -> TimelineSegment? {
        let segments = timelineView.segments

        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else {
            return nil
        }

        let nextIndex = index + 1
        return nextIndex < segments.count ? segments[nextIndex] : nil
    }

    /// Get the next segment after the given source time
    private func getNextSegment(afterSourceTime sourceTime: TimeInterval) -> TimelineSegment? {
        let segments = timelineView.segments

        for segment in segments {
            if segment.sourceStartTime > sourceTime {
                return segment
            }
        }

        return nil
    }
}
