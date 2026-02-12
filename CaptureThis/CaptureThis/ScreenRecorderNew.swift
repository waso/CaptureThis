import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

// Frame data with exact capture timestamp
struct CapturedFrame {
    let timestamp: Date
    let presentationTime: CMTime
}

class ScreenRecorderNew: NSObject {
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var micWriterInput: AVAssetWriterInput?  // Separate track for mic
    private var tempRecordingURL: URL?
    private var resolution: CGSize
    var recordedVideoURL: URL?  // Made public for fallback access
    private var isRecording = false
    private var isPaused = false
    private var startTime: Date?
    private var windowID: CGWindowID?  // Optional window ID for window recording

    // ScreenCaptureKit
    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    // Separate microphone capture session (SCStream only captures system audio, not mic input)
    private var micCaptureSession: AVCaptureSession?
    private var micAudioDataOutput: AVCaptureAudioDataOutput?

    // Callback to notify when each frame is captured (for cursor sampling)
    var onFrameCaptured: ((Date) -> Void)?

    // Flag to enable/disable audio recording
    var recordAudio: Bool = true

    // Thread-safe mute flag - can be toggled while recording
    private let audioMuteLock = NSLock()
    private var _isAudioMuted: Bool = false
    var isAudioMuted: Bool {
        get {
            audioMuteLock.lock()
            defer { audioMuteLock.unlock() }
            return _isAudioMuted
        }
        set {
            audioMuteLock.lock()
            _isAudioMuted = newValue
            audioMuteLock.unlock()
            // Sync with stream output for window recording
            print("ScreenRecorder: isAudioMuted changed to \(newValue), syncing with streamOutput (exists: \(streamOutput != nil))")
            streamOutput?.isAudioMuted = newValue
        }
    }

    // Specific audio device to use (nil = default device)
    var audioDevice: AVCaptureDevice?

    // Specific display to record (nil = main display)
    var displayID: CGDirectDisplayID?

    // Window IDs to exclude from full-screen recording (e.g. selfie preview window)
    var excludeWindowIDs: [CGWindowID] = []

    /// Called when the first valid video frame is received from SCStream.
    /// Used for synchronized recording start — MainViewController waits for this
    /// before calling beginWriting() on all recorders.
    var onFirstFrameReady: (() -> Void)?

    /// Starts writing frames to disk. Called by MainViewController after all streams are ready.
    func beginWriting() {
        streamOutput?.writingEnabled = true
        print("ScreenRecorder: Writing enabled")
    }

    /// Represents a display/screen with its ID and name
    struct DisplayInfo {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
        let isMain: Bool
    }

    init(resolution: CGSize, windowID: CGWindowID? = nil, displayID: CGDirectDisplayID? = nil) {
        self.resolution = resolution
        self.windowID = windowID
        self.displayID = displayID
    }

    static func checkPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Returns all available displays/screens with their names
    static func availableDisplays() -> [DisplayInfo] {
        var displays: [DisplayInfo] = []

        // Get all active displays
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        guard displayCount > 0 else { return displays }

        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)

        let mainDisplayID = CGMainDisplayID()

        for displayID in activeDisplays {
            let bounds = CGDisplayBounds(displayID)
            let isMain = displayID == mainDisplayID

            // Try to get the display name from NSScreen
            var displayName = "Display \(displayID)"

            for screen in NSScreen.screens {
                // Get the display ID from NSScreen's deviceDescription
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                   screenNumber == displayID {
                    displayName = screen.localizedName
                    break
                }
            }

            // Add suffix for main display
            if isMain && !displayName.contains("Built-in") {
                displayName = "\(displayName) (Main)"
            }

            displays.append(DisplayInfo(
                id: displayID,
                name: displayName,
                frame: bounds,
                isMain: isMain
            ))
        }

        // Sort so main display is first
        displays.sort { $0.isMain && !$1.isMain }

        return displays
    }

    /// Returns all available audio input devices (microphones)
    static func availableAudioDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices
    }

    func startRecording(completion: @escaping (Error?) -> Void) {
        // Clean up any old temp files from previous recordings
        let tempDir = FileManager.default.temporaryDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            let oldTempFiles = contents.filter { $0.lastPathComponent.hasPrefix("screen-temp-") && $0.pathExtension == "mp4" }

            for oldFile in oldTempFiles {
                do {
                    try FileManager.default.removeItem(at: oldFile)
                    print("ScreenRecorder: Cleaned up old temp file: \(oldFile.lastPathComponent)")
                } catch {
                    print("ScreenRecorder: Warning - Could not remove old temp file \(oldFile.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            print("ScreenRecorder: Warning - Could not scan temp directory for cleanup: \(error.localizedDescription)")
        }

        // Create temp file for recording with unique name
        let uniqueID = UUID().uuidString.prefix(8)
        tempRecordingURL = tempDir.appendingPathComponent("screen-temp-\(Date().timeIntervalSince1970)-\(uniqueID).mp4")

        guard let outputURL = tempRecordingURL else {
            completion(NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output URL"]))
            return
        }

        print("ScreenRecorder: Recording to temp file: \(outputURL.path)")
        print("ScreenRecorder: recordAudio=\(recordAudio), audioDevice=\(audioDevice?.localizedName ?? "default")")

        // Use ScreenCaptureKit for both window recording and full-screen recording
        if let windowID = windowID {
            startWindowRecording(outputURL: outputURL, completion: completion)
        } else {
            startDisplayRecording(outputURL: outputURL, completion: completion)
        }
    }

    private func startDisplayRecording(outputURL: URL, completion: @escaping (Error?) -> Void) {
        let targetDisplayID = self.displayID ?? CGMainDisplayID()

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
                    completion(NSError(domain: "ScreenRecorder", code: 7, userInfo: [NSLocalizedDescriptionKey: "Display not found"]))
                    return
                }

                // Find windows to exclude (e.g. selfie preview)
                let excludeWindows = content.windows.filter { self.excludeWindowIDs.contains($0.windowID) }
                if !excludeWindows.isEmpty {
                    print("ScreenRecorder: Excluding \(excludeWindows.count) window(s) from display recording")
                }

                let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)

                let config = SCStreamConfiguration()
                config.width = Int(self.resolution.width)
                config.height = Int(self.resolution.height)
                config.scalesToFit = true
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 5
                config.showsCursor = true
                config.capturesAudio = self.recordAudio
                if self.recordAudio {
                    config.sampleRate = 44100
                    config.channelCount = 2
                }
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.backgroundColor = .clear

                print("ScreenRecorder: Display recording config - \(config.width)x\(config.height) at 60fps, display \(targetDisplayID), audio: \(self.recordAudio)")

                self.setupAssetWriter(outputURL: outputURL) { [weak self] writerError in
                    if let writerError = writerError {
                        completion(writerError)
                        return
                    }

                    guard let self = self else {
                        completion(NSError(domain: "ScreenRecorder", code: 6, userInfo: [NSLocalizedDescriptionKey: "Recorder deallocated"]))
                        return
                    }

                    let output = StreamOutput(assetWriter: self.assetWriter,
                                              assetWriterInput: self.assetWriterInput,
                                              audioWriterInput: self.audioWriterInput,
                                              micWriterInput: self.micWriterInput,
                                              onFrameCaptured: self.onFrameCaptured)
                    output.isAudioMuted = self.isAudioMuted
                    output.onFirstFrameReady = self.onFirstFrameReady
                    // If no onFirstFrameReady callback, start writing immediately (no gating)
                    output.writingEnabled = (self.onFirstFrameReady == nil)
                    self.streamOutput = output

                    Task {
                        do {
                            guard let streamOutput = self.streamOutput else { return }

                            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.vibe.screenrecorder.output"))
                            if self.recordAudio {
                                try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.vibe.screenrecorder.audio"))
                            }

                            try await stream.startCapture()

                            self.stream = stream
                            self.isRecording = true
                            self.startTime = Date()

                            // Start separate microphone capture (SCStream only captures system audio)
                            if self.recordAudio {
                                self.startMicrophoneCapture()
                            }

                            print("ScreenRecorder: Display recording started")
                            completion(nil)
                        } catch {
                            completion(error)
                        }
                    }
                }
            } catch {
                completion(error)
            }
        }
    }

    private func startWindowRecording(outputURL: URL, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                // Get available content
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                // Find the window with matching ID
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    completion(NSError(domain: "ScreenRecorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "Window not found"]))
                    return
                }

                print("ScreenRecorder: Found window: \(window.title ?? "Untitled") - \(window.owningApplication?.applicationName ?? "Unknown")")
                print("ScreenRecorder: Window size: \(window.frame.width)x\(window.frame.height)")

                // Create filter for just this window
                let filter = SCContentFilter(desktopIndependentWindow: window)

                // Configure stream with high quality settings
                let config = SCStreamConfiguration()

                // Capture at high resolution for quality
                // The resolution parameter contains the desired output quality (e.g., 4K)
                let targetWidth = Int(self.resolution.width)
                let targetHeight = Int(self.resolution.height)

                config.width = targetWidth
                config.height = targetHeight
                config.scalesToFit = true  // Scale window content to target resolution
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 FPS
                config.queueDepth = 5
                config.showsCursor = true

                // Capture system audio from the window (e.g. YouTube, music) only when audio recording is enabled
                config.capturesAudio = self.recordAudio
                if self.recordAudio {
                    config.sampleRate = 44100
                    config.channelCount = 2
                }

                // High quality capture settings
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.backgroundColor = .clear

                print("ScreenRecorder: Window recording config - \(config.width)x\(config.height) at 60fps, audio: \(self.recordAudio)")

                // Set up asset writer
                self.setupAssetWriter(outputURL: outputURL) { [weak self] writerError in
                    if let writerError = writerError {
                        completion(writerError)
                        return
                    }

                    // Create stream output
                    guard let self = self else {
                        completion(NSError(domain: "ScreenRecorder", code: 6, userInfo: [NSLocalizedDescriptionKey: "Recorder deallocated"]))
                        return
                    }

                    let output = StreamOutput(assetWriter: self.assetWriter,
                                              assetWriterInput: self.assetWriterInput,
                                              audioWriterInput: self.audioWriterInput,
                                              micWriterInput: self.micWriterInput,
                                              onFrameCaptured: self.onFrameCaptured)
                    output.isAudioMuted = self.isAudioMuted
                    output.onFirstFrameReady = self.onFirstFrameReady
                    output.writingEnabled = (self.onFirstFrameReady == nil)
                    self.streamOutput = output
                    print("ScreenRecorder: StreamOutput created, initial isAudioMuted=\(self.isAudioMuted)")

                    // Create and start stream
                    Task {
                        do {
                            guard let streamOutput = self.streamOutput else { return }

                            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.vibe.screenrecorder.output"))

                            // Add system audio capture only when audio recording is enabled
                            if self.recordAudio {
                                try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.vibe.screenrecorder.audio"))
                                print("ScreenRecorder: System audio stream output added")
                            }

                            try await stream.startCapture()

                            self.stream = stream
                            self.isRecording = true
                            self.startTime = Date()

                            // Start separate microphone capture for window recording
                            // SCStream only captures system audio, not mic input
                            if self.recordAudio {
                                self.startMicrophoneCapture()
                            }

                            print("ScreenRecorder: Window recording started")
                            completion(nil)
                        } catch {
                            completion(error)
                        }
                    }
                }
            } catch {
                completion(error)
            }
        }
    }

    /// Starts a dedicated AVCaptureSession for microphone input.
    /// SCStream only captures system audio, not mic input.
    /// This is needed because SCStream.capturesAudio only captures system audio, not mic.
    private func startMicrophoneCapture() {
        let session = AVCaptureSession()
        session.beginConfiguration()

        let device: AVCaptureDevice?
        if let specificDevice = self.audioDevice {
            device = specificDevice
            print("ScreenRecorder: Mic session using specific device: \(specificDevice.localizedName)")
        } else {
            device = AVCaptureDevice.default(for: .audio)
            print("ScreenRecorder: Mic session using default device: \(device?.localizedName ?? "none")")
        }

        guard let micDevice = device else {
            print("ScreenRecorder: No microphone available for window recording")
            return
        }

        do {
            let micInput = try AVCaptureDeviceInput(device: micDevice)
            if session.canAddInput(micInput) {
                session.addInput(micInput)
            } else {
                print("ScreenRecorder: Cannot add mic input to session")
                return
            }

            let output = AVCaptureAudioDataOutput()
            let micQueue = DispatchQueue(label: "com.screenrecorder.micqueue")
            output.setSampleBufferDelegate(self, queue: micQueue)

            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                print("ScreenRecorder: Cannot add mic output to session")
                return
            }

            micAudioDataOutput = output
            session.commitConfiguration()
            session.startRunning()
            micCaptureSession = session
            print("ScreenRecorder: Microphone capture started for window recording")
        } catch {
            print("ScreenRecorder: Error setting up mic capture: \(error)")
        }
    }

    private func setupAssetWriter(outputURL: URL, completion: @escaping (Error?) -> Void) {
        do {
            // Remove existing file if any
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            // Create asset writer
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            // Configure video settings with high quality for 4K
            // Calculate bitrate based on resolution (higher for 4K)
            let pixels = resolution.width * resolution.height
            let baseBitrate: Int
            if pixels >= 3840 * 2160 {
                // 4K or higher - use 50 Mbps
                baseBitrate = 50_000_000
            } else if pixels >= 1920 * 1080 {
                // 1080p - use 20 Mbps
                baseBitrate = 20_000_000
            } else {
                // Lower res - use 10 Mbps
                baseBitrate = 10_000_000
            }

            // H.264 encoding - remove AVVideoQualityKey to prevent 4:4:4 Predictive profile
            // Use bitrate control only for X.com compatibility
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: resolution.width,
                AVVideoHeightKey: resolution.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: baseBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]

            print("ScreenRecorder: Video settings - \(Int(resolution.width))x\(Int(resolution.height)) @ \(baseBitrate / 1_000_000)Mbps")

            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            if let writer = assetWriter, let input = assetWriterInput, writer.canAdd(input) {
                writer.add(input)
            }

            // Add audio writer input if audio recording is enabled
            if recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]

                audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioWriterInput?.expectsMediaDataInRealTime = true

                if let writer = assetWriter, let audioInput = audioWriterInput, writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    print("ScreenRecorder: Audio writer input added successfully")
                } else {
                    print("ScreenRecorder: Cannot add audio writer input")
                }

                // Add a second audio track for microphone
                // (system audio comes from SCStream, mic audio from AVCaptureSession)
                micWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                micWriterInput?.expectsMediaDataInRealTime = true

                if let writer = assetWriter, let micInput = micWriterInput, writer.canAdd(micInput) {
                    writer.add(micInput)
                    print("ScreenRecorder: Mic writer input added")
                }
            }

            completion(nil)
        } catch {
            completion(error)
        }
    }

    /// Immediately stops writing frames (but doesn't finalize the file).
    /// Called by MainViewController to synchronize stop timing across all recorders.
    func stopWriting() {
        streamOutput?.writingEnabled = false
    }

    func stopRecording(completion: ((URL?) -> Void)? = nil) {
        isRecording = false
        onFirstFrameReady = nil
        streamOutput?.writingEnabled = false

        // Stop microphone capture session first (synchronous)
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micAudioDataOutput = nil

        if let stream = stream {
            self.stream = nil

            // Wait for stream to fully stop BEFORE finalizing the writer.
            // This prevents pending frames from arriving after markAsFinished().
            Task {
                do {
                    try await stream.stopCapture()
                    print("ScreenRecorder: Stream stopped")
                } catch {
                    print("ScreenRecorder: Error stopping stream: \(error)")
                }

                self.streamOutput = nil
                self.finalizeAssetWriter(completion: completion)
            }
        } else {
            finalizeAssetWriter(completion: completion)
        }

        print("ScreenRecorder: Recording stopped")
    }

    private func finalizeAssetWriter(completion: ((URL?) -> Void)?) {
        guard let writer = assetWriter else {
            print("ScreenRecorder: ERROR - No asset writer to finalize")
            completion?(nil)
            return
        }

        // If writer was never started (no frames received), cancel and return URL
        if writer.status == .unknown {
            print("ScreenRecorder: WARNING - Asset writer was never started (no frames captured)")
            writer.cancelWriting()
            if let url = tempRecordingURL {
                recordedVideoURL = url
                completion?(url)
            } else {
                completion?(nil)
            }
            return
        }

        assetWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        micWriterInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self = self else {
                completion?(nil)
                return
            }

            if let outputURL = self.tempRecordingURL {
                self.recordedVideoURL = outputURL

                if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                   let fileSize = attributes[.size] as? UInt64 {
                    print("ScreenRecorder: Recording saved to: \(outputURL.path)")
                    print("ScreenRecorder: File size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000.0) MB)")
                } else {
                    print("ScreenRecorder: Recording saved to: \(outputURL.path) (size unknown)")
                }

                print("ScreenRecorder: Calling completion handler with URL: \(outputURL.path)")
                completion?(outputURL)
            } else {
                print("ScreenRecorder: ERROR - No temp recording URL available")
                completion?(nil)
            }

            if let error = writer.error {
                print("ScreenRecorder: AssetWriter error: \(error.localizedDescription)")
            }
        }
    }

    func pause() {
        guard isRecording && !isPaused else { return }

        isPaused = true
        print("ScreenRecorder: Recording paused")

        if let stream = stream {
            Task {
                do {
                    try await stream.stopCapture()
                    print("ScreenRecorder: Stream paused")
                } catch {
                    print("ScreenRecorder: Error pausing stream: \(error)")
                }
            }
        }
    }

    func resume() {
        guard isRecording && isPaused else { return }

        isPaused = false
        print("ScreenRecorder: Recording resumed")

        if let stream = stream {
            Task {
                do {
                    try await stream.startCapture()
                    print("ScreenRecorder: Stream resumed")
                } catch {
                    print("ScreenRecorder: Error resuming stream: \(error)")
                }
            }
        }
    }

    func exportWithZoom(
        clickEvents: [ClickEventNew],
        cursorPositions: [CursorPositionNew]? = nil,
        trackingMode: TrackingMode,
        to outputURL: URL,
        startTime: Date,
        subtitles: [SubtitleEntryApple]? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard let inputURL = recordedVideoURL else {
            completion(NSError(domain: "ScreenRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "No recorded video available"]))
            return
        }

        // Process video with zoom effects and subtitles
        let processor = VideoProcessor()
        processor.processVideo(
            inputURL: inputURL,
            outputURL: outputURL,
            clickEvents: clickEvents,
            cursorPositions: cursorPositions,
            trackingMode: trackingMode,
            recordingStartTime: startTime,
            subtitles: subtitles,
            progress: progress,
            completion: completion
        )
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (microphone capture)
extension ScreenRecorderNew: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }

        // Route microphone audio through StreamOutput which has timing reference from SCStream
        if output == micAudioDataOutput {
            streamOutput?.appendMicrophoneAudio(sampleBuffer)
        }
    }
}

// MARK: - ScreenCaptureKit Stream Output
class StreamOutput: NSObject, SCStreamOutput {
    private weak var assetWriter: AVAssetWriter?
    private weak var assetWriterInput: AVAssetWriterInput?
    private weak var audioWriterInput: AVAssetWriterInput?
    private weak var micWriterInput: AVAssetWriterInput?
    private var onFrameCaptured: ((Date) -> Void)?
    private var firstSampleTime: CMTime?
    private var firstAudioSampleTime: CMTime?
    private(set) var totalFrameCount: Int = 0
    private var audioSampleCount: Int = 0
    private var skippedAudioSampleCount: Int = 0

    // Writing gate — frames are discarded until this is set to true
    var writingEnabled = false
    private var hasSignaledReady = false
    var onFirstFrameReady: (() -> Void)?

    // Thread-safe mute flag - can be toggled during recording
    private let muteLock = NSLock()
    private var _isAudioMuted: Bool = false
    var isAudioMuted: Bool {
        get {
            muteLock.lock()
            defer { muteLock.unlock() }
            return _isAudioMuted
        }
        set {
            muteLock.lock()
            _isAudioMuted = newValue
            muteLock.unlock()
            print("StreamOutput: isAudioMuted set to \(newValue)")
        }
    }

    init(assetWriter: AVAssetWriter?, assetWriterInput: AVAssetWriterInput?, audioWriterInput: AVAssetWriterInput?, micWriterInput: AVAssetWriterInput? = nil, onFrameCaptured: ((Date) -> Void)?) {
        self.assetWriter = assetWriter
        self.assetWriterInput = assetWriterInput
        self.audioWriterInput = audioWriterInput
        self.micWriterInput = micWriterInput
        self.onFrameCaptured = onFrameCaptured
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let assetWriter = assetWriter else {
            return
        }

        // Don't append if writer is no longer in a writable state
        guard assetWriter.status == .unknown || assetWriter.status == .writing else {
            return
        }

        if type == .screen {
            // Handle video
            guard let assetWriterInput = assetWriterInput else {
                return
            }

            // SCStream can deliver status-change sample buffers without pixel data.
            // These must be skipped — appending them crashes the asset writer.
            guard CMSampleBufferDataIsReady(sampleBuffer),
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                return
            }

            // Signal ready on first valid screen frame (even if writing is gated)
            if !hasSignaledReady {
                hasSignaledReady = true
                let callback = onFirstFrameReady
                onFirstFrameReady = nil
                DispatchQueue.main.async { callback?() }
            }

            // Don't write until MainViewController enables writing (synchronized start)
            guard writingEnabled else { return }

            // Start writer on first writable sample
            if assetWriter.status == .unknown {
                let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: .zero)
                firstSampleTime = startTime
                print("StreamOutput: Started writing at time 0s (normalized from \(CMTimeGetSeconds(startTime))s)")
            }

            // Adjust timestamp to be relative to first frame
            guard let firstSampleTime = firstSampleTime else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let adjustedTime = CMTimeSubtract(presentationTime, firstSampleTime)
            let adjustedBuffer = adjustSampleBufferTiming(sampleBuffer, newPresentationTime: adjustedTime)

            // Write sample if ready
            if assetWriterInput.isReadyForMoreMediaData {
                let success = assetWriterInput.append(adjustedBuffer ?? sampleBuffer)
                if success {
                    totalFrameCount += 1
                    if totalFrameCount <= 5 || totalFrameCount % 60 == 0 {
                        print("StreamOutput: Frame \(totalFrameCount) written")
                    }
                } else {
                    print("StreamOutput: Failed to append frame \(totalFrameCount)")
                }

                // Notify frame captured
                onFrameCaptured?(Date())
            }
        } else if type == .audio {
            guard writingEnabled else { return }
            guard let audioWriterInput = audioWriterInput else {
                return
            }

            // Only write audio after video session has started
            if let firstSampleTime = firstSampleTime, audioWriterInput.isReadyForMoreMediaData {
                // Adjust timestamp to be relative to first frame
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let adjustedTime = CMTimeSubtract(presentationTime, firstSampleTime)

                // Skip audio samples that arrived before the first video frame
                guard adjustedTime >= .zero else { return }

                let adjustedBuffer = adjustSampleBufferTiming(sampleBuffer, newPresentationTime: adjustedTime)

                // Handle audio - write silence if muted, otherwise write actual audio
                if isAudioMuted {
                    skippedAudioSampleCount += 1
                    if skippedAudioSampleCount == 1 || skippedAudioSampleCount % 50 == 0 {
                        print("StreamOutput: Audio muted - writing silence for sample \(skippedAudioSampleCount)")
                    }
                    if let silentBuffer = createSilentAudioBuffer(from: adjustedBuffer ?? sampleBuffer) {
                        audioWriterInput.append(silentBuffer)
                    }
                    return
                }

                let success = audioWriterInput.append(adjustedBuffer ?? sampleBuffer)
                if success {
                    audioSampleCount += 1
                    if audioSampleCount <= 5 {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        if firstAudioSampleTime == nil {
                            firstAudioSampleTime = presentationTime
                            print("StreamOutput: First audio sample at PTS: \(CMTimeGetSeconds(presentationTime))s")
                        }
                        print("StreamOutput: Audio sample \(audioSampleCount) written")
                    }
                } else {
                    print("StreamOutput: Failed to append audio sample \(audioSampleCount)")
                }
            }
        }
    }

    /// Accepts microphone audio samples from a separate AVCaptureSession.
    /// Uses the same timing reference as SCStream video for correct sync.
    /// Writes to a dedicated mic audio track (separate from system audio).
    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let micInput = micWriterInput else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }
        guard let firstSampleTime = firstSampleTime else { return }
        guard micInput.isReadyForMoreMediaData else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(presentationTime, firstSampleTime)
        guard adjustedTime >= .zero else { return }
        let adjustedBuffer = adjustSampleBufferTiming(sampleBuffer, newPresentationTime: adjustedTime)

        if isAudioMuted {
            if let silentBuffer = createSilentAudioBuffer(from: adjustedBuffer ?? sampleBuffer) {
                micInput.append(silentBuffer)
            }
            return
        }

        let success = micInput.append(adjustedBuffer ?? sampleBuffer)
        if success {
            audioSampleCount += 1
            if audioSampleCount <= 3 {
                print("StreamOutput: Mic audio sample \(audioSampleCount) at PTS: \(CMTimeGetSeconds(adjustedTime))s")
            }
        }
    }

    // Helper to adjust sample buffer presentation time
    private func adjustSampleBufferTiming(_ sampleBuffer: CMSampleBuffer, newPresentationTime: CMTime) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = newPresentationTime
        timingInfo.decodeTimeStamp = .invalid
        timingInfo.duration = CMSampleBufferGetDuration(sampleBuffer)

        var adjustedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )

        return adjustedBuffer
    }

    // Create a silent audio buffer with the same format and timing as the input
    private func createSilentAudioBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        // Get the audio stream basic description
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        // Calculate buffer size
        let bytesPerSample = Int(asbd.mBytesPerFrame)
        let bufferSize = numSamples * bytesPerSample

        // Create a buffer filled with zeros (silence)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bufferSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bufferSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer = blockBuffer else { return nil }

        // Fill with silence (zeros)
        status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bufferSize)
        guard status == noErr else { return nil }

        // Get timing info from original buffer
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

        // Create the silent sample buffer
        var silentBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: numSamples,
            presentationTimeStamp: timingInfo.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &silentBuffer
        )

        if status != noErr {
            // Fallback: try creating with simpler method
            var sampleSizeArray = [Int](repeating: bytesPerSample, count: numSamples)
            status = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: numSamples,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: numSamples,
                sampleSizeArray: &sampleSizeArray,
                sampleBufferOut: &silentBuffer
            )
        }

        return status == noErr ? silentBuffer : nil
    }
}
