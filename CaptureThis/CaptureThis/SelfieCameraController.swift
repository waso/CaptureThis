import Cocoa
import AVFoundation

struct SelfieOverlayEvent: Codable {
    let time: TimeInterval
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

final class SelfieCameraController: NSObject {
    private enum DefaultsKey {
        static let windowFrame = "selfieWindowFrame"
        static let enabled = "selfieEnabled"
        static let selectedCameraID = "selfieCameraID"
        static let mirrored = "selfieMirrored"
    }

    private let captureSession = AVCaptureSession()
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var previewWindow: NSWindow?
    private var previewView: SelfiePreviewView?

    private(set) var isEnabled: Bool = false
    private(set) var isMirrored: Bool = true
    private var isRecording = false
    private(set) var isPaused = false
    private var pauseStartTime: CMTime?
    private var totalPausedDuration: CMTime = .zero

    // Selected camera device (nil = default front camera)
    var selectedCameraDevice: AVCaptureDevice?

    private var screenRecordingStartTime: Date?
    private var recordingBounds: CGRect = .zero

    private(set) var overlayEvents: [SelfieOverlayEvent] = []
    private(set) var recordingURL: URL?

    /// The CGWindowID of the selfie preview window (for excluding from screen capture).
    var selfieWindowID: CGWindowID? {
        guard let window = previewWindow else { return nil }
        return CGWindowID(window.windowNumber)
    }

    // Recording infrastructure (AVAssetWriter for frame-level timing control)
    private var selfieWriter: AVAssetWriter?
    private var selfieWriterInput: AVAssetWriterInput?
    private var selfieFirstSampleTime: CMTime?
    private var isWritingEnabled = false
    private var hasSignaledReady = false
    private var onReadyCallback: (() -> Void)?
    private var stopRecordingCompletion: ((URL?, [SelfieOverlayEvent], TimeInterval) -> Void)?
    private let writerQueue = DispatchQueue(label: "com.capturethis.selfie.writer")

    override init() {
        super.init()
        restoreSelectedCamera()
        restoreMirrorSetting()
    }

    func setMirrored(_ mirrored: Bool) {
        isMirrored = mirrored
        UserDefaults.standard.set(mirrored, forKey: DefaultsKey.mirrored)
        applyMirrorSetting()
    }

    private func restoreMirrorSetting() {
        // Default to true (mirrored) if not set
        if UserDefaults.standard.object(forKey: DefaultsKey.mirrored) == nil {
            isMirrored = true
        } else {
            isMirrored = UserDefaults.standard.bool(forKey: DefaultsKey.mirrored)
        }
    }

    private func applyMirrorSetting() {
        // Apply to preview layer
        if let previewLayer = previewView?.previewLayer,
           let connection = previewLayer.connection,
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
        // Apply to recording output
        if let connection = videoDataOutput?.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }

    /// Returns all available video capture devices (cameras)
    static func availableCameraDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    func setSelectedCamera(_ device: AVCaptureDevice?) {
        selectedCameraDevice = device
        // Save selection
        if let device = device {
            UserDefaults.standard.set(device.uniqueID, forKey: DefaultsKey.selectedCameraID)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.selectedCameraID)
        }
        // Reconfigure capture session with new camera (only if authorized)
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            setupCaptureSession()
            if isEnabled && !isRecording {
                startPreview()
            }
        }
    }

    private func restoreSelectedCamera() {
        guard let savedID = UserDefaults.standard.string(forKey: DefaultsKey.selectedCameraID) else { return }
        let devices = SelfieCameraController.availableCameraDevices()
        selectedCameraDevice = devices.first { $0.uniqueID == savedID }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.enabled)

        if enabled {
            showPreviewWindow()
            ensureCameraAccessAndStartPreview()
        } else {
            stopRecordingIfNeeded()
            stopPreview()
            hidePreviewWindow()
        }
    }

    func restoreEnabledState() -> Bool {
        return UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    func startRecording(recordingStartTime: Date, recordingBounds: CGRect, onReady: (() -> Void)? = nil) {
        guard isEnabled else {
            onReady?()
            return
        }
        guard !isRecording else {
            onReady?()
            return
        }

        self.recordingBounds = recordingBounds
        screenRecordingStartTime = recordingStartTime
        overlayEvents.removeAll()
        isWritingEnabled = false
        hasSignaledReady = false
        selfieFirstSampleTime = nil
        isPaused = false
        pauseStartTime = nil
        totalPausedDuration = .zero
        selfieWriterInput = nil
        onReadyCallback = onReady

        showPreviewWindow()
        ensureCameraAccessAndStartPreview()

        recordOverlayEvent(at: recordingStartTime)

        let tempDir = FileManager.default.temporaryDirectory
        let uniqueID = UUID().uuidString.prefix(8)
        let outputURL = tempDir.appendingPathComponent("selfie-temp-\(Date().timeIntervalSince1970)-\(uniqueID).mp4")
        recordingURL = outputURL

        applyMirrorSetting()

        // Create AVAssetWriter (inputs added lazily on first written frame)
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            selfieWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            print("SelfieCameraController: Failed to create asset writer: \(error)")
        }

        isRecording = true

        // If no onReady callback (standalone mode), start writing immediately
        if onReady == nil {
            isWritingEnabled = true
        }
    }

    /// Called by MainViewController when all streams are ready — starts writing frames to disk.
    func beginWriting() {
        isWritingEnabled = true
        print("SelfieCameraController: Writing enabled")
    }

    func pause() {
        isPaused = true
        print("SelfieCameraController: Paused")
    }

    func resume() {
        isPaused = false
        print("SelfieCameraController: Resumed")
    }

    func stopRecording(completion: @escaping (URL?, [SelfieOverlayEvent], TimeInterval) -> Void) {
        guard isRecording else {
            completion(recordingURL, overlayEvents, 0)
            return
        }

        isRecording = false
        isWritingEnabled = false

        writerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil, [], 0) }
                return
            }

            guard let writer = self.selfieWriter else {
                let url = self.recordingURL
                let events = self.overlayEvents
                DispatchQueue.main.async { completion(url, events, 0) }
                return
            }

            if writer.status == .writing {
                self.selfieWriterInput?.markAsFinished()
                writer.finishWriting {
                    let url = self.recordingURL
                    let events = self.overlayEvents
                    if let error = writer.error {
                        print("SelfieCameraController: Writer error: \(error.localizedDescription)")
                    }
                    print("SelfieCameraController: Recording finished to \(url?.path ?? "nil")")
                    DispatchQueue.main.async { completion(url, events, 0) }
                }
            } else {
                if writer.status == .unknown {
                    writer.cancelWriting()
                }
                let url = self.recordingURL
                let events = self.overlayEvents
                print("SelfieCameraController: Writer was in status \(writer.status.rawValue), returning URL")
                DispatchQueue.main.async { completion(url, events, 0) }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.stopPreview()
        }
    }

    private func stopRecordingIfNeeded() {
        guard isRecording else { return }
        isRecording = false
        isWritingEnabled = false
        writerQueue.async { [weak self] in
            guard let self = self, let writer = self.selfieWriter else { return }
            if writer.status == .writing {
                self.selfieWriterInput?.markAsFinished()
                writer.finishWriting {}
            } else if writer.status == .unknown {
                writer.cancelWriting()
            }
            self.selfieWriter = nil
            self.selfieWriterInput = nil
        }
    }

    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        if let existingInputs = captureSession.inputs as? [AVCaptureInput] {
            for input in existingInputs {
                captureSession.removeInput(input)
            }
        }

        // Use selected camera device or fall back to default front camera
        let device: AVCaptureDevice?
        if let selected = selectedCameraDevice {
            device = selected
            print("SelfieCameraController: Using selected camera: \(selected.localizedName)")
        } else {
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }

        guard let cameraDevice = device else {
            print("SelfieCameraController: No camera available")
            captureSession.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: cameraDevice)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {
            print("SelfieCameraController: Failed to create camera input: \(error)")
        }

        // Add video data output (only once — persists across camera changes)
        if videoDataOutput == nil {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: writerQueue)
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            videoDataOutput = output
        }

        captureSession.commitConfiguration()
    }

    private func ensureCameraAccessAndStartPreview() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("SelfieCameraController: Camera authorization status: \(status.rawValue)")

        switch status {
        case .authorized:
            print("SelfieCameraController: Camera already authorized")
            setupCaptureSession()
            startPreview()
        case .notDetermined:
            print("SelfieCameraController: Requesting camera access...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("SelfieCameraController: Camera access response: \(granted)")
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.setupCaptureSession()
                        self.startPreview()
                    } else {
                        self.showCameraAccessAlert()
                    }
                }
            }
        case .denied, .restricted:
            print("SelfieCameraController: Camera access denied/restricted, requesting anyway to register app...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.setupCaptureSession()
                        self.startPreview()
                    } else {
                        self.showCameraAccessAlert()
                    }
                }
            }
        @unknown default:
            showCameraAccessAlert()
        }
    }

    private func startPreview() {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()

        if let previewLayer = previewView?.previewLayer {
            previewLayer.session = captureSession
            applyMirrorSetting()
        }
    }

    private func stopPreview() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        if let previewLayer = previewView?.previewLayer {
            previewLayer.session = nil
        }
    }

    private func showCameraAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "Allow camera access for CaptureThis in System Settings > Privacy & Security > Camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showPreviewWindow() {
        if previewWindow == nil {
            createPreviewWindow()
        }
        previewWindow?.makeKeyAndOrderFront(nil)
    }

    private func hidePreviewWindow() {
        previewWindow?.orderOut(nil)
    }

    func closePreviewWindow() {
        hidePreviewWindow()
    }

    private func createPreviewWindow() {
        let defaultFrame = NSRect(x: 100, y: 100, width: 240, height: 180)
        let storedFrameString = UserDefaults.standard.string(forKey: DefaultsKey.windowFrame)
        let storedFrame = storedFrameString.flatMap { NSRectFromString($0) }
        let frame = storedFrame?.isEmpty == false ? storedFrame! : defaultFrame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Selfie"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 80, height: 60)
        window.delegate = self
        window.sharingType = .none

        let view = SelfiePreviewView(frame: window.contentView?.bounds ?? frame)
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        previewWindow = window
        previewView = view
    }

    private func recordOverlayEvent(at time: Date) {
        guard let screenStart = screenRecordingStartTime else { return }
        guard let window = previewWindow else { return }
        guard recordingBounds.width > 0, recordingBounds.height > 0 else { return }

        let elapsed = time.timeIntervalSince(screenStart)
        let windowFrame = window.frame

        let relativeX = (windowFrame.origin.x - recordingBounds.origin.x) / recordingBounds.width
        let relativeY = (windowFrame.origin.y - recordingBounds.origin.y) / recordingBounds.height
        let relativeWidth = windowFrame.width / recordingBounds.width
        let relativeHeight = windowFrame.height / recordingBounds.height

        let clampedX = max(0, min(1, relativeX))
        let clampedY = max(0, min(1, relativeY))
        let clampedWidth = max(0.02, min(1, relativeWidth))
        let clampedHeight = max(0.02, min(1, relativeHeight))

        let event = SelfieOverlayEvent(
            time: elapsed,
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )

        overlayEvents.append(event)
    }

    private func saveWindowFrame() {
        guard let window = previewWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: DefaultsKey.windowFrame)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension SelfieCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Signal ready on first camera frame (even before writing is enabled)
        if !hasSignaledReady {
            hasSignaledReady = true
            let callback = onReadyCallback
            onReadyCallback = nil
            DispatchQueue.main.async { callback?() }
        }

        guard isRecording, isWritingEnabled else { return }
        guard let writer = selfieWriter else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Pause handling — skip frames during pause, adjust timestamps on resume
        if isPaused {
            if pauseStartTime == nil, selfieFirstSampleTime != nil {
                pauseStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            }
            return
        }
        if let pauseStart = pauseStartTime {
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pauseDuration = CMTimeSubtract(rawPTS, pauseStart)
            totalPausedDuration = CMTimeAdd(totalPausedDuration, pauseDuration)
            pauseStartTime = nil
            print("SelfieCameraController: Pause ended. Gap: \(CMTimeGetSeconds(pauseDuration))s, Total paused: \(CMTimeGetSeconds(totalPausedDuration))s")
        }

        // Initialize writer input on first writable frame (needs format info from the sample)
        if selfieWriterInput == nil {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                print("SelfieCameraController: Cannot add writer input")
                return
            }
            writer.add(input)
            selfieWriterInput = input
        }

        // Start writer on first frame
        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            selfieFirstSampleTime = startTime
            print("SelfieCameraController: Writer started")
        }

        guard writer.status == .writing else { return }
        guard let firstTime = selfieFirstSampleTime else { return }
        guard let writerInput = selfieWriterInput, writerInput.isReadyForMoreMediaData else { return }

        // Normalize timestamp to 0-based, minus paused duration
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(CMTimeSubtract(pts, firstTime), totalPausedDuration)

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: adjustedTime,
            decodeTimeStamp: .invalid
        )
        var adjustedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )

        if let buf = adjustedBuffer {
            writerInput.append(buf)
        }
    }
}

extension SelfieCameraController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
        if isRecording {
            recordOverlayEvent(at: Date())
        }
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
        applyMirrorSetting()
        if isRecording {
            recordOverlayEvent(at: Date())
        }
    }
}

final class SelfiePreviewView: NSView {
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        self.layer?.addSublayer(layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
