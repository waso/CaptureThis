import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

class ScreenRecorder {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var tempRecordingURL: URL?
    private var resolution: CGSize
    private var recordedVideoURL: URL?
    private var recordingDelegate: MovieRecordingDelegate?

    init(resolution: CGSize) {
        self.resolution = resolution
    }

    static func checkPermission() -> Bool {
        // Check for screen recording permission
        return CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func startRecording(completion: @escaping (Error?) -> Void) {
        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        tempRecordingURL = tempDir.appendingPathComponent("vibe-temp-\(Date().timeIntervalSince1970).mov")

        // Set up capture session
        setupCaptureSession { [weak self] error in
            if let error = error {
                completion(error)
                return
            }

            // Start recording
            self?.startCapture()
            completion(nil)
        }
    }

    private func setupCaptureSession(completion: @escaping (Error?) -> Void) {
        // Always use legacy AVCaptureScreenInput - it's simpler and works well
        setupLegacyCapture(completion: completion)
    }

    @available(macOS 12.3, *)
    private func setupScreenCaptureKit(completion: @escaping (Error?) -> Void) {
        // ScreenCaptureKit implementation would go here
        // For now, we use the legacy method which is simpler and more reliable
        setupLegacyCapture(completion: completion)
    }

    private func setupLegacyCapture(completion: @escaping (Error?) -> Void) {
        captureSession = AVCaptureSession()

        guard let session = captureSession else {
            completion(NSError(domain: "ScreenRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create capture session"]))
            return
        }

        session.beginConfiguration()

        // Get main display
        let displayID = CGMainDisplayID()

        // Create screen input
        guard let input = AVCaptureScreenInput(displayID: displayID) else {
            completion(NSError(domain: "ScreenRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create screen input"]))
            return
        }

        // Configure capture area and resolution
        input.minFrameDuration = CMTime(value: 1, timescale: 30)

        // Scale to desired resolution
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let scaleX = resolution.width / screenSize.width
        let scaleY = resolution.height / screenSize.height
        let scale = min(scaleX, scaleY)
        input.scaleFactor = scale

        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Add movie file output
        videoOutput = AVCaptureMovieFileOutput()

        if let output = videoOutput, session.canAddOutput(output) {
            session.addOutput(output)

            // Configure video settings for high quality
            if let connection = output.connection(with: .video) {
                connection.videoOrientation = .landscapeRight
            }
        }

        session.commitConfiguration()

        completion(nil)
    }

    private func startCapture() {
        guard let session = captureSession, let output = videoOutput, let url = tempRecordingURL else {
            print("ScreenRecorder: Cannot start capture - missing session, output, or URL")
            return
        }

        print("ScreenRecorder: Starting capture session...")
        session.startRunning()

        // Create and retain the delegate
        recordingDelegate = MovieRecordingDelegate { [weak self] outputURL, error in
            // Check if recording was successful despite error code -11806 (normal stop)
            if let error = error as NSError? {
                let wasSuccessful = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                if wasSuccessful {
                    print("ScreenRecorder: Recording completed successfully (with normal stop code -11806)")
                } else {
                    print("ScreenRecorder: Recording failed with error: \(error)")
                    return
                }
            }

            // Save the video URL whether or not there was a "successful stop" error
            if let outputURL = outputURL {
                print("ScreenRecorder: Recording saved to: \(outputURL.path)")
                self?.recordedVideoURL = outputURL

                // Verify file exists
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
                    print("ScreenRecorder: Video file verified, size: \(size) bytes")
                } else {
                    print("ScreenRecorder: WARNING - Video file does not exist!")
                }
            } else {
                print("ScreenRecorder: WARNING - No output URL provided!")
            }
        }

        // Start recording to file
        print("ScreenRecorder: Starting recording to: \(url.path)")
        output.startRecording(to: url, recordingDelegate: recordingDelegate!)
    }

    func stopRecording() {
        print("ScreenRecorder: Stopping recording...")
        videoOutput?.stopRecording()
        captureSession?.stopRunning()
        print("ScreenRecorder: Recording stopped")
    }

    func exportWithZoom(
        clickEvents: [ClickEventNew],
        cursorPositions: [CursorPositionNew]? = nil,
        trackingMode: TrackingMode,
        to outputURL: URL,
        startTime: Date,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        print("ScreenRecorder: Export requested")
        print("ScreenRecorder: recordedVideoURL = \(recordedVideoURL?.path ?? "nil")")

        guard let inputURL = recordedVideoURL else {
            print("ScreenRecorder: ERROR - No recorded video available!")
            completion(NSError(domain: "ScreenRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "No recorded video available"]))
            return
        }

        print("ScreenRecorder: Starting export from: \(inputURL.path)")

        // Process video with zoom effects
        let processor = VideoProcessor()
        processor.processVideo(
            inputURL: inputURL,
            outputURL: outputURL,
            clickEvents: clickEvents,
            cursorPositions: cursorPositions,
            trackingMode: trackingMode,
            recordingStartTime: startTime,
            progress: progress,
            completion: completion
        )
    }
}

// Delegate for movie recording
class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let completion: (URL?, Error?) -> Void

    init(completion: @escaping (URL?, Error?) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        completion(outputFileURL, error)
    }
}
