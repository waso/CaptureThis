import Cocoa
import AVFoundation

// MARK: - Data Models

/// Represents a cut point on the timeline created by the blade tool
struct CutPoint {
    var time: TimeInterval
    var id: UUID = UUID()
}

/// Represents a segment between two cut points
struct TimelineSegment {
    var sourceStartTime: TimeInterval  // Where this content comes from in the original video
    var sourceEndTime: TimeInterval
    var displayStartTime: TimeInterval  // Where this appears on the edited timeline
    var displayEndTime: TimeInterval
    var id: UUID = UUID()

    var sourceDuration: TimeInterval {
        return sourceEndTime - sourceStartTime
    }

    var displayDuration: TimeInterval {
        return displayEndTime - displayStartTime
    }
}

/// Represents a zoom region that will be shown on the timeline
struct ZoomRegion {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var type: ZoomType

    enum ZoomType {
        case zoomIn
        case hold
        case zoomOut
    }
}

// MARK: - Timeline Delegate

protocol TimelineViewDelegate: AnyObject {
    func timelineView(_ timeline: TimelineView, didSeekToTime time: TimeInterval)
    func timelineView(_ timeline: TimelineView, didUpdateSegments segments: [TimelineSegment])
    func timelineViewDidTogglePlayPause(_ timeline: TimelineView)
    func timelineView(_ timeline: TimelineView, didChangeBladeToolState isActive: Bool)
    func timelineView(_ timeline: TimelineView, didChangeZoomOrPan zoomLevel: CGFloat, panOffset: CGFloat)
}

// MARK: - Main Timeline View

class TimelineView: NSView {

    // MARK: - Properties

    weak var delegate: TimelineViewDelegate?

    var sourceDuration: TimeInterval = 0 {  // Original video duration
        didSet {
            if segments.isEmpty {
                // Initialize with one segment covering entire video
                segments = [TimelineSegment(
                    sourceStartTime: 0,
                    sourceEndTime: sourceDuration,
                    displayStartTime: 0,
                    displayEndTime: sourceDuration
                )]
            }
            updateLayout()
        }
    }

    var editedDuration: TimeInterval {  // Duration after cuts/deletions
        return segments.isEmpty ? 0 : segments.last?.displayEndTime ?? 0
    }

    var currentTime: TimeInterval = 0 {
        didSet {
            playheadView.currentTime = currentTime
            updateCurrentTimeDisplay()
        }
    }

    var zoomRegions: [ZoomRegion] = [] {
        didSet {
            markerTrackView.zoomRegions = zoomRegions
        }
    }

    var clickEventTimes: [TimeInterval] = [] {
        didSet {
            markerTrackView.clickEventTimes = clickEventTimes
        }
    }

    private(set) var segments: [TimelineSegment] = [] {
        didSet {
            segmentView.segments = segments
            delegate?.timelineView(self, didUpdateSegments: segments)
        }
    }

    var isBladeToolActive: Bool = false {
        didSet {
            updateCursor()
            selectedSegmentIndex = nil // Clear selection when switching modes
        }
    }

    private var selectedSegmentIndex: Int? = nil {
        didSet {
            segmentView.selectedSegmentIndex = selectedSegmentIndex
        }
    }

    // MARK: - Zoom and Pan Properties

    var zoomLevel: CGFloat = 1.0 {
        didSet {
            let oldZoom = zoomLevel
            zoomLevel = max(1.0, min(zoomLevel, 10.0)) // Clamp between 1.0x and 10x (never smaller than timeline width)

            // Force reset pan when at minimum zoom
            if zoomLevel <= 1.0 {
                panOffset = 0
            }

            updateLayout()
            updatePanOffset()
            notifyZoomPanChanged()

            print("TimelineView: Zoom level changed from \(oldZoom) to \(zoomLevel), panOffset: \(panOffset)")
        }
    }

    private var panOffset: CGFloat = 0 {
        didSet {
            // Prevent any pan offset at minimum zoom
            if zoomLevel <= 1.0 && panOffset != 0 {
                panOffset = 0
                return
            }
            updateLayout()
            notifyZoomPanChanged()
        }
    }

    // MARK: - Subviews

    private let rulerView = TimelineRulerView()
    private let segmentView = SegmentView()
    private let playheadView = PlayheadView()
    private let markerTrackView = MarkerTrackView()
    private let interactionView = TimelineInteractionView()

    private let currentTimeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .right
        return label
    }()

    private let totalTimeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.6, alpha: 1.0)
        label.alignment = .left
        return label
    }()

    private lazy var zoomInButton: NSButton = {
        let button = NSButton()
        button.title = "+"
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        button.target = self
        button.action = #selector(zoomIn)
        return button
    }()

    private lazy var zoomOutButton: NSButton = {
        let button = NSButton()
        button.title = "−"
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        button.target = self
        button.action = #selector(zoomOut)
        return button
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        layer?.cornerRadius = 6

        // Add subviews in order (bottom to top)
        addSubview(segmentView)
        addSubview(markerTrackView)
        addSubview(rulerView)
        addSubview(playheadView)
        addSubview(interactionView)
        addSubview(currentTimeLabel)
        addSubview(totalTimeLabel)
        addSubview(zoomOutButton)
        addSubview(zoomInButton)

        // Setup interaction view
        interactionView.onMouseDown = { [weak self] location in
            self?.handleMouseDown(at: location)
        }

        interactionView.onMouseDragged = { [weak self] location in
            self?.handleMouseDragged(to: location)
        }

        interactionView.onMouseUp = { [weak self] location in
            self?.handleMouseUp(at: location)
        }

        // Segments are initialized via sourceDuration didSet

        setupLayout()
    }

    private func setupLayout() {
        [rulerView, segmentView, playheadView, markerTrackView, interactionView, currentTimeLabel, totalTimeLabel, zoomOutButton, zoomInButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // Time labels at top
            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            currentTimeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 60),

            totalTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            totalTimeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            totalTimeLabel.widthAnchor.constraint(equalToConstant: 60),

            // Zoom buttons - between time labels
            zoomOutButton.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            zoomOutButton.trailingAnchor.constraint(equalTo: zoomInButton.leadingAnchor, constant: -4),
            zoomOutButton.widthAnchor.constraint(equalToConstant: 28),
            zoomOutButton.heightAnchor.constraint(equalToConstant: 22),

            zoomInButton.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            zoomInButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomInButton.widthAnchor.constraint(equalToConstant: 28),
            zoomInButton.heightAnchor.constraint(equalToConstant: 22),

            // Ruler at top (below time labels) - increased padding to show full time labels
            rulerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            rulerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rulerView.topAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor, constant: 4),
            rulerView.heightAnchor.constraint(equalToConstant: 20),

            // Marker track (zoom regions and click events) - below ruler
            markerTrackView.leadingAnchor.constraint(equalTo: rulerView.leadingAnchor),
            markerTrackView.trailingAnchor.constraint(equalTo: rulerView.trailingAnchor),
            markerTrackView.topAnchor.constraint(equalTo: rulerView.bottomAnchor, constant: 2),
            markerTrackView.heightAnchor.constraint(equalToConstant: 16),

            // Segment view - main timeline area
            segmentView.leadingAnchor.constraint(equalTo: rulerView.leadingAnchor),
            segmentView.trailingAnchor.constraint(equalTo: rulerView.trailingAnchor),
            segmentView.topAnchor.constraint(equalTo: markerTrackView.bottomAnchor, constant: 2),
            segmentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // Playhead on top
            playheadView.leadingAnchor.constraint(equalTo: rulerView.leadingAnchor),
            playheadView.trailingAnchor.constraint(equalTo: rulerView.trailingAnchor),
            playheadView.topAnchor.constraint(equalTo: rulerView.topAnchor),
            playheadView.bottomAnchor.constraint(equalTo: segmentView.bottomAnchor),

            // Interaction view covers everything
            interactionView.leadingAnchor.constraint(equalTo: segmentView.leadingAnchor),
            interactionView.trailingAnchor.constraint(equalTo: segmentView.trailingAnchor),
            interactionView.topAnchor.constraint(equalTo: rulerView.topAnchor),
            interactionView.bottomAnchor.constraint(equalTo: segmentView.bottomAnchor),
        ])
    }

    private func updateLayout() {
        let displayDuration = editedDuration
        rulerView.duration = displayDuration
        rulerView.zoomLevel = zoomLevel
        rulerView.panOffset = panOffset

        segmentView.duration = displayDuration
        segmentView.zoomLevel = zoomLevel
        segmentView.panOffset = panOffset

        playheadView.duration = displayDuration
        playheadView.zoomLevel = zoomLevel
        playheadView.panOffset = panOffset

        markerTrackView.duration = displayDuration
        markerTrackView.zoomLevel = zoomLevel
        markerTrackView.panOffset = panOffset

        totalTimeLabel.stringValue = formatTime(displayDuration)
    }

    // MARK: - Interaction Handling

    private var isDraggingPlayhead = false

    private func handleMouseDown(at location: NSPoint) {
        let displayTime = xPositionToTime(location.x)

        // Convert click location to segmentView coordinates to check if clicking on segment bar
        let locationInSegmentView = segmentView.convert(location, from: interactionView)
        let isClickOnSegmentBar = segmentView.bounds.contains(locationInSegmentView)

        if isBladeToolActive {
            // Blade tool: find which segment was clicked and create cut in SOURCE time
            if let segmentIndex = segments.firstIndex(where: {
                $0.displayStartTime <= displayTime && displayTime < $0.displayEndTime
            }) {
                let segment = segments[segmentIndex]
                // Convert display time to source time within this segment
                let offsetInSegment = displayTime - segment.displayStartTime
                let sourceTime = segment.sourceStartTime + offsetInSegment
                addCutPoint(at: sourceTime, in: segmentIndex)
            }
        } else {
            // Normal mode: check if clicking on segment bar or elsewhere
            if isClickOnSegmentBar {
                // Clicking on segment bar area - select segment AND move playhead
                if let segmentIndex = segments.firstIndex(where: {
                    $0.displayStartTime <= displayTime && displayTime < $0.displayEndTime
                }) {
                    selectedSegmentIndex = segmentIndex
                    print("TimelineView: Selected segment \(segmentIndex)")
                    // Also move playhead to clicked position
                    isDraggingPlayhead = true
                    seekToTime(displayTime)
                    updateLayout()
                    return
                }
            }

            // Click on timeline (not on segment bar, or on empty space) - seek and start dragging
            selectedSegmentIndex = nil
            isDraggingPlayhead = true
            seekToTime(displayTime)
            updateLayout()
        }
    }

    private func handleMouseDragged(to location: NSPoint) {
        if isDraggingPlayhead {
            let time = xPositionToTime(location.x)
            seekToTime(time)
        }
    }

    private func handleMouseUp(at location: NSPoint) {
        // Stop dragging playhead
        isDraggingPlayhead = false
    }

    private func seekToTime(_ time: TimeInterval) {
        let clampedTime = max(0, min(time, editedDuration))
        currentTime = clampedTime
        delegate?.timelineView(self, didSeekToTime: clampedTime)
    }

    // MARK: - Cut Point Management

    func addCutPoint(at sourceTime: TimeInterval, in segmentIndex: Int) {
        let segment = segments[segmentIndex]

        // Don't cut too close to segment boundaries
        guard sourceTime > segment.sourceStartTime + 0.1 &&
              sourceTime < segment.sourceEndTime - 0.1 else { return }

        // Split the segment at this point
        let displayOffsetFromStart = sourceTime - segment.sourceStartTime

        let newSegment1 = TimelineSegment(
            sourceStartTime: segment.sourceStartTime,
            sourceEndTime: sourceTime,
            displayStartTime: segment.displayStartTime,
            displayEndTime: segment.displayStartTime + displayOffsetFromStart
        )

        let newSegment2 = TimelineSegment(
            sourceStartTime: sourceTime,
            sourceEndTime: segment.sourceEndTime,
            displayStartTime: segment.displayStartTime + displayOffsetFromStart,
            displayEndTime: segment.displayEndTime
        )

        // Replace the old segment with two new ones
        segments.remove(at: segmentIndex)
        segments.insert(newSegment2, at: segmentIndex)
        segments.insert(newSegment1, at: segmentIndex)

        // Clear selection since segment was split
        selectedSegmentIndex = nil

        print("TimelineView: Split segment at source time \(sourceTime)")
        updateLayout()
    }

    func removeCutPoint(at sourceTime: TimeInterval, tolerance: TimeInterval = 0.5) {
        // Find two adjacent segments that share a boundary near this time
        for i in 0..<(segments.count - 1) {
            let seg1 = segments[i]
            let seg2 = segments[i + 1]

            // Check if these segments are adjacent in SOURCE time and the boundary is near the cut
            if abs(seg1.sourceEndTime - sourceTime) < tolerance &&
               abs(seg2.sourceStartTime - sourceTime) < tolerance &&
               abs(seg1.sourceEndTime - seg2.sourceStartTime) < 0.01 {

                // Merge these two segments
                let mergedSegment = TimelineSegment(
                    sourceStartTime: seg1.sourceStartTime,
                    sourceEndTime: seg2.sourceEndTime,
                    displayStartTime: seg1.displayStartTime,
                    displayEndTime: seg2.displayEndTime
                )

                segments.remove(at: i + 1)
                segments.remove(at: i)
                segments.insert(mergedSegment, at: i)

                print("TimelineView: Merged segments at source time \(sourceTime)")
                updateLayout()
                return
            }
        }
    }

    func clearAllCuts() {
        // Reset to single segment
        segments = [TimelineSegment(
            sourceStartTime: 0,
            sourceEndTime: sourceDuration,
            displayStartTime: 0,
            displayEndTime: sourceDuration
        )]
        selectedSegmentIndex = nil
        updateLayout()
    }

    // MARK: - Segment Management

    func deleteSelectedSegment() {
        guard let index = selectedSegmentIndex, index < segments.count else { return }

        print("TimelineView: Deleting segment \(index)")

        // Remove the segment
        segments.remove(at: index)

        // Rebuild display times for all remaining segments
        rebuildDisplayTimes()

        // Clear selection
        selectedSegmentIndex = nil

        updateLayout()
    }

    private func rebuildDisplayTimes() {
        var currentDisplayTime: TimeInterval = 0

        for i in 0..<segments.count {
            let duration = segments[i].sourceDuration
            segments[i].displayStartTime = currentDisplayTime
            segments[i].displayEndTime = currentDisplayTime + duration
            currentDisplayTime += duration
        }

        print("TimelineView: Rebuilt timeline - \(segments.count) segments, total duration: \(currentDisplayTime)s")
    }

    func getActiveSegments() -> [TimelineSegment] {
        return segments  // All segments in the array are active (deleted ones are removed)
    }

    // MARK: - Keyboard Handling

    override var acceptsFirstResponder: Bool { return true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 11: // B key
            isBladeToolActive.toggle()
            delegate?.timelineView(self, didChangeBladeToolState: isBladeToolActive)

        case 49: // Spacebar
            delegate?.timelineViewDidTogglePlayPause(self)

        case 123: // Left arrow
            seekToTime(currentTime - 0.033) // ~1 frame at 30fps

        case 124: // Right arrow
            seekToTime(currentTime + 0.033)

        case 51: // Delete/Backspace
            if selectedSegmentIndex != nil {
                // Delete selected segment
                deleteSelectedSegment()
            } else if let hoveredTime = interactionView.lastMouseLocation {
                let displayTime = xPositionToTime(hoveredTime.x)

                // Find which segment we're hovering over
                if let segmentIndex = segments.firstIndex(where: {
                    $0.displayStartTime <= displayTime && displayTime < $0.displayEndTime
                }) {
                    let segment = segments[segmentIndex]

                    // Convert display time to source time
                    let offsetInSegment = displayTime - segment.displayStartTime
                    let sourceTime = segment.sourceStartTime + offsetInSegment

                    // Check if we're near a segment boundary (cut point)
                    let isNearStart = offsetInSegment < 0.5
                    let isNearEnd = (segment.displayEndTime - displayTime) < 0.5

                    if isNearStart && segmentIndex > 0 {
                        // Near start of segment - try to remove cut before it
                        removeCutPoint(at: segment.sourceStartTime)
                    } else if isNearEnd && segmentIndex < segments.count - 1 {
                        // Near end of segment - try to remove cut after it
                        removeCutPoint(at: segment.sourceEndTime)
                    }
                }
            }

        default:
            super.keyDown(with: event)
        }
    }

    private func updateCursor() {
        if isBladeToolActive {
            // Create custom scissors cursor
            if let scissorsCursor = createScissorsCursor() {
                scissorsCursor.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    private func createScissorsCursor() -> NSCursor? {
        // Create a cursor with scissors emoji facing upwards
        let cursorSize = NSSize(width: 32, height: 32)
        let cursorImage = NSImage(size: cursorSize)

        cursorImage.lockFocus()

        // Draw scissors emoji rotated to face upwards
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.white
        ]

        let scissors = "✂️"
        let textSize = scissors.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (cursorSize.width - textSize.width) / 2,
            y: (cursorSize.height - textSize.height) / 2 - 2, // Offset slightly up
            width: textSize.width,
            height: textSize.height
        )

        // Rotate context to make scissors point upwards
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: cursorSize.width / 2, y: cursorSize.height / 2)
        NSGraphicsContext.current?.cgContext.rotate(by: .pi / 2) // Rotate 90 degrees
        NSGraphicsContext.current?.cgContext.translateBy(x: -cursorSize.width / 2, y: -cursorSize.height / 2)

        scissors.draw(in: textRect, withAttributes: attributes)

        NSGraphicsContext.current?.cgContext.restoreGState()

        cursorImage.unlockFocus()

        // Hotspot at center bottom (where the cut happens)
        let hotspot = NSPoint(x: cursorSize.width / 2, y: 2)
        return NSCursor(image: cursorImage, hotSpot: hotspot)
    }

    // MARK: - Helper Methods

    // The track area width (interactionView, segmentView, playheadView all have same width)
    private var trackWidth: CGFloat {
        return interactionView.bounds.width > 0 ? interactionView.bounds.width : bounds.width - 40
    }

    private func xPositionToTime(_ x: CGFloat) -> TimeInterval {
        guard trackWidth > 0 else { return 0 }
        // Account for zoom and pan
        let adjustedX = x + panOffset
        let totalWidth = trackWidth * zoomLevel
        let fraction = adjustedX / totalWidth
        return TimeInterval(fraction) * editedDuration
    }

    private func timeToXPosition(_ time: TimeInterval) -> CGFloat {
        guard editedDuration > 0, trackWidth > 0 else { return 0 }
        // Account for zoom and pan
        let fraction = CGFloat(time / editedDuration)
        let totalWidth = trackWidth * zoomLevel
        let position = fraction * totalWidth
        return position - panOffset
    }

    private func updateCurrentTimeDisplay() {
        currentTimeLabel.stringValue = formatTime(currentTime)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Zoom and Pan Methods

    @objc private func zoomIn() {
        zoomLevel *= 1.5
        print("TimelineView: Zoomed in to \(zoomLevel)x")
    }

    @objc private func zoomOut() {
        let newZoom = zoomLevel / 1.5
        if newZoom >= 1.0 {
            zoomLevel = newZoom
            print("TimelineView: Zoomed out to \(zoomLevel)x")
        } else {
            // Force to exactly 1.0 to ensure entire timeline fits without scrolling
            if zoomLevel > 1.0 {
                zoomLevel = 1.0
                print("TimelineView: Zoomed out to minimum (1.0x) - entire timeline visible")
            } else {
                print("TimelineView: Already at minimum zoom (1.0x)")
            }
        }
    }

    private func updatePanOffset() {
        // Reset pan offset when at default zoom (no need to pan)
        if zoomLevel <= 1.0 {
            panOffset = 0
            return
        }

        // Clamp pan offset to keep timeline visible
        let maxPanOffset = max(0, (bounds.width * zoomLevel) - bounds.width)
        panOffset = max(0, min(panOffset, maxPanOffset))
    }

    override func scrollWheel(with event: NSEvent) {
        // Only allow horizontal scrolling when zoomed in
        guard zoomLevel > 1.0 else {
            print("TimelineView: Cannot scroll - not zoomed in (zoom level: \(zoomLevel))")
            return
        }

        // Use deltaY for vertical mouse wheel (converts vertical scroll to horizontal pan)
        // Use deltaX for trackpad horizontal swipe
        let scrollDelta = event.deltaY != 0 ? event.deltaY : event.deltaX

        panOffset -= scrollDelta * 5.0 // Increased multiplier for faster scrolling
        updatePanOffset()

        print("TimelineView: Scrolled by \(scrollDelta), new pan offset: \(panOffset)")
    }

    // MARK: - Scroll Bar Communication

    /// Set pan offset from external source (e.g., scroll bar)
    func setPanOffset(_ offset: CGFloat) {
        guard zoomLevel > 1.0 else { return }
        panOffset = offset
        updatePanOffset()
    }

    /// Get scroll information for scroll bar
    func getScrollInfo() -> (visibleFraction: CGFloat, scrollPosition: CGFloat) {
        guard zoomLevel > 1.0 else {
            return (1.0, 0.0) // Fully visible, no scroll
        }

        let visibleFraction = 1.0 / zoomLevel
        let maxPanOffset = max(0, (bounds.width * zoomLevel) - bounds.width)
        let scrollPosition = maxPanOffset > 0 ? panOffset / maxPanOffset : 0

        return (visibleFraction, scrollPosition)
    }

    private func notifyZoomPanChanged() {
        delegate?.timelineView(self, didChangeZoomOrPan: zoomLevel, panOffset: panOffset)
    }
}

// MARK: - Timeline Ruler View

private class TimelineRulerView: NSView {
    var duration: TimeInterval = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var zoomLevel: CGFloat = 1.0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var panOffset: CGFloat = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false // Use draw(_:) for custom drawing
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard duration > 0 else {
            print("TimelineRulerView: No duration, skipping draw")
            return
        }

        let tickColor = NSColor(white: 0.5, alpha: 1.0)
        let textColor = NSColor(white: 0.7, alpha: 1.0)

        // Calculate intelligent tick interval based on visible duration and available space
        let tickInterval = calculateOptimalTickInterval(duration: duration, zoomLevel: zoomLevel, viewWidth: bounds.width)

        print("TimelineRulerView: Drawing ruler - duration: \(duration)s, tickInterval: \(tickInterval)s, zoomLevel: \(zoomLevel), bounds: \(bounds)")

        let totalWidth = bounds.width * zoomLevel

        // Always draw 0:00 at the start
        drawTick(at: 0, duration: duration, totalWidth: totalWidth, tickColor: tickColor, textColor: textColor, showLabel: true)

        // Draw intermediate ticks at regular intervals (only natural ticks, no forced end marker)
        var time = tickInterval
        var tickCount = 1
        while time < duration {
            drawTick(at: time, duration: duration, totalWidth: totalWidth, tickColor: tickColor, textColor: textColor, showLabel: true)
            time += tickInterval
            tickCount += 1
        }
        print("TimelineRulerView: Drew \(tickCount) ticks")
    }

    private func drawTick(at time: TimeInterval, duration: TimeInterval, totalWidth: CGFloat, tickColor: NSColor, textColor: NSColor, showLabel: Bool) {
        let fraction = CGFloat(time / duration)
        let x = (fraction * totalWidth) - panOffset

        // Only draw if visible
        guard x >= 0 && x <= bounds.width else { return }

        // Draw tick mark (vertical line)
        let tickPath = NSBezierPath()
        tickPath.move(to: NSPoint(x: x, y: bounds.height - 6))
        tickPath.line(to: NSPoint(x: x, y: bounds.height))
        tickColor.setStroke()
        tickPath.lineWidth = 1.5
        tickPath.stroke()

        // Draw time label if requested
        if showLabel {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            let timeString = String(format: "%d:%02d", minutes, seconds)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: textColor
            ]

            let size = timeString.size(withAttributes: attributes)

            // Align labels based on position to prevent clipping
            let labelX: CGFloat
            if time <= 0.01 {
                // First label - align left
                labelX = x
            } else if abs(time - duration) < 0.01 {
                // Last label - align right
                labelX = x - size.width
            } else {
                // Middle labels - center
                labelX = x - size.width / 2
            }

            let rect = NSRect(x: labelX, y: 1, width: size.width, height: size.height)
            timeString.draw(in: rect, withAttributes: attributes)
        }
    }

    private func calculateOptimalTickInterval(duration: TimeInterval, zoomLevel: CGFloat, viewWidth: CGFloat) -> TimeInterval {
        // Calculate effective width (how wide the timeline appears)
        let effectiveWidth = viewWidth * zoomLevel

        // Calculate pixels per second
        let pixelsPerSecond = effectiveWidth / CGFloat(duration)

        // Estimate minimum space needed for a time label (approximately 50 pixels including spacing)
        let minPixelsBetweenLabels: CGFloat = 50

        // Calculate minimum seconds between labels to avoid overlap
        let minSecondsBetweenLabels = Double(minPixelsBetweenLabels / pixelsPerSecond)

        // Define nice intervals to snap to (in seconds)
        let niceIntervals: [TimeInterval] = [
            0.1, 0.2, 0.5,           // Sub-second (for extreme zoom)
            1, 2, 5,                 // Seconds
            10, 15, 30,              // Tens of seconds
            60, 120, 300,            // Minutes
            600, 900, 1800,          // 10, 15, 30 minutes
            3600                     // 1 hour
        ]

        // Find the smallest nice interval that's larger than our minimum
        for interval in niceIntervals {
            if interval >= minSecondsBetweenLabels {
                return interval
            }
        }

        // Fallback for very long videos
        return 3600 // 1 hour
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Segment View

private class SegmentView: NSView {
    var duration: TimeInterval = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var zoomLevel: CGFloat = 1.0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var panOffset: CGFloat = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var segments: [TimelineSegment] = [] {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var selectedSegmentIndex: Int? = nil {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard duration > 0 else { return }

        // Draw base background
        NSColor(white: 0.12, alpha: 1.0).setFill()
        NSBezierPath(rect: bounds).fill()

        // Active colors with gradients
        let activeColor = NSColor(red: 0.3, green: 0.6, blue: 0.95, alpha: 1.0)
        let activeColorDark = NSColor(red: 0.2, green: 0.45, blue: 0.75, alpha: 1.0)

        let totalWidth = bounds.width * zoomLevel

        for (index, segment) in segments.enumerated() {
            NSGraphicsContext.saveGraphicsState()

            let startX = (CGFloat(segment.displayStartTime / duration) * totalWidth) - panOffset
            let endX = (CGFloat(segment.displayEndTime / duration) * totalWidth) - panOffset
            let width = max(2, endX - startX)

            // Skip if segment is completely out of view
            guard endX >= 0 && startX <= bounds.width else {
                NSGraphicsContext.restoreGraphicsState()
                continue
            }

            let rect = NSRect(x: startX, y: 0, width: width, height: bounds.height)
            let isSelected = (index == selectedSegmentIndex)

            // Create gradient
            let gradient = NSGradient(starting: activeColor, ending: activeColorDark)!

            // Draw gradient fill
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.addClip()
            gradient.draw(in: rect, angle: 90)

            NSGraphicsContext.restoreGraphicsState()

            // Draw border (thicker and yellow if selected)
            if isSelected {
                NSColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 1.0).setStroke()
                let borderPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                borderPath.lineWidth = 2.5
                borderPath.stroke()
            } else {
                NSColor(white: 0.3, alpha: 0.6).setStroke()
                let borderPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                borderPath.lineWidth = 0.5
                borderPath.stroke()
            }

            // Add subtle highlight at top
            let highlightColor: NSColor
            if isSelected {
                highlightColor = NSColor(red: 1.0, green: 0.95, blue: 0.5, alpha: 0.6)
            } else {
                highlightColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.3)
            }
            let highlightPath = NSBezierPath()
            highlightPath.move(to: NSPoint(x: startX + 3, y: 1))
            highlightPath.line(to: NSPoint(x: endX - 3, y: 1))
            highlightColor.setStroke()
            highlightPath.lineWidth = isSelected ? 2.0 : 1.5
            highlightPath.stroke()

            // Draw segment boundary lines (cuts)
            if index > 0 {
                // Draw a subtle line at the start of this segment
                let cutLine = NSBezierPath()
                cutLine.move(to: NSPoint(x: startX, y: 0))
                cutLine.line(to: NSPoint(x: startX, y: bounds.height))
                NSColor(white: 0.6, alpha: 0.8).setStroke()
                cutLine.lineWidth = 1.5
                cutLine.stroke()
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Playhead View

private class PlayheadView: NSView {
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var zoomLevel: CGFloat = 1.0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var panOffset: CGFloat = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard duration > 0 else { return }

        let totalWidth = bounds.width * zoomLevel
        let x = (CGFloat(currentTime / duration) * totalWidth) - panOffset

        // Only draw if playhead is visible
        guard x >= 0 && x <= bounds.width else { return }

        // Draw playhead line with glow effect
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: x, y: 0))
        linePath.line(to: NSPoint(x: x, y: bounds.height))

        // Outer glow
        NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.3).setStroke()
        linePath.lineWidth = 4
        linePath.stroke()

        // Main line
        NSColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0).setStroke()
        linePath.lineWidth = 2
        linePath.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Cut Point View

private class CutPointView: NSView {
    var duration: TimeInterval = 0
    var cutPoints: [CutPoint] = [] {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard duration > 0 else { return }

        for cut in cutPoints {
            let x = CGFloat(cut.time / duration) * bounds.width

            // Draw cut line with dashed style
            let linePath = NSBezierPath()
            linePath.move(to: NSPoint(x: x, y: 0))
            linePath.line(to: NSPoint(x: x, y: bounds.height))

            // Shadow/glow
            NSColor(white: 1.0, alpha: 0.3).setStroke()
            linePath.lineWidth = 4
            linePath.stroke()

            // Main line
            NSColor.white.setStroke()
            linePath.lineWidth = 2
            linePath.setLineDash([4, 2], count: 2, phase: 0)
            linePath.stroke()

            // Draw scissors icon at top
            let iconSize: CGFloat = 10
            let iconY: CGFloat = bounds.height / 2 - iconSize / 2

            let iconRect = NSRect(x: x - iconSize / 2, y: iconY, width: iconSize, height: iconSize)
            let iconPath = NSBezierPath(ovalIn: iconRect)

            NSColor(white: 0.2, alpha: 0.8).setFill()
            iconPath.fill()

            NSColor.white.setStroke()
            iconPath.lineWidth = 1
            iconPath.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Marker Track View

private class MarkerTrackView: NSView {
    var duration: TimeInterval = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var zoomLevel: CGFloat = 1.0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var panOffset: CGFloat = 0 {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var zoomRegions: [ZoomRegion] = [] {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    var clickEventTimes: [TimeInterval] = [] {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard duration > 0 else { return }

        let totalWidth = bounds.width * zoomLevel

        // Draw zoom regions as colored bars with gradients
        for region in zoomRegions {
            NSGraphicsContext.saveGraphicsState()

            let startX = (CGFloat(region.startTime / duration) * totalWidth) - panOffset
            let endX = (CGFloat(region.endTime / duration) * totalWidth) - panOffset
            let width = max(2, endX - startX)

            // Skip if region is completely out of view
            guard endX >= 0 && startX <= bounds.width else {
                NSGraphicsContext.restoreGraphicsState()
                continue
            }

            let (color1, color2): (NSColor, NSColor)
            switch region.type {
            case .zoomIn:
                color1 = NSColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 0.8)
                color2 = NSColor(red: 1.0, green: 0.7, blue: 0.1, alpha: 0.8)
            case .hold:
                color1 = NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.8)
                color2 = NSColor(red: 0.2, green: 0.7, blue: 0.2, alpha: 0.8)
            case .zoomOut:
                color1 = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 0.8)
                color2 = NSColor(red: 1.0, green: 0.4, blue: 0.1, alpha: 0.8)
            }

            let rect = NSRect(x: startX, y: 0, width: width, height: bounds.height)

            // Draw gradient
            let gradient = NSGradient(starting: color1, ending: color2)!
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.addClip()
            gradient.draw(in: rect, angle: 90)

            NSGraphicsContext.restoreGraphicsState()

            // Draw border
            NSColor(white: 0.4, alpha: 0.5).setStroke()
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            borderPath.lineWidth = 0.5
            borderPath.stroke()
        }

        // Draw click event markers as beautiful diamonds
        for time in clickEventTimes {
            NSGraphicsContext.saveGraphicsState()

            let x = (CGFloat(time / duration) * totalWidth) - panOffset

            // Skip if marker is out of view
            guard x >= -10 && x <= bounds.width + 10 else {
                NSGraphicsContext.restoreGraphicsState()
                continue
            }

            let centerY = bounds.height / 2

            let size: CGFloat = 5
            let diamondPath = NSBezierPath()
            diamondPath.move(to: NSPoint(x: x, y: centerY - size))
            diamondPath.line(to: NSPoint(x: x + size, y: centerY))
            diamondPath.line(to: NSPoint(x: x, y: centerY + size))
            diamondPath.line(to: NSPoint(x: x - size, y: centerY))
            diamondPath.close()

            // Shadow
            NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.4).setFill()
            let shadowPath = diamondPath.copy() as! NSBezierPath
            let transform = AffineTransform(translationByX: 0, byY: 1)
            shadowPath.transform(using: transform)
            shadowPath.fill()

            // Gradient fill
            let gradient = NSGradient(
                starting: NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0),
                ending: NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0)
            )!
            diamondPath.addClip()
            gradient.draw(in: NSRect(x: x - size, y: centerY - size, width: size * 2, height: size * 2), angle: 135)

            NSGraphicsContext.restoreGraphicsState()

            // Border
            NSColor.white.setStroke()
            let borderPath = NSBezierPath()
            borderPath.move(to: NSPoint(x: x, y: centerY - size))
            borderPath.line(to: NSPoint(x: x + size, y: centerY))
            borderPath.line(to: NSPoint(x: x, y: centerY + size))
            borderPath.line(to: NSPoint(x: x - size, y: centerY))
            borderPath.close()
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Interaction View

private class TimelineInteractionView: NSView {
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var lastMouseLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow
        ]
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas {
            removeTrackingArea(area)
        }

        setupTracking()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastMouseLocation = location
        onMouseDown?(location)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastMouseLocation = location
        onMouseDragged?(location)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastMouseLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseUp?(location)
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to parent TimelineView
        superview?.scrollWheel(with: event)
    }
}

// MARK: - Timeline Horizontal Scroll Bar

class TimelineScrollBar: NSView {
    var onScrollPositionChanged: ((CGFloat) -> Void)?

    private var visibleFraction: CGFloat = 1.0 {
        didSet { setNeedsDisplay(bounds) }
    }

    private var scrollPosition: CGFloat = 0.0 {
        didSet { setNeedsDisplay(bounds) }
    }

    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartScrollPosition: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1.0).cgColor
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }

    func updateScrollState(visibleFraction: CGFloat, scrollPosition: CGFloat) {
        self.visibleFraction = max(0.0, min(1.0, visibleFraction))
        self.scrollPosition = max(0.0, min(1.0, scrollPosition))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = bounds.insetBy(dx: 4, dy: 4)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3)
        NSColor(white: 0.15, alpha: 1.0).setFill()
        trackPath.fill()

        guard visibleFraction < 1.0 else { return }

        let availableWidth = trackRect.width
        let thumbWidth = max(30, availableWidth * visibleFraction)
        let thumbX = trackRect.minX + (scrollPosition * (availableWidth - thumbWidth))

        let thumbRect = NSRect(x: thumbX, y: trackRect.minY + 2, width: thumbWidth, height: trackRect.height - 4)

        NSGraphicsContext.saveGraphicsState()
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
        thumbPath.addClip()
        let gradient = NSGradient(starting: NSColor(white: 0.5, alpha: 1.0), ending: NSColor(white: 0.35, alpha: 1.0))!
        gradient.draw(in: thumbRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.6, alpha: 0.8).setStroke()
        let borderPath = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
        borderPath.lineWidth = 1
        borderPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let trackRect = bounds.insetBy(dx: 4, dy: 4)
        let availableWidth = trackRect.width
        let thumbWidth = max(30, availableWidth * visibleFraction)
        let thumbX = trackRect.minX + (scrollPosition * (availableWidth - thumbWidth))
        let thumbRect = NSRect(x: thumbX, y: trackRect.minY + 2, width: thumbWidth, height: trackRect.height - 4)

        if thumbRect.contains(location) {
            isDragging = true
            dragStartX = location.x
            dragStartScrollPosition = scrollPosition
        } else if trackRect.contains(location) {
            let clickPosition = (location.x - trackRect.minX) / availableWidth
            onScrollPositionChanged?(max(0.0, min(1.0, clickPosition)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        let trackRect = bounds.insetBy(dx: 4, dy: 4)
        let availableWidth = trackRect.width
        let thumbWidth = max(30, availableWidth * visibleFraction)
        let dragFraction = (location.x - dragStartX) / (availableWidth - thumbWidth)
        onScrollPositionChanged?(max(0.0, min(1.0, dragStartScrollPosition + dragFraction)))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}
