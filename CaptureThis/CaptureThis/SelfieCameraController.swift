import Cocoa
import AVFoundation
import Vision
import CoreImage

enum VirtualBackgroundMode: Int, Codable {
    case none = 0
    case blurLight = 1
    case blurMedium = 2
    case blurStrong = 3
    case solidColor = 4
    case customImage = 5
}

struct VirtualBackgroundSettings: Codable {
    var mode: VirtualBackgroundMode = .none
    var colorHex: String? = nil
    var imageBookmark: Data? = nil
    var bundledImageIndex: Int? = nil
}

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
        static let virtualBackground = "selfieVirtualBackground"
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

    // Virtual background
    private(set) var backgroundSettings = VirtualBackgroundSettings()
    private var segmentationRequest: VNGeneratePersonSegmentationRequest?
    private var sequenceHandler: VNSequenceRequestHandler?
    private var backgroundCIImage: CIImage?
    private var ciContext: CIContext?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

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
        restoreBackgroundSettings()
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

    // MARK: - Virtual Background

    func setVirtualBackground(_ mode: VirtualBackgroundMode, colorHex: String? = nil, imageBookmark: Data? = nil, bundledImageIndex: Int? = nil) {
        backgroundSettings.mode = mode
        backgroundSettings.colorHex = colorHex
        backgroundSettings.imageBookmark = bundledImageIndex != nil ? nil : imageBookmark
        backgroundSettings.bundledImageIndex = imageBookmark != nil ? nil : bundledImageIndex

        // Persist
        if let data = try? JSONEncoder().encode(backgroundSettings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.virtualBackground)
        }

        if mode != .none {
            setupVisionResources()
            if mode == .customImage {
                if let index = bundledImageIndex,
                   index >= 0, index < BundledBackgroundGenerator.backgrounds.count {
                    let bg = BundledBackgroundGenerator.backgrounds[index]
                    backgroundCIImage = bg.makeCIImage(CGSize(width: 1920, height: 1080))
                } else if let bookmark = imageBookmark {
                    backgroundCIImage = loadBackgroundImage(from: bookmark)
                }
            }
        } else {
            teardownVisionResources()
        }

        // Switch preview mode
        DispatchQueue.main.async { [weak self] in
            self?.updatePreviewMode()
        }
    }

    private func restoreBackgroundSettings() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.virtualBackground),
              let settings = try? JSONDecoder().decode(VirtualBackgroundSettings.self, from: data) else { return }
        backgroundSettings = settings
        if settings.mode != .none {
            setupVisionResources()
            if settings.mode == .customImage {
                if let index = settings.bundledImageIndex,
                   index >= 0, index < BundledBackgroundGenerator.backgrounds.count {
                    let bg = BundledBackgroundGenerator.backgrounds[index]
                    backgroundCIImage = bg.makeCIImage(CGSize(width: 1920, height: 1080))
                } else if let bookmark = settings.imageBookmark {
                    backgroundCIImage = loadBackgroundImage(from: bookmark)
                }
            }
        }
    }

    private func setupVisionResources() {
        if segmentationRequest == nil {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segmentationRequest = request
        }
        if sequenceHandler == nil {
            sequenceHandler = VNSequenceRequestHandler()
        }
        if ciContext == nil {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    private func teardownVisionResources() {
        segmentationRequest = nil
        sequenceHandler = nil
        backgroundCIImage = nil
        pixelBufferPool = nil
    }

    private func updatePreviewMode() {
        guard let view = previewView else { return }
        if backgroundSettings.mode != .none {
            // Switch to CGImage-based display
            view.setUseCustomDisplay(true)
            if let previewLayer = view.previewLayer {
                previewLayer.session = nil
            }
        } else {
            // Switch back to preview layer
            view.setUseCustomDisplay(false)
            if captureSession.isRunning {
                view.previewLayer?.session = captureSession
                applyMirrorSetting()
            }
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
            self.pixelBufferAdaptor = nil
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

        updatePreviewMode()
        applyMirrorSetting()
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

    // MARK: - Frame Processing

    private func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard backgroundSettings.mode != .none else { return nil }
        guard let request = segmentationRequest, let handler = sequenceHandler else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Run person segmentation
        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            return nil
        }

        guard let maskPixelBuffer = request.results?.first?.pixelBuffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

        // Scale mask to match frame size
        let maskWidth = CVPixelBufferGetWidth(maskPixelBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskPixelBuffer)
        let scaleX = CGFloat(width) / CGFloat(maskWidth)
        let scaleY = CGFloat(height) / CGFloat(maskHeight)
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Create background based on mode
        let background: CIImage
        switch backgroundSettings.mode {
        case .none:
            return nil
        case .blurLight:
            background = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: ciImage.extent)
        case .blurMedium:
            background = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 20).cropped(to: ciImage.extent)
        case .blurStrong:
            background = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: ciImage.extent)
        case .solidColor:
            let hex = backgroundSettings.colorHex ?? "007AFF"
            let ciColor = CIColor(hexString: hex)
            background = CIImage(color: ciColor).cropped(to: ciImage.extent)
        case .customImage:
            if let bgImage = backgroundCIImage {
                // Scale custom image to fill frame
                let bgScaleX = CGFloat(width) / bgImage.extent.width
                let bgScaleY = CGFloat(height) / bgImage.extent.height
                let bgScale = max(bgScaleX, bgScaleY)
                let scaled = bgImage.transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
                // Center crop
                let offsetX = (scaled.extent.width - CGFloat(width)) / 2
                let offsetY = (scaled.extent.height - CGFloat(height)) / 2
                background = scaled.cropped(to: CGRect(x: scaled.extent.origin.x + offsetX,
                                                        y: scaled.extent.origin.y + offsetY,
                                                        width: CGFloat(width),
                                                        height: CGFloat(height)))
                    .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            } else {
                background = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 20).cropped(to: ciImage.extent)
            }
        }

        // Composite: person over background using mask
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blendFilter.setValue(background, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let outputImage = blendFilter.outputImage else { return nil }
        guard let ctx = ciContext else { return nil }

        // Get or create pixel buffer pool
        let outputBuffer = createPixelBuffer(width: width, height: height)
        guard let resultBuffer = outputBuffer else { return nil }

        ctx.render(outputImage, to: resultBuffer)
        return resultBuffer
    }

    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        // Reuse pool if dimensions match
        if let pool = pixelBufferPool {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            if status == kCVReturnSuccess, let buf = buffer {
                return buf
            }
        }

        // Create new pool
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &pool)
        pixelBufferPool = pool

        guard let newPool = pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, newPool, &buffer)
        return buffer
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

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Process frame through virtual background pipeline if active
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let isVirtualBG = backgroundSettings.mode != .none
        let processedBuffer: CVPixelBuffer? = isVirtualBG ? processFrame(sourceBuffer) : nil
        let displayBuffer = processedBuffer ?? sourceBuffer

        // Update preview with processed frame (only when using virtual background)
        if isVirtualBG, let ctx = ciContext {
            let ciImg = CIImage(cvPixelBuffer: displayBuffer)
            if let cgImg = ctx.createCGImage(ciImg, from: ciImg.extent) {
                DispatchQueue.main.async { [weak self] in
                    self?.previewView?.updateFrame(cgImg)
                }
            }
        }

        // Recording logic
        guard isRecording, isWritingEnabled else { return }
        guard let writer = selfieWriter else { return }

        // Pause handling
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

        // Initialize writer input on first writable frame
        if selfieWriterInput == nil {
            let width = CVPixelBufferGetWidth(displayBuffer)
            let height = CVPixelBufferGetHeight(displayBuffer)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let adaptorAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: adaptorAttributes
            )

            guard writer.canAdd(input) else {
                print("SelfieCameraController: Cannot add writer input")
                return
            }
            writer.add(input)
            selfieWriterInput = input
            pixelBufferAdaptor = adaptor
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

        // Normalize timestamp
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(CMTimeSubtract(pts, firstTime), totalPausedDuration)

        if isVirtualBG, let adaptor = pixelBufferAdaptor {
            // Use pixel buffer adaptor for processed frames
            adaptor.append(displayBuffer, withPresentationTime: adjustedTime)
        } else {
            // Use sample buffer for unprocessed frames
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
    private var displayLayer: CALayer?
    private var useCustomDisplay = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspectFill
        previewLayer = preview
        self.layer?.addSublayer(preview)

        let display = CALayer()
        display.contentsGravity = .resizeAspectFill
        display.isHidden = true
        displayLayer = display
        self.layer?.addSublayer(display)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUseCustomDisplay(_ custom: Bool) {
        useCustomDisplay = custom
        previewLayer?.isHidden = custom
        displayLayer?.isHidden = !custom
    }

    func updateFrame(_ cgImage: CGImage) {
        displayLayer?.contents = cgImage
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        displayLayer?.frame = bounds
    }
}

// MARK: - Color Hex Helpers

extension NSColor {
    func toHex() -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        if hex.count == 6 {
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        } else {
            (r, g, b) = (0, 0, 0)
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension CIColor {
    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        if hex.count == 6 {
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        } else {
            (r, g, b) = (0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255)
    }
}

// MARK: - Security-Scoped Bookmark Helpers

extension SelfieCameraController {
    func loadBackgroundImage(from bookmark: Data) -> CIImage? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return CIImage(contentsOf: url)
    }
}
