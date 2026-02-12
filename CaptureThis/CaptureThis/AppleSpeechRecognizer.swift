import Foundation
import AVFoundation
import Speech

// Subtitle data structure to store timestamp and text
struct SubtitleEntryApple: Codable {
    let timestamp: TimeInterval  // Relative to recording start
    let text: String
    let duration: TimeInterval  // How long to display
}

// Protocol for receiving speech recognition results
protocol AppleSpeechRecognizerDelegate: AnyObject {
    func didReceiveTranscript(_ text: String, isFinal: Bool)
    func didEncounterError(_ error: Error)
}

@MainActor
class AppleSpeechRecognizer: NSObject {
    weak var delegate: AppleSpeechRecognizerDelegate?

    private var audioEngine = AVAudioEngine()
    private var isRecording = false

    // Speech recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // For storing subtitles
    private var subtitleEntries: [SubtitleEntryApple] = []
    private var recordingStartTime: Date?

    // Current transcript buffer
    private var currentTranscript = ""
    private var currentTranscriptTime: TimeInterval = 0  // When current transcript was last updated
    private var lastSentenceEnd = ""  // Track where last sentence ended
    private var currentSentence = ""   // Current sentence being built
    private var lastSavedTranscript = ""  // Last transcript we saved to avoid duplicates
    private var lastSavedTime: TimeInterval = 0  // When we last saved a subtitle

    override init() {
        super.init()
        print("AppleSpeechRecognizer: Initialized")
    }

    // MARK: - Public API

    func startRecognition(recordingStartTime: Date) {
        guard !isRecording else { return }

        self.recordingStartTime = recordingStartTime
        self.subtitleEntries.removeAll()
        self.currentTranscript = ""
        self.lastSavedTranscript = ""
        self.lastSavedTime = 0

        Task {
            await startTranscriptionAsync()
        }
    }

    func stopRecognition() {
        guard isRecording else { return }

        print("AppleSpeechRecognizer: Stopping recognition...")
        isRecording = false

        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Stop recognition
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Save final transcript if any, using the timestamp when it was received
        if !currentTranscript.isEmpty {
            saveSubtitle(currentTranscript, timestamp: currentTranscriptTime)
        }

        print("AppleSpeechRecognizer: Recognition stopped, total subtitles: \(subtitleEntries.count)")
    }

    func getSubtitles() -> [SubtitleEntryApple] {
        return subtitleEntries
    }

    // MARK: - Private Implementation

    private func startTranscriptionAsync() async {
        // Request speech recognition authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            let error = NSError(domain: "AppleSpeechRecognizer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Speech recognition authorization denied"])
            self.delegate?.didEncounterError(error)
            return
        }

        // Request mic permission
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            let error = NSError(domain: "AppleSpeechRecognizer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
            self.delegate?.didEncounterError(error)
            return
        }

        do {
            try startRecognitionWithSpeechFramework()
            print("AppleSpeechRecognizer: Started successfully")
        } catch {
            print("AppleSpeechRecognizer: Error starting: \(error.localizedDescription)")
            self.delegate?.didEncounterError(error)
            isRecording = false
        }
    }

    private func startRecognitionWithSpeechFramework() throws {
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "AppleSpeechRecognizer", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }

        // Configure request for real-time recognition
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false  // Use cloud for better accuracy

        // Setup audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        print("AppleSpeechRecognizer: Input format - Sample rate: \(recordingFormat.sampleRate) Hz, Channels: \(recordingFormat.channelCount)")

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                // Ignore expected errors that occur during normal operation
                let nsError = error as NSError

                // Error 216: Recognition canceled (expected when stopping/restarting)
                // Error 203: No speech detected (not a real error, just informational)
                // Error 1110: Speech recognition request was canceled
                if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 216 || nsError.code == 203 || nsError.code == 1110) {
                    print("AppleSpeechRecognizer: Recognition ended (code \(nsError.code)) - this is normal")
                    return
                }

                // Also check for "No speech detected" in the error message
                if error.localizedDescription.contains("No speech detected") ||
                   error.localizedDescription.contains("was canceled") {
                    print("AppleSpeechRecognizer: \(error.localizedDescription) - this is normal")
                    return
                }

                print("AppleSpeechRecognizer: Recognition error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.delegate?.didEncounterError(error)
                }
                return
            }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                let isFinal = result.isFinal

                print("AppleSpeechRecognizer: Transcript: '\(transcription)' (final: \(isFinal))")

                Task { @MainActor in
                    self.handleTranscriptResponse(transcription, isFinal: isFinal)
                }

                // If final, restart recognition to continue listening
                if isFinal && self.isRecording {
                    Task { @MainActor in
                        self.restartRecognition()
                    }
                }
            }
        }

        print("AppleSpeechRecognizer: Audio engine started")
    }

    private func restartRecognition() {
        guard isRecording else { return }

        // Stop current recognition
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        // Start new recognition
        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }

            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = false

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                if let error = error {
                    // Ignore expected errors that occur during normal operation
                    let nsError = error as NSError

                    // Error 216: Recognition canceled (expected when stopping/restarting)
                    // Error 203: No speech detected (not a real error, just informational)
                    // Error 1110: Speech recognition request was canceled
                    if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 216 || nsError.code == 203 || nsError.code == 1110) {
                        print("AppleSpeechRecognizer: Recognition ended (code \(nsError.code)) during restart - this is normal")
                        return
                    }

                    // Also check for "No speech detected" in the error message
                    if error.localizedDescription.contains("No speech detected") ||
                       error.localizedDescription.contains("was canceled") {
                        print("AppleSpeechRecognizer: \(error.localizedDescription) during restart - this is normal")
                        return
                    }

                    print("AppleSpeechRecognizer: Recognition error: \(error.localizedDescription)")
                    return
                }

                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    let isFinal = result.isFinal

                    Task { @MainActor in
                        self.handleTranscriptResponse(transcription, isFinal: isFinal)
                    }

                    if isFinal && self.isRecording {
                        Task { @MainActor in
                            self.restartRecognition()
                        }
                    }
                }
            }
        } catch {
            print("AppleSpeechRecognizer: Error restarting recognition: \(error.localizedDescription)")
        }
    }

    private func handleTranscriptResponse(_ text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }

        currentTranscript = text

        // Capture the timestamp when this transcript was received
        if let startTime = recordingStartTime {
            currentTranscriptTime = Date().timeIntervalSince(startTime)
        }

        // Extract the smart subtitle to display (last sentence or last ~7 words)
        let displayText = extractSmartSubtitle(from: text)

        delegate?.didReceiveTranscript(displayText, isFinal: isFinal)

        // Save subtitles more aggressively to capture more speech
        let timeSinceLastSave = currentTranscriptTime - lastSavedTime
        let textIsDifferent = text != lastSavedTranscript
        let hasEnoughNewContent = text.count >= lastSavedTranscript.count + 10  // At least 10 new characters

        if isFinal {
            // Always save final transcripts
            saveSubtitle(text, timestamp: currentTranscriptTime)
            currentTranscript = ""
            lastSentenceEnd = text
            currentSentence = ""
        } else if textIsDifferent && (timeSinceLastSave >= 2.0 || hasEnoughNewContent) {
            // Save partial transcripts if enough time has passed or enough new content
            // Only save if it's substantially different from what we last saved
            saveSubtitle(text, timestamp: currentTranscriptTime)
            print("AppleSpeechRecognizer: Saved partial transcript at \(String(format: "%.2f", currentTranscriptTime))s")
        }
    }

    private func extractSmartSubtitle(from fullText: String) -> String {
        // Look for sentence endings (., !, ?)
        let sentenceEndPattern = /[.!?]\s*/

        // Split into sentences
        let sentences = fullText.split(separator: sentenceEndPattern, omittingEmptySubsequences: true)

        if sentences.count > 0 {
            // Get the last sentence (current one being spoken)
            let lastSentence = String(sentences.last ?? "")

            // If sentence is too long (>10 words), show only last 7 words
            let words = lastSentence.split(separator: " ")
            if words.count > 10 {
                let lastWords = words.suffix(7)
                return lastWords.joined(separator: " ")
            }

            return lastSentence
        }

        // No sentence break yet - show last 7 words max
        let words = fullText.split(separator: " ")
        if words.count > 7 {
            let lastWords = words.suffix(7)
            return lastWords.joined(separator: " ")
        }

        return fullText
    }

    private func saveSubtitle(_ text: String, timestamp: TimeInterval) {
        let entry = SubtitleEntryApple(
            timestamp: timestamp,
            text: text,
            duration: 3.0  // Display for 3 seconds
        )

        subtitleEntries.append(entry)
        lastSavedTranscript = text
        lastSavedTime = timestamp
        print("AppleSpeechRecognizer: Saved subtitle at \(String(format: "%.2f", timestamp))s: \(text)")
    }

    // Export subtitles to JSON
    func exportSubtitles(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(subtitleEntries)
        try data.write(to: url)
        print("AppleSpeechRecognizer: Exported \(subtitleEntries.count) subtitles to \(url.path)")
    }
}
