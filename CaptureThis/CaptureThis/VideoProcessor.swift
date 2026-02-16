import AVFoundation
import CoreImage
import CoreVideo
import AppKit

class VideoProcessor {
    func processVideo(
        inputURL: URL,
        outputURL: URL,
        clickEvents: [ClickEventNew],
        cursorPositions: [CursorPositionNew]? = nil,
        trackingMode: TrackingMode,
        recordingStartTime: Date,
        subtitles: [SubtitleEntryApple]? = nil,
        addBorders: Bool = false,
        selfieVideoURL: URL? = nil,
        selfieOverlayEvents: [SelfieOverlayEvent] = [],
        selfieStartOffset: TimeInterval = 0,
        backgroundColor: NSColor? = nil,
        backgroundImage: NSImage? = nil,
        borderEnabled: Bool = false,
        borderWidth: CGFloat = 0,
        muteAudio: Bool = false,
        cursorOverlayMode: CursorOverlayMode = .normal,
        allClickEvents: [ClickEventNew] = [],
        progress: @escaping (Double) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        // Load the video asset
        let asset = AVAsset(url: inputURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(NSError(domain: "VideoProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"]))
            return
        }

        // Get video properties
        let videoSize = videoTrack.naturalSize
        let assetDuration = asset.duration
        let trackDuration = videoTrack.timeRange.duration
        let duration = trackDuration.seconds.isFinite && trackDuration.seconds > 0 ? trackDuration : assetDuration

        print("VideoProcessor: Asset duration: \(CMTimeGetSeconds(assetDuration))s")
        print("VideoProcessor: Track duration: \(CMTimeGetSeconds(trackDuration))s")
        print("VideoProcessor: Using duration: \(CMTimeGetSeconds(duration))s")

        // Cursor tracking and screen recording now start simultaneously with same timestamp reference
        // No offset calculation needed - they're already synchronized!
        let timingOffset: TimeInterval = 0.0

        print("VideoProcessor: Recording start time: \(recordingStartTime)")
        print("VideoProcessor: Tracking mode: \(trackingMode)")
        print("VideoProcessor: Total click events: \(clickEvents.count)")
        print("VideoProcessor: Total cursor positions: \(cursorPositions?.count ?? 0)")
        print("VideoProcessor: Total subtitles: \(subtitles?.count ?? 0)")
        if let subs = subtitles, !subs.isEmpty {
            print("VideoProcessor: First subtitle: '\(subs[0].text)' at \(subs[0].timestamp)s")
        }
        print("VideoProcessor: Video duration: \(CMTimeGetSeconds(duration)) seconds")
        print("VideoProcessor: Video size: \(videoSize.width)x\(videoSize.height)")

        // DIAGNOSTIC: Check first few cursor positions vs video timeline
        if let positions = cursorPositions, positions.count > 5 {
            print("\n=== CURSOR POSITION TIMELINE ===")
            for i in 0..<min(5, positions.count) {
                let pos = positions[i]
                let timeOffset = pos.captureTimestamp.timeIntervalSince(recordingStartTime)
                print("Cursor[\(i)]: \(timeOffset)s after start @ \(pos.captureTimestamp)")
            }
        }

        print("\n=== VIDEO FRAME TIMELINE ===")
        print("Video frame 0 starts at: 0.0s")
        print("Video frame 30 (1 sec) at: ~1.0s")
        print("Video frame timebase: \(videoTrack.naturalTimeScale) ticks/sec")

        // Group clicks that are close together (only for click mode)
        let clickGroups = trackingMode == .zoomOnClicks ? groupClicks(clickEvents, maxTimeDiff: 3.0) : []

        print("VideoProcessor: Created \(clickGroups.count) click groups:")
        for (index, group) in clickGroups.enumerated() {
            if let firstClick = group.first {
                let triggerTime = firstClick.captureTimestamp.timeIntervalSince(recordingStartTime)
                print("  Group \(index): \(group.count) click(s) at \(triggerTime)s")
            }
        }

        // Create composition
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(NSError(domain: "VideoProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"]))
            return
        }

        print("VideoProcessor: Source video track ID: \(videoTrack.trackID)")
        print("VideoProcessor: Composition track ID: \(compositionVideoTrack.trackID)")

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: .zero
            )
            print("VideoProcessor: Successfully inserted video track into composition")
        } catch {
            print("VideoProcessor: ERROR inserting video track - \(error.localizedDescription)")
            completion(error)
            return
        }

        // Add all audio tracks (source may have system audio + mic audio as separate tracks)
        let audioTracks = muteAudio ? [] : asset.tracks(withMediaType: .audio)
        print("VideoProcessor: Found \(audioTracks.count) audio track(s) in source video\(muteAudio ? " (muted)" : "")")
        for (index, audioTrack) in audioTracks.enumerated() {
            if let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: audioTrack,
                        at: .zero
                    )
                    print("VideoProcessor: Successfully inserted audio track \(index + 1) into composition")
                } catch {
                    print("VideoProcessor: ERROR inserting audio track \(index + 1) - \(error.localizedDescription)")
                }
            }
        }

        // Determine upfront if we need the custom compositor
        let hasSubtitles = subtitles != nil && !subtitles!.isEmpty
        let needsZoom = trackingMode == .zoomOnClicks || trackingMode == .followCursor
        let hasSelfieURL = selfieVideoURL != nil && FileManager.default.fileExists(atPath: selfieVideoURL!.path)

        // Load selfie asset for overlay (uses AVAssetImageGenerator, not a composition track)
        var selfieAsset: AVAsset? = nil
        if hasSelfieURL {
            let sAsset = AVAsset(url: selfieVideoURL!)
            if sAsset.tracks(withMediaType: .video).first != nil {
                selfieAsset = sAsset
                print("VideoProcessor: Loaded selfie asset for overlay at offset \(selfieStartOffset)s")
            }
        }
        let hasSelfie = selfieAsset != nil && !selfieOverlayEvents.isEmpty

        // Use compositor for zoom, subtitles, borders, selfie overlay, or cursor overlay
        let needsCursorOverlay = cursorOverlayMode != .normal
        let needsCompositor = needsZoom || hasSubtitles || borderEnabled || hasSelfie || needsCursorOverlay

        // Export the composition
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(NSError(domain: "VideoProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        // Log compositor decision (already computed above)
        print("VideoProcessor: Compositor check - trackingMode: \(trackingMode), hasSubtitles: \(hasSubtitles), hasSelfie: \(hasSelfie), needsCompositor: \(needsCompositor)")

        if needsCompositor {
            let backgroundCIImage: CIImage?
            if let backgroundImage = backgroundImage, let cgImage = backgroundImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                backgroundCIImage = CIImage(cgImage: cgImage)
            } else {
                backgroundCIImage = nil
            }

            let backgroundCIColor: CIColor? = backgroundColor.flatMap { CIColor(color: $0) }

            let videoComposition = createVideoComposition(
                for: composition,
                videoSize: videoSize,
                clickGroups: clickGroups,
                cursorPositions: cursorPositions ?? [],
                trackingMode: trackingMode,
                recordingStartTime: recordingStartTime,
                subtitles: subtitles ?? [],
                timingOffset: timingOffset,
                videoDuration: duration,
                compositionTrackID: compositionVideoTrack.trackID,
                addBorders: addBorders,
                selfieAsset: selfieAsset,
                selfieOverlayEvents: selfieOverlayEvents,
                selfieVideoSize: selfieAsset?.tracks(withMediaType: .video).first?.naturalSize,
                selfieStartOffset: selfieStartOffset,
                backgroundColor: backgroundCIColor,
                backgroundImage: backgroundCIImage,
                borderEnabled: borderEnabled,
                borderWidth: borderWidth,
                cursorOverlayMode: cursorOverlayMode,
                allClickEvents: allClickEvents
            )
            exportSession.videoComposition = videoComposition

            // Reset time-based progress tracking
            let totalDuration = CMTimeGetSeconds(duration)
            ZoomVideoCompositor.resetProgress(duration: totalDuration)
            print("VideoProcessor: ✓ Using custom compositor for tracking mode: \(trackingMode), subtitles: \(subtitles?.count ?? 0), duration: \(String(format: "%.1f", totalDuration))s")
        } else {
            // Simple export without custom compositor - just use the composition directly
            print("VideoProcessor: ✓ Using simple export (no custom compositor needed)")
        }

        // Monitor progress using compositor frame count (exportSession.progress
        // doesn't update reliably with custom AVVideoComposition compositors).
        // Use DispatchSourceTimer instead of Timer.scheduledTimer because processVideo
        // may be called from a background thread (e.g. after segment export) where
        // the run loop isn't running, causing Timer to never fire.
        var lastLoggedPercent = -1
        let progressTimer = DispatchSource.makeTimerSource(queue: .main)
        progressTimer.schedule(deadline: .now(), repeating: 0.2)
        progressTimer.setEventHandler {
            let frameProgress = needsCompositor ? ZoomVideoCompositor.getProgress() : Double(exportSession.progress)
            let currentProgress = min(frameProgress, 0.95)
            progress(currentProgress)

            let currentPercent = Int(currentProgress * 100)
            if currentPercent != lastLoggedPercent && currentPercent % 10 == 0 {
                print("VideoProcessor: Export progress: \(currentPercent)% (\(String(format: "%.1f", ZoomVideoCompositor.latestTime))/\(String(format: "%.1f", ZoomVideoCompositor.totalDuration))s)")
                lastLoggedPercent = currentPercent
            }
        }
        progressTimer.resume()

        print("VideoProcessor: Starting export asynchronously...")

        exportSession.exportAsynchronously {
            progressTimer.cancel()
            progress(1.0)

            let status = exportSession.status
            print("VideoProcessor: Export completed with status: \(status.rawValue)")

            switch status {
            case .completed:
                print("VideoProcessor: ✓ Export successful")
                completion(nil)
            case .failed:
                let error = exportSession.error ?? NSError(domain: "VideoProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
                let nsError = error as NSError
                print("VideoProcessor: ✗ Export failed: \(error.localizedDescription) (domain=\(nsError.domain), code=\(nsError.code))")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("VideoProcessor: Underlying error: \(underlying.localizedDescription) (domain=\(underlying.domain), code=\(underlying.code))")
                }
                completion(error)
            case .cancelled:
                let error = exportSession.error
                if let error = error {
                    print("VideoProcessor: Export cancelled with error: \(error.localizedDescription)")
                } else {
                    print("VideoProcessor: Export cancelled")
                }
                completion(error ?? NSError(domain: "VideoProcessor", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
            default:
                print("VideoProcessor: Export ended with unknown status: \(status.rawValue)")
                completion(NSError(domain: "VideoProcessor", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unknown export error"]))
            }
        }
    }

    private func createVideoComposition(
        for composition: AVMutableComposition,
        videoSize: CGSize,
        clickGroups: [[ClickEventNew]],
        cursorPositions: [CursorPositionNew],
        trackingMode: TrackingMode,
        recordingStartTime: Date,
        subtitles: [SubtitleEntryApple],
        timingOffset: TimeInterval,
        videoDuration: CMTime,
        compositionTrackID: CMPersistentTrackID,
        addBorders: Bool = false,
        selfieAsset: AVAsset? = nil,
        selfieOverlayEvents: [SelfieOverlayEvent] = [],
        selfieVideoSize: CGSize? = nil,
        selfieStartOffset: TimeInterval = 0,
        backgroundColor: CIColor? = nil,
        backgroundImage: CIImage? = nil,
        borderEnabled: Bool = false,
        borderWidth: CGFloat = 0,
        cursorOverlayMode: CursorOverlayMode = .normal,
        allClickEvents: [ClickEventNew] = []
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()

        // Add borders if requested (for background canvas)
        // IMPORTANT: Output dimensions must be integers for video encoding
        let outputSize: CGSize
        if borderEnabled {
            let borderSize: CGFloat = max(1, round(borderWidth * 2))
            outputSize = CGSize(
                width: round(videoSize.width + borderSize),
                height: round(videoSize.height + borderSize)
            )
            print("VideoProcessor: Adding borders - input size: \(videoSize.width)x\(videoSize.height), output size: \(outputSize.width)x\(outputSize.height)")
        } else {
            outputSize = CGSize(width: round(videoSize.width), height: round(videoSize.height))
        }

        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        // Create custom compositor for zoom effects
        videoComposition.customVideoCompositorClass = ZoomVideoCompositor.self

        // Single instruction for the entire duration.
        // Selfie overlay uses AVAssetImageGenerator (no composition track needed).
        print("VideoProcessor: Using composition track ID: \(compositionTrackID)")

        let instruction = ZoomCompositionInstruction(
            trackID: compositionTrackID,
            sourceTrackID: compositionTrackID,
            timeRange: CMTimeRange(start: .zero, duration: videoDuration),
            videoSize: videoSize,
            clickGroups: clickGroups,
            cursorPositions: cursorPositions,
            trackingMode: trackingMode,
            recordingStartTime: recordingStartTime,
            subtitles: subtitles,
            timingOffset: timingOffset,
            addBorders: addBorders,
            selfieAsset: selfieAsset,
            selfieOverlayEvents: selfieOverlayEvents,
            selfieVideoSize: selfieVideoSize,
            selfieStartOffset: selfieStartOffset,
            backgroundColor: backgroundColor,
            backgroundImage: backgroundImage,
            borderEnabled: borderEnabled,
            borderWidth: borderWidth,
            canvasSize: outputSize,
            cursorOverlayMode: cursorOverlayMode,
            allClickEvents: allClickEvents
        )
        videoComposition.instructions = [instruction]

        return videoComposition
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
}

// Custom compositor for applying zoom effects
class ZoomVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    // Static progress tracking for UI updates (time-based, not frame-based)
    static var totalDuration: Double = 0
    static var latestTime: Double = 0
    static var progressLock = NSLock()

    static func resetProgress(duration: Double) {
        progressLock.lock()
        totalDuration = duration
        latestTime = 0
        progressLock.unlock()
    }

    static func getProgress() -> Double {
        progressLock.lock()
        defer { progressLock.unlock() }
        guard totalDuration > 0 else { return 0 }
        return min(1.0, latestTime / totalDuration)
    }

    private func updateProgress(time: CMTime) {
        ZoomVideoCompositor.progressLock.lock()
        ZoomVideoCompositor.latestTime = CMTimeGetSeconds(time)
        ZoomVideoCompositor.progressLock.unlock()
    }

    // Thread-safe queue for compositor operations
    private let compositorQueue = DispatchQueue(label: "com.viberecorder.compositor", qos: .userInitiated)

    // Selfie image generator for preview path (reads frames without composition track)
    private var _selfieImageGenerator: AVAssetImageGenerator?
    private let selfieGeneratorLock = NSLock()

    private func getSelfieFrame(from asset: AVAsset, at time: CMTime) -> CIImage? {
        selfieGeneratorLock.lock()
        if _selfieImageGenerator == nil {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            _selfieImageGenerator = gen
        }
        let gen = _selfieImageGenerator!
        selfieGeneratorLock.unlock()

        do {
            let cgImage = try gen.copyCGImage(at: time, actualTime: nil)
            return CIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // High-quality CIContext for rendering - thread-safe lazy initialization
    private var _ciContext: CIContext?
    private let contextLock = NSLock()
    private var ciContext: CIContext {
        contextLock.lock()
        defer { contextLock.unlock() }

        if let context = _ciContext {
            return context
        }

        // Use more conservative settings to prevent GPU timeout/memory issues
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .useSoftwareRenderer: false,  // Use GPU
            .highQualityDownsample: false,  // Disable to reduce GPU load
            .cacheIntermediates: false,  // Don't cache to save memory
            .workingFormat: CIFormat.BGRA8,  // Must be BGRA8/RGBA8/RGBAh/RGBAf or nil
            .priorityRequestLow: true  // Lower priority to prevent GPU timeout
        ]
        let context = CIContext(options: options)
        _ciContext = context
        print("ZoomVideoCompositor: Created CIContext with conservative GPU settings")
        return context
    }

    // Store render context for creating pixel buffers - thread-safe
    private var _renderContext: AVVideoCompositionRenderContext?
    private let renderContextLock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext? {
        get {
            renderContextLock.lock()
            defer { renderContextLock.unlock() }
            return _renderContext
        }
        set {
            renderContextLock.lock()
            defer { renderContextLock.unlock() }
            _renderContext = newValue
        }
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Store the render context in thread-safe manner
        renderContext = newRenderContext
        print("ZoomVideoCompositor: Render context changed")
    }

    deinit {
        // Clean up GPU resources
        contextLock.lock()
        _ciContext = nil
        contextLock.unlock()
        print("ZoomVideoCompositor: Cleaned up GPU resources")
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        // Wrap entire frame rendering in autoreleasepool to ensure memory is released promptly
        autoreleasepool {
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? ZoomCompositionInstruction else {
                print("ZoomVideoCompositor ERROR: Failed to cast instruction")
                asyncVideoCompositionRequest.finish(with: NSError(domain: "ZoomVideoCompositor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to cast instruction"]))
                return
            }

        // Debug: Log track IDs only for first few frames to avoid log spam
        let frameTime = CMTimeGetSeconds(asyncVideoCompositionRequest.compositionTime)
        if frameTime < 0.2 {  // Only log first 0.2 seconds
            print("ZoomVideoCompositor: Frame at \(frameTime)s - sourceTrackID: \(instruction.sourceTrackID)")
        }

        // Try to get source pixel buffer - try multiple approaches
        var sourcePixelBuffer: CVPixelBuffer?

        // Approach 1: Try using the instruction's sourceTrackID
        sourcePixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.sourceTrackID)

        // Approach 2: If that fails and sourceTrackIDs is not empty, try each available track ID
        if sourcePixelBuffer == nil && !asyncVideoCompositionRequest.sourceTrackIDs.isEmpty {
            if frameTime < 0.2 {  // Only log for first frames
                print("ZoomVideoCompositor: Trying alternative track IDs...")
            }
            for trackIDValue in asyncVideoCompositionRequest.sourceTrackIDs {
                if let number = trackIDValue as? NSNumber {
                    let trackID = CMPersistentTrackID(number.int32Value)
                    sourcePixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: trackID)
                    if sourcePixelBuffer != nil {
                        if frameTime < 0.2 {
                            print("ZoomVideoCompositor: Success with trackID: \(trackID)")
                        }
                        break
                    }
                }
            }
        }

        guard let finalPixelBuffer = sourcePixelBuffer else {
            print("ZoomVideoCompositor ERROR: Failed to get source frame after trying all approaches")
            print("ZoomVideoCompositor ERROR: Available source track IDs: \(asyncVideoCompositionRequest.sourceTrackIDs)")
            asyncVideoCompositionRequest.finish(with: NSError(domain: "ZoomVideoCompositor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get source frame"]))
            return
        }

        // Calculate zoom state at current time
        let currentTime = asyncVideoCompositionRequest.compositionTime
        let zoomState = instruction.getZoomState(at: currentTime)

        // Get the base image
        var ciImage = CIImage(cvPixelBuffer: finalPixelBuffer)

        // Apply cursor overlay BEFORE zoom (cursor positions are in full-video coords)
        ciImage = applyCursorOverlay(to: ciImage, instruction: instruction, currentTime: currentTime)

        // Apply zoom effect FIRST (before borders)
        ciImage = applyZoom(to: ciImage, with: zoomState, videoSize: instruction.videoSize)

        // Always render into a NEW output buffer from the render context.
        // Rendering into the source buffer can cause export failure.
        guard let outputPixelBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer() else {
            print("ZoomVideoCompositor ERROR: Failed to create output pixel buffer")
            asyncVideoCompositionRequest.finish(with: NSError(domain: "ZoomVideoCompositor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"]))
            return
        }

        // Apply subtitles if any (on content)
        ciImage = applySubtitles(to: ciImage, instruction: instruction, currentTime: currentTime)

        // Apply canvas/border before selfie so selfie can be placed anywhere on the canvas
        if instruction.borderEnabled {
            ciImage = applyCanvasBackground(to: ciImage, instruction: instruction)
        }

        // Apply selfie overlay on the full canvas (allows placement over borders)
        ciImage = applySelfieOverlay(to: ciImage, instruction: instruction, request: asyncVideoCompositionRequest)

        // Render to the appropriate pixel buffer with error handling
        do {
            // Verify image extent is valid before rendering
            let imageExtent = ciImage.extent
            if imageExtent.isEmpty || imageExtent.isInfinite {
                print("ZoomVideoCompositor ERROR: Invalid image extent: \(imageExtent)")
                asyncVideoCompositionRequest.finish(with: NSError(domain: "ZoomVideoCompositor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid image extent"]))
                return
            }

            // Render with the thread-safe context
            ciContext.render(ciImage, to: outputPixelBuffer)

            // Verify the render completed successfully
            asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputPixelBuffer)

            // Update progress tracking
            updateProgress(time: asyncVideoCompositionRequest.compositionTime)
        } catch {
            print("ZoomVideoCompositor ERROR: Failed to render frame: \(error.localizedDescription)")
            asyncVideoCompositionRequest.finish(with: error)
        }
        }  // End autoreleasepool
    }

    private func applyZoom(to image: CIImage, with zoomState: ZoomState, videoSize: CGSize) -> CIImage {
        guard zoomState.isZooming else {
            return image
        }

        guard let boundingBox = zoomState.boundingBox else {
            print("ZoomVideoCompositor: WARNING - isZooming=true but boundingBox is NIL!")
            return image
        }

        // Only log at key progress points
        if zoomState.progress == 0.0 || zoomState.progress == 1.0 {
            print("ZoomVideoCompositor: Zoom progress=\(String(format: "%.2f", zoomState.progress)), bbox center(\(Int(boundingBox.centerX)),\(Int(boundingBox.centerY)))")
        }

        let progress = zoomState.progress

        // Calculate zoom parameters
        let fullWidth = videoSize.width
        let fullHeight = videoSize.height

        let zoomFactorX = fullWidth / boundingBox.width
        let zoomFactorY = fullHeight / boundingBox.height
        let zoomFactor = min(zoomFactorX, zoomFactorY, 2.2)  // Reduced max zoom for smoother effect

        // Calculate START and TARGET positions
        // START position: full screen center at zoom=1.0
        let startCenterX = fullWidth / 2
        let startCenterY = fullHeight / 2

        // TARGET position: use actual click location for smooth diagonal movement
        // Don't constrain - let it show black edges if needed for smooth motion
        let targetCenterX = boundingBox.centerX
        let targetCenterY = boundingBox.centerY

        // Now calculate CURRENT zoom and position using smooth interpolation
        let currentZoom = 1.0 + (zoomFactor - 1.0) * progress
        let zoomedWidth = fullWidth / currentZoom
        let zoomedHeight = fullHeight / currentZoom

        // Smooth diagonal interpolation - both zoom and position change together with same progress
        var currentCenterX = startCenterX + (targetCenterX - startCenterX) * progress
        var currentCenterY = startCenterY + (targetCenterY - startCenterY) * progress

        // Ensure current position is valid for current zoom level
        let minCurrentCenterX = zoomedWidth / 2
        let maxCurrentCenterX = fullWidth - zoomedWidth / 2
        let minCurrentCenterY = zoomedHeight / 2
        let maxCurrentCenterY = fullHeight - zoomedHeight / 2

        // Store unclamped values for debugging
        let unclampedX = currentCenterX
        let unclampedY = currentCenterY

        currentCenterX = max(minCurrentCenterX, min(maxCurrentCenterX, currentCenterX))
        currentCenterY = max(minCurrentCenterY, min(maxCurrentCenterY, currentCenterY))

        // Debug log only if clamping occurs
        if unclampedX != currentCenterX || unclampedY != currentCenterY {
            print("  ⚠️ Position clamped: (\(Int(unclampedX)),\(Int(unclampedY))) -> (\(Int(currentCenterX)),\(Int(currentCenterY))) at zoom:\(String(format: "%.2f", currentZoom))")
        }

        // Calculate source rect
        let sourceX = currentCenterX - zoomedWidth / 2
        let sourceY = currentCenterY - zoomedHeight / 2

        // Create source rectangle
        let sourceRect = CGRect(x: sourceX, y: sourceY, width: zoomedWidth, height: zoomedHeight)

        // Crop to the zoomed region
        let croppedImage = image.cropped(to: sourceRect)

        // Apply Lanczos scale filter for high-quality upsampling
        let scaleX = fullWidth / zoomedWidth
        let scaleY = fullHeight / zoomedHeight

        guard let lanczosFilter = CIFilter(name: "CILanczosScaleTransform") else {
            // Fallback to basic transform if filter unavailable
            let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
                .translatedBy(x: -sourceX, y: -sourceY)
            let scaledImage = croppedImage.transformed(by: scaleTransform)
            let outputRect = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
            return scaledImage.cropped(to: outputRect)
        }

        lanczosFilter.setValue(croppedImage, forKey: kCIInputImageKey)
        lanczosFilter.setValue(max(scaleX, scaleY), forKey: kCIInputScaleKey)
        lanczosFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let scaledImage = lanczosFilter.outputImage else {
            return image
        }

        // Translate to correct position
        let translatedImage = scaledImage.transformed(by: CGAffineTransform(translationX: -sourceX * scaleX, y: -sourceY * scaleY))

        // Ensure the output is exactly the right size
        let outputRect = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        let finalImage = translatedImage.cropped(to: outputRect)

        return finalImage
    }

    // MARK: - Cursor Overlay Rendering

    private func applyCursorOverlay(to image: CIImage, instruction: ZoomCompositionInstruction, currentTime: CMTime) -> CIImage {
        switch instruction.cursorOverlayMode {
        case .normal:
            return image
        case .clickHighlight:
            return applyClickHighlight(to: image, instruction: instruction, currentTime: currentTime)
        case .bigPointer:
            return applyBigPointer(to: image, instruction: instruction, currentTime: currentTime)
        }
    }

    private func applyClickHighlight(to image: CIImage, instruction: ZoomCompositionInstruction, currentTime: CMTime) -> CIImage {
        let currentTimeSeconds = CMTimeGetSeconds(currentTime)
        let videoSize = instruction.videoSize
        let highlightDuration: TimeInterval = 0.5
        var result = image

        for click in instruction.allClickEvents {
            let clickTimeSeconds = click.captureTimestamp.timeIntervalSince(instruction.recordingStartTime)
            let elapsed = currentTimeSeconds - clickTimeSeconds

            guard elapsed >= 0 && elapsed < highlightDuration else { continue }

            let progress = elapsed / highlightDuration
            let radius = 10.0 + 50.0 * progress  // 10 -> 60 px

            // Convert click coords to video coords (Y-flip: CIImage origin is bottom-left)
            let cx = (click.x / click.screenWidth) * videoSize.width
            let cy = videoSize.height - (click.y / click.screenHeight) * videoSize.height

            // Solid black filled circle using radial gradient
            let center = CIVector(x: cx, y: cy)
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": 0.0,
                "inputRadius1": radius,
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.black
            ])?.outputImage else { continue }

            // Create a transparency mask: radial gradient from opaque to transparent
            guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": 0.0,
                "inputRadius1": radius,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ])?.outputImage else { continue }

            let blackCircle = gradient.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: CIColor.clear).cropped(to: image.extent),
                kCIInputMaskImageKey: mask
            ]).cropped(to: image.extent)

            guard let composite = CIFilter(name: "CISourceOverCompositing") else { continue }
            composite.setValue(blackCircle, forKey: kCIInputImageKey)
            composite.setValue(result, forKey: kCIInputBackgroundImageKey)
            if let output = composite.outputImage {
                result = output.cropped(to: image.extent)
            }
        }

        return result
    }

    // Cached big pointer image
    private var _bigPointerImage: CIImage?
    private let bigPointerLock = NSLock()

    private func getBigPointerImage() -> CIImage? {
        bigPointerLock.lock()
        defer { bigPointerLock.unlock() }

        if let cached = _bigPointerImage {
            return cached
        }

        // Generate a cursor image programmatically (~2x the macOS default cursor)
        let width: CGFloat = 36
        let height: CGFloat = 48
        let nsImage = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            // Arrow shape (typical macOS cursor shape, scaled to fit)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 1))
            path.line(to: NSPoint(x: 2, y: 38))
            path.line(to: NSPoint(x: 11, y: 30))
            path.line(to: NSPoint(x: 19, y: 44))
            path.line(to: NSPoint(x: 24, y: 42))
            path.line(to: NSPoint(x: 16, y: 28))
            path.line(to: NSPoint(x: 26, y: 28))
            path.close()

            // Black outline
            NSColor.black.setStroke()
            path.lineWidth = 3
            path.stroke()

            // White fill
            NSColor.white.setFill()
            path.fill()

            return true
        }

        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let ciImage = CIImage(cgImage: cgImage)
        _bigPointerImage = ciImage
        return ciImage
    }

    private func applyBigPointer(to image: CIImage, instruction: ZoomCompositionInstruction, currentTime: CMTime) -> CIImage {
        let currentTimeSeconds = CMTimeGetSeconds(currentTime)
        let videoSize = instruction.videoSize

        // Find cursor position at current time via interpolation
        let positions = instruction.cursorPositions
        guard !positions.isEmpty else { return image }

        // Find the two positions bracketing current time
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0

        let firstTimeOffset = positions[0].captureTimestamp.timeIntervalSince(instruction.recordingStartTime)
        let lastTimeOffset = positions[positions.count - 1].captureTimestamp.timeIntervalSince(instruction.recordingStartTime)

        if currentTimeSeconds <= firstTimeOffset {
            // Before first position
            cursorX = (positions[0].x / positions[0].screenWidth) * videoSize.width
            cursorY = (positions[0].y / positions[0].screenHeight) * videoSize.height
        } else if currentTimeSeconds >= lastTimeOffset {
            // After last position
            let last = positions[positions.count - 1]
            cursorX = (last.x / last.screenWidth) * videoSize.width
            cursorY = (last.y / last.screenHeight) * videoSize.height
        } else {
            // Interpolate between two positions using binary search
            var lo = 0
            var hi = positions.count - 1
            while lo < hi - 1 {
                let mid = (lo + hi) / 2
                let midTime = positions[mid].captureTimestamp.timeIntervalSince(instruction.recordingStartTime)
                if midTime <= currentTimeSeconds {
                    lo = mid
                } else {
                    hi = mid
                }
            }

            let posA = positions[lo]
            let posB = positions[hi]
            let timeA = posA.captureTimestamp.timeIntervalSince(instruction.recordingStartTime)
            let timeB = posB.captureTimestamp.timeIntervalSince(instruction.recordingStartTime)
            let t = (timeB > timeA) ? (currentTimeSeconds - timeA) / (timeB - timeA) : 0.0

            let ax = (posA.x / posA.screenWidth) * videoSize.width
            let ay = (posA.y / posA.screenHeight) * videoSize.height
            let bx = (posB.x / posB.screenWidth) * videoSize.width
            let by = (posB.y / posB.screenHeight) * videoSize.height

            cursorX = ax + CGFloat(t) * (bx - ax)
            cursorY = ay + CGFloat(t) * (by - ay)
        }

        guard let pointerImage = getBigPointerImage() else { return image }

        // Position the pointer so its tip covers the real cursor exactly.
        // The arrow tip is drawn at (2, 1) in flipped NSImage coords.
        // In CIImage coords (bottom-left origin), the tip is at (2, height - 1).
        // We want that tip point to land at (cursorX, cursorY).
        let pointerExtent = pointerImage.extent
        let tipX: CGFloat = 2  // tip X in CIImage coords
        let tipY: CGFloat = pointerExtent.height - 1  // tip Y in CIImage coords (flipped from 1)
        let tx = cursorX - tipX
        let ty = cursorY - tipY
        let positioned = pointerImage.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        guard let composite = CIFilter(name: "CISourceOverCompositing") else { return image }
        composite.setValue(positioned, forKey: kCIInputImageKey)
        composite.setValue(image, forKey: kCIInputBackgroundImageKey)

        return composite.outputImage?.cropped(to: image.extent) ?? image
    }

    private func applyCanvasBackground(to image: CIImage, instruction: ZoomCompositionInstruction) -> CIImage {
        let border = max(1, instruction.borderWidth)
        let outputSize = instruction.canvasSize

        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))

        let positioned = normalized.transformed(by: CGAffineTransform(
            translationX: border,
            y: border
        ))

        let roundedContent = applyRoundedRectMask(to: positioned, radius: min(64, border * 4.0))

        let background = makeBackgroundImage(color: instruction.backgroundColor, image: instruction.backgroundImage, size: outputSize)

        let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
        compositeFilter.setValue(roundedContent, forKey: kCIInputImageKey)
        compositeFilter.setValue(background, forKey: kCIInputBackgroundImageKey)

        guard let result = compositeFilter.outputImage else {
            print("VideoProcessor: Failed to composite")
            return image
        }

        return result.cropped(to: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
    }

    private func makeBackgroundImage(color: CIColor?, image: CIImage?, size: CGSize) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)

        if let image = image {
            let sourceExtent = image.extent
            let scaleX = size.width / sourceExtent.width
            let scaleY = size.height / sourceExtent.height
            let scale = max(scaleX, scaleY)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let x = (size.width - scaled.extent.width) / 2
            let y = (size.height - scaled.extent.height) / 2
            let translated = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
            return translated.cropped(to: rect)
        }

        let bgColor = color ?? CIColor.black
        return CIImage(color: bgColor).cropped(to: rect)
    }

    private func applyRoundedRectMask(to image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
            .applyingFilter("CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            ])
            .cropped(to: extent)

        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent)
        ])
    }

    private func applySubtitles(to image: CIImage, instruction: ZoomCompositionInstruction, currentTime: CMTime) -> CIImage {
        guard !instruction.subtitles.isEmpty else {
            return image
        }

        let currentTimeSeconds = CMTimeGetSeconds(currentTime)

        // Debug: Log at specific intervals
        let second = Int(currentTimeSeconds)
        if currentTimeSeconds - Double(second) < 0.1 {  // Log once per second
            print("VideoProcessor: Time \(currentTimeSeconds)s, checking \(instruction.subtitles.count) subtitles")
            for (i, subtitle) in instruction.subtitles.enumerated() {
                print("  Subtitle \(i): '\(subtitle.text)' range: \(subtitle.timestamp)s - \(subtitle.timestamp + subtitle.duration)s")
            }
        }

        // Find the active subtitle at the current time
        for subtitle in instruction.subtitles {
            let startTime = subtitle.timestamp
            let endTime = subtitle.timestamp + subtitle.duration

            if currentTimeSeconds >= startTime && currentTimeSeconds <= endTime {
                // Render this subtitle onto the image
                print("VideoProcessor: ✓ Rendering subtitle '\(subtitle.text)' at time \(currentTimeSeconds)s")
                return renderSubtitleText(subtitle.text, videoSize: instruction.videoSize, onto: image)
            }
        }

        return image
    }

    private func applySelfieOverlay(to image: CIImage, instruction: ZoomCompositionInstruction, request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        guard !instruction.selfieOverlayEvents.isEmpty else {
            return image
        }

        let currentTimeSeconds = CMTimeGetSeconds(request.compositionTime)

        // Use composition time for rect lookup — coords are relative to the full canvas (including borders)
        guard let selfieRect = selfieRectAt(time: currentTimeSeconds, events: instruction.selfieOverlayEvents, videoSize: instruction.canvasSize) else {
            return image
        }

        let baseImage = image

        // Get selfie frame — render at new position for ALL times (even before selfie recording started,
        // use the first available frame)
        guard let selfieAsset = instruction.selfieAsset else {
            return baseImage
        }
        let selfieFrameTime = max(0, currentTimeSeconds - instruction.selfieStartOffset)
        let selfieTime = CMTime(seconds: selfieFrameTime, preferredTimescale: 600)
        guard let selfieImage = getSelfieFrame(from: selfieAsset, at: selfieTime) else {
            return baseImage
        }

        // No extra mirror needed — the recorded selfie video already has the user's mirror preference
        // applied via AVCaptureConnection.isVideoMirrored

        // Aspect-fill: scale uniformly to fill the rect, then crop excess
        let scale = max(selfieRect.width / selfieImage.extent.width, selfieRect.height / selfieImage.extent.height)
        let scaled = selfieImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Center-crop to match the rect size
        let cropX = scaled.extent.minX + (scaled.extent.width - selfieRect.width) / 2
        let cropY = scaled.extent.minY + (scaled.extent.height - selfieRect.height) / 2
        let cropped = scaled.cropped(to: CGRect(x: cropX, y: cropY, width: selfieRect.width, height: selfieRect.height))
        let translated = cropped.transformed(by: CGAffineTransform(translationX: selfieRect.minX - cropped.extent.minX, y: selfieRect.minY - cropped.extent.minY))

        let roundedSelfie = applyRoundedRectMask(to: translated, radius: min(selfieRect.width, selfieRect.height) * 0.12)

        let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
        compositeFilter.setValue(roundedSelfie, forKey: kCIInputImageKey)
        compositeFilter.setValue(baseImage, forKey: kCIInputBackgroundImageKey)

        return compositeFilter.outputImage ?? baseImage
    }

    private func selfieRectAt(time: TimeInterval, events: [SelfieOverlayEvent], videoSize: CGSize) -> CGRect? {
        guard !events.isEmpty else { return nil }

        let sorted = events.sorted { $0.time < $1.time }
        var last = sorted[0]

        for event in sorted {
            if event.time <= time {
                last = event
            } else {
                break
            }
        }

        let width = max(1, videoSize.width * last.width)
        let height = max(1, videoSize.height * last.height)
        let x = videoSize.width * last.x
        let y = videoSize.height * last.y

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func renderSubtitleText(_ text: String, videoSize: CGSize, onto image: CIImage) -> CIImage {
        let fontSize: CGFloat = 72
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        // Create attributed string with background
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.8),
            .paragraphStyle: paragraphStyle
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)

        // Calculate text size
        let maxWidth = videoSize.width * 0.9
        let textSize = attributedString.boundingRect(
            with: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size

        // Add padding
        let padding: CGFloat = 20
        let textWidth = min(textSize.width + padding * 2, maxWidth)
        let textHeight = textSize.height + padding * 2

        // Position at bottom center (40pt from bottom like SubtitleOverlay)
        let textX = (videoSize.width - textWidth) / 2
        let textY: CGFloat = 40

        // Create image from text
        let textRect = CGRect(x: 0, y: 0, width: textWidth, height: textHeight)
        let textImage = NSImage(size: textRect.size)
        textImage.lockFocus()

        // Draw rounded background
        let backgroundPath = NSBezierPath(roundedRect: textRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.8).setFill()
        backgroundPath.fill()

        // Draw text
        let textDrawRect = CGRect(x: padding, y: padding, width: textWidth - padding * 2, height: textHeight - padding * 2)
        attributedString.draw(in: textDrawRect)

        textImage.unlockFocus()

        // Convert NSImage to CIImage
        guard let cgImage = textImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let textCIImage = CIImage(cgImage: cgImage)

        // Position text overlay on video
        let translatedText = textCIImage.transformed(by: CGAffineTransform(translationX: textX, y: textY))

        // Composite text over video
        let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
        compositeFilter.setValue(translatedText, forKey: kCIInputImageKey)
        compositeFilter.setValue(image, forKey: kCIInputBackgroundImageKey)

        return compositeFilter.outputImage ?? image
    }
}

// Custom instruction that holds zoom data
class ZoomCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let videoSize: CGSize
    let clickGroups: [[ClickEventNew]]
    let cursorPositions: [CursorPositionNew]
    let trackingMode: TrackingMode
    let recordingStartTime: Date
    let subtitles: [SubtitleEntryApple]
    let timingOffset: TimeInterval
    let addBorders: Bool
    let selfieAsset: AVAsset?  // Read selfie frames via AVAssetImageGenerator
    let selfieOverlayEvents: [SelfieOverlayEvent]
    let selfieVideoSize: CGSize?
    let selfieStartOffset: TimeInterval
    let backgroundColor: CIColor?
    let backgroundImage: CIImage?
    let borderEnabled: Bool
    let borderWidth: CGFloat
    let canvasSize: CGSize
    let cursorOverlayMode: CursorOverlayMode
    let allClickEvents: [ClickEventNew]

    init(
        trackID: CMPersistentTrackID,
        sourceTrackID: CMPersistentTrackID,
        timeRange: CMTimeRange,
        videoSize: CGSize,
        clickGroups: [[ClickEventNew]],
        cursorPositions: [CursorPositionNew],
        trackingMode: TrackingMode,
        recordingStartTime: Date,
        subtitles: [SubtitleEntryApple],
        timingOffset: TimeInterval,
        addBorders: Bool = false,
        selfieAsset: AVAsset? = nil,
        selfieOverlayEvents: [SelfieOverlayEvent] = [],
        selfieVideoSize: CGSize? = nil,
        selfieStartOffset: TimeInterval = 0,
        backgroundColor: CIColor? = nil,
        backgroundImage: CIImage? = nil,
        borderEnabled: Bool = false,
        borderWidth: CGFloat = 0,
        canvasSize: CGSize,
        cursorOverlayMode: CursorOverlayMode = .normal,
        allClickEvents: [ClickEventNew] = []
    ) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.videoSize = videoSize
        self.clickGroups = clickGroups
        self.cursorPositions = cursorPositions
        self.trackingMode = trackingMode
        self.recordingStartTime = recordingStartTime
        self.subtitles = subtitles
        self.timingOffset = timingOffset
        self.addBorders = addBorders
        self.selfieAsset = selfieAsset
        self.selfieOverlayEvents = selfieOverlayEvents
        self.selfieVideoSize = selfieVideoSize
        self.selfieStartOffset = selfieStartOffset
        self.backgroundColor = backgroundColor
        self.backgroundImage = backgroundImage
        self.borderEnabled = borderEnabled
        self.borderWidth = borderWidth
        self.canvasSize = canvasSize
        self.cursorOverlayMode = cursorOverlayMode
        self.allClickEvents = allClickEvents
        super.init()

        // Only the main video track is required via composition.
        // Selfie frames are read via AVAssetImageGenerator (no composition track needed).
        self.requiredSourceTrackIDs = [NSNumber(value: Int(sourceTrackID))]
        print("ZoomCompositionInstruction: Initialized with sourceTrackID: \(sourceTrackID), selfieAsset: \(selfieAsset != nil), requiredSourceTrackIDs: \(String(describing: requiredSourceTrackIDs))")
    }

    func getZoomState(at time: CMTime) -> ZoomState {
        let currentTimeSeconds = CMTimeGetSeconds(time)

        // Handle record window mode (no zoom or tracking)
        if trackingMode == .recordWindow {
            // Return default state - no zoom, no transform
            return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
        }

        // Handle cursor follow mode
        if trackingMode == .followCursor {
            return getCursorFollowState(at: currentTimeSeconds)
        }

        // Handle zoom on clicks mode
        let zoomInDuration: TimeInterval = 1.0
        let preClickPause: TimeInterval = 0.4   // Pause after zoom in, before click
        let postClickPause: TimeInterval = 0.4  // Pause after click, before zoom out
        let zoomOutDuration: TimeInterval = 1.0

        // Only log every 30 frames to avoid spam
        if Int(currentTimeSeconds * 30) % 30 == 0 {
            print("ZoomCompositionInstruction: getZoomState at \(currentTimeSeconds)s")
            print("  - Total click groups: \(clickGroups.count)")
            print("  - Tracking mode: \(trackingMode)")
        }

        for group in clickGroups {
            guard !group.isEmpty else { continue }

            let firstClick = group[0]
            let lastClick = group[group.count - 1]

            let firstTriggerTime = firstClick.captureTimestamp.timeIntervalSince(recordingStartTime)
            let lastTriggerTime = lastClick.captureTimestamp.timeIntervalSince(recordingStartTime)

            // Timeline relative to first click at 0.0s:
            // -1.4s: Start zoom in (1.0s duration)
            // -0.4s: Finish zoom in, start pre-click pause (0.4s)
            //  0.0s: First click happens (fully zoomed)
            // Then pan between clicks if multiple in group
            // After last click:
            //  0.0s to 0.4s: Post-click pause (0.4s)
            //  0.4s: Start zoom out (1.0s duration)
            //  1.4s: Finish zoom out

            // Zoom starts before first click, ends after last click
            let zoomStartTime = firstTriggerTime - (zoomInDuration + preClickPause)
            let zoomEndTime = lastTriggerTime + postClickPause + zoomOutDuration

            if currentTimeSeconds >= zoomStartTime && currentTimeSeconds <= zoomEndTime {
                // Only log once when entering zoom session
                if Int((currentTimeSeconds - zoomStartTime) * 30) < 2 {
                    print("  - ✓ ZOOM SESSION START for \(group.count) click(s):")
                    for (i, click) in group.enumerated() {
                        let t = click.captureTimestamp.timeIntervalSince(recordingStartTime)
                        print("    Click\(i): at \(String(format: "%.2f", t))s")
                    }
                    print("    Zoom timeline: start=\(String(format: "%.2f", zoomStartTime))s, end=\(String(format: "%.2f", zoomEndTime))s")
                }

                var progress: CGFloat = 0
                var currentBoundingBox: BoundingBox? = nil

                // Zoom in phase (before first click)
                if currentTimeSeconds < firstTriggerTime - preClickPause {
                    // Zooming in to first click
                    let inProgress = (currentTimeSeconds - zoomStartTime) / zoomInDuration
                    progress = easeInOutCubic(CGFloat(inProgress))
                    currentBoundingBox = calculateBoundingBox(for: [firstClick], videoSize: videoSize)
                }
                // Hold/pan phase (from first click to last click + pause)
                else if currentTimeSeconds < lastTriggerTime + postClickPause {
                    // Fully zoomed, may need to pan between clicks
                    progress = 1.0

                    // Find the most recent click we've passed
                    var currentClickIndex = 0
                    for (index, click) in group.enumerated() {
                        let clickTime = click.captureTimestamp.timeIntervalSince(recordingStartTime)
                        if currentTimeSeconds >= clickTime {
                            currentClickIndex = index
                        }
                    }

                    let currentClick = group[currentClickIndex]
                    let currentClickTime = currentClick.captureTimestamp.timeIntervalSince(recordingStartTime)

                    var fromClick: ClickEventNew = currentClick
                    var toClick: ClickEventNew? = nil
                    var transitionProgress: CGFloat = 0

                    // Check if we should be panning to the next click
                    if currentClickIndex < group.count - 1 && currentTimeSeconds >= currentClickTime + postClickPause {
                        // We're past this click's pause - pan to next click
                        let nextClick = group[currentClickIndex + 1]
                        let nextClickTime = nextClick.captureTimestamp.timeIntervalSince(recordingStartTime)

                        fromClick = currentClick
                        toClick = nextClick

                        let panStartTime = currentClickTime + postClickPause
                        let actualPanDuration = nextClickTime - panStartTime

                        // Calculate dynamic pan duration based on distance
                        let fromBox = calculateBoundingBox(for: [currentClick], videoSize: videoSize)
                        let toBox = calculateBoundingBox(for: [nextClick], videoSize: videoSize)

                        var adjustedPanDuration = actualPanDuration

                        if let from = fromBox, let to = toBox {
                            // Calculate pixel distance between clicks
                            let dx = to.centerX - from.centerX
                            let dy = to.centerY - from.centerY
                            let distance = sqrt(dx * dx + dy * dy)

                            // Check if next click would be outside current zoom window
                            // Zoom window size is roughly the bounding box size
                            let zoomWindowRadius = max(from.width, from.height) / 2

                            if distance > zoomWindowRadius * 0.7 {
                                // Next click is far - need faster pan
                                // Calculate minimum pan speed to keep click visible
                                let minPanSpeed: CGFloat = 800 // pixels per second minimum
                                let requiredDuration = TimeInterval(distance / minPanSpeed)

                                // Use the shorter of actual time or required time (faster pan)
                                adjustedPanDuration = min(actualPanDuration, max(requiredDuration, 0.3))

                                // Log adjustment on first frame
                                if Int((currentTimeSeconds - panStartTime) * 30) < 2 {
                                    print("  - Pan adjustment: distance=\(String(format: "%.0f", distance))px, zoomRadius=\(String(format: "%.0f", zoomWindowRadius))px")
                                    print("    actualDuration=\(String(format: "%.2f", actualPanDuration))s, adjustedDuration=\(String(format: "%.2f", adjustedPanDuration))s")
                                }
                            }
                        }

                        if adjustedPanDuration > 0 {
                            // Calculate progress using adjusted duration for smoother tracking
                            let elapsed = currentTimeSeconds - panStartTime
                            transitionProgress = CGFloat(elapsed / adjustedPanDuration)
                            transitionProgress = min(max(transitionProgress, 0), 1)
                        }

                        // Log panning details every 15 frames
                        if Int(currentTimeSeconds * 30) % 15 == 0 {
                            print("  - PANNING: click\(currentClickIndex)→click\(currentClickIndex + 1), progress: \(String(format: "%.2f", transitionProgress))")
                        }
                    } else {
                        // Holding at current click (either at first click or during pause after a click)
                        fromClick = currentClick
                        toClick = nil

                        if Int(currentTimeSeconds * 30) % 30 == 0 {
                            print("  - HOLDING at click\(currentClickIndex)")
                        }
                    }

                    // Calculate interpolated bounding box
                    if let to = toClick {
                        // Panning between two clicks
                        let fromBox = calculateBoundingBox(for: [fromClick], videoSize: videoSize)
                        let toBox = calculateBoundingBox(for: [to], videoSize: videoSize)
                        currentBoundingBox = interpolateBoundingBox(
                            from: fromBox,
                            to: toBox,
                            progress: easeInOutCubic(transitionProgress)
                        )
                    } else {
                        // Holding at a single click
                        currentBoundingBox = calculateBoundingBox(for: [fromClick], videoSize: videoSize)
                    }
                }
                // Zoom out phase (after last click + pause)
                else {
                    // Zooming out from last click
                    let outProgress = (currentTimeSeconds - (lastTriggerTime + postClickPause)) / zoomOutDuration
                    progress = 1.0 - easeInOutCubic(CGFloat(outProgress))
                    currentBoundingBox = calculateBoundingBox(for: [lastClick], videoSize: videoSize)
                }

                return ZoomState(isZooming: true, progress: progress, boundingBox: currentBoundingBox)
            }
        }

        return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
    }

    // Cache for smoothed cursor positions to reduce jitter - thread-safe
    private var smoothedPositionCache: [TimeInterval: (x: CGFloat, y: CGFloat)] = [:]
    private let cacheLock = NSLock()

    private func getCursorFollowState(at currentTimeSeconds: TimeInterval) -> ZoomState {
        // Find cursor position closest to current time
        guard !cursorPositions.isEmpty else {
            return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
        }

        // With frame-synchronized cursor sampling, cursor position and video frame
        // are captured at the EXACT same moment. No offset needed!
        // currentTimeSeconds is relative to recording start
        // cursor timestamps are absolute Date() values from recording start
        let targetTime = recordingStartTime.addingTimeInterval(currentTimeSeconds)

        // Debug: Log every 30 frames (once per second at 30fps)
        if Int(currentTimeSeconds * 30) % 30 == 0 {
            print("Frame at \(currentTimeSeconds)s → looking for cursor at \(targetTime)")
        }

        // Find the two positions to interpolate between
        var beforePosition: CursorPositionNew?
        var afterPosition: CursorPositionNew?

        for position in cursorPositions {
            let positionTime = position.captureTimestamp

            if positionTime <= targetTime {
                if beforePosition == nil || positionTime > beforePosition!.captureTimestamp {
                    beforePosition = position
                }
            }

            if positionTime >= targetTime {
                if afterPosition == nil || positionTime < afterPosition!.captureTimestamp {
                    afterPosition = position
                }
            }
        }

        // Determine which position to use and interpolate if possible
        var finalX: CGFloat
        var finalY: CGFloat

        if let before = beforePosition, let after = afterPosition {
            // Interpolate between the two positions
            let beforeTime = before.captureTimestamp.timeIntervalSince(recordingStartTime)
            let afterTime = after.captureTimestamp.timeIntervalSince(recordingStartTime)

            if afterTime > beforeTime {
                let progress = CGFloat((currentTimeSeconds - beforeTime) / (afterTime - beforeTime))

                let beforeX = (before.x / before.screenWidth) * videoSize.width
                let beforeY = (before.y / before.screenHeight) * videoSize.height
                let afterX = (after.x / after.screenWidth) * videoSize.width
                let afterY = (after.y / after.screenHeight) * videoSize.height

                finalX = beforeX + (afterX - beforeX) * progress
                finalY = beforeY + (afterY - beforeY) * progress
            } else {
                // Same time, use before position
                finalX = (before.x / before.screenWidth) * videoSize.width
                finalY = (before.y / before.screenHeight) * videoSize.height
            }
        } else if let before = beforePosition {
            // Only have before position
            finalX = (before.x / before.screenWidth) * videoSize.width
            finalY = (before.y / before.screenHeight) * videoSize.height
        } else if let after = afterPosition {
            // Only have after position
            finalX = (after.x / after.screenWidth) * videoSize.width
            finalY = (after.y / after.screenHeight) * videoSize.height
        } else {
            return ZoomState(isZooming: false, progress: 0, boundingBox: nil)
        }

        // Apply temporal smoothing to reduce jitter/flickering
        // Use exponential moving average with neighboring frames
        let smoothingWindow: TimeInterval = 0.1  // 100ms window (3-6 frames at 30-60fps)
        let smoothedPosition = applySmoothingToCursor(
            x: finalX,
            y: finalY,
            time: currentTimeSeconds,
            window: smoothingWindow
        )

        finalX = smoothedPosition.x
        finalY = smoothedPosition.y

        // Create a larger zoom area around cursor for smoother tracking
        // Larger area gives cursor more room to move before going out of frame
        let zoomWidth: CGFloat = 1200
        let zoomHeight: CGFloat = 900

        let boundingBox = BoundingBox(
            centerX: finalX,
            centerY: finalY,
            width: zoomWidth,
            height: zoomHeight
        )

        // Always fully zoomed in cursor follow mode
        return ZoomState(isZooming: true, progress: 1.0, boundingBox: boundingBox)
    }

    private func applySmoothingToCursor(x: CGFloat, y: CGFloat, time: TimeInterval, window: TimeInterval) -> (x: CGFloat, y: CGFloat) {
        // Check cache first - thread-safe
        let cacheKey = time
        cacheLock.lock()
        if let cached = smoothedPositionCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Collect positions within the time window
        var relevantPositions: [(x: CGFloat, y: CGFloat, time: TimeInterval)] = []

        for position in cursorPositions {
            let posTime = position.captureTimestamp.timeIntervalSince(recordingStartTime)
            let timeDiff = abs(posTime - time)

            if timeDiff <= window {
                let normX = (position.x / position.screenWidth) * videoSize.width
                let normY = (position.y / position.screenHeight) * videoSize.height
                relevantPositions.append((x: normX, y: normY, time: posTime))
            }
        }

        guard !relevantPositions.isEmpty else {
            // No positions in window, use original values
            cacheLock.lock()
            smoothedPositionCache[cacheKey] = (x: x, y: y)
            cacheLock.unlock()
            return (x: x, y: y)
        }

        // Apply weighted average - positions closer in time get higher weight
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        var totalWeight: CGFloat = 0

        for pos in relevantPositions {
            let timeDiff = abs(pos.time - time)
            // Gaussian-like weight: closer positions have more influence
            let weight = exp(-pow(timeDiff / (window / 3), 2))

            weightedX += pos.x * weight
            weightedY += pos.y * weight
            totalWeight += weight
        }

        let smoothedX = weightedX / totalWeight
        let smoothedY = weightedY / totalWeight

        // Cache result - thread-safe
        cacheLock.lock()
        smoothedPositionCache[cacheKey] = (x: smoothedX, y: smoothedY)
        cacheLock.unlock()

        return (x: smoothedX, y: smoothedY)
    }

    private func calculateBoundingBox(for group: [ClickEventNew], videoSize: CGSize) -> BoundingBox? {
        guard !group.isEmpty else {
            print("ZoomVideoCompositor: calculateBoundingBox - empty group, returning nil")
            return nil
        }

        print("ZoomVideoCompositor: calculateBoundingBox for \(group.count) click(s), videoSize: \(videoSize)")

        var minX: CGFloat = .infinity
        var minY: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var maxY: CGFloat = -.infinity

        for click in group {
            // Normalize coordinates to video size
            let x = (click.x / click.screenWidth) * videoSize.width
            // Click coordinates are in top-left origin, but CIImage uses bottom-left origin
            // Convert: bottom-left Y = height - top-left Y
            let y = videoSize.height - ((click.y / click.screenHeight) * videoSize.height)

            print("  Click: (\(click.x), \(click.y)) in (\(click.screenWidth)x\(click.screenHeight)) -> normalized to (\(x), \(y)) in video")

            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        // Add padding
        let width = maxX - minX
        let height = maxY - minY
        let paddingX = max(width * 0.3, 150)
        let paddingY = max(height * 0.3, 150)

        minX = max(0, minX - paddingX)
        minY = max(0, minY - paddingY)
        maxX = min(videoSize.width, maxX + paddingX)
        maxY = min(videoSize.height, maxY + paddingY)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let boxWidth = maxX - minX
        let boxHeight = maxY - minY

        let bbox = BoundingBox(centerX: centerX, centerY: centerY, width: boxWidth, height: boxHeight)
        print("  -> BoundingBox: center(\(centerX), \(centerY)), size(\(boxWidth)x\(boxHeight))")

        return bbox
    }

    private func interpolateBoundingBox(from: BoundingBox?, to: BoundingBox?, progress: CGFloat) -> BoundingBox? {
        guard let from = from, let to = to else {
            return from ?? to
        }

        // Smoothly interpolate center position and size
        let centerX = from.centerX + (to.centerX - from.centerX) * progress
        let centerY = from.centerY + (to.centerY - from.centerY) * progress
        let width = from.width + (to.width - from.width) * progress
        let height = from.height + (to.height - from.height) * progress

        return BoundingBox(centerX: centerX, centerY: centerY, width: width, height: height)
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

struct ZoomState {
    let isZooming: Bool
    let progress: CGFloat
    let boundingBox: BoundingBox?
}

struct BoundingBox {
    let centerX: CGFloat
    let centerY: CGFloat
    let width: CGFloat
    let height: CGFloat
}
