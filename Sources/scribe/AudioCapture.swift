@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures microphone and/or system audio using ScreenCaptureKit (macOS 15+).
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let captureMic: Bool
    let captureSystem: Bool

    private var stream: SCStream?
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var continuation: CheckedContinuation<Void, any Error>?
    private var sourceSampleRate: Double = 48000
    private var micSampleRate: Double = 48000

    init(captureMic: Bool = true, captureSystem: Bool = true) {
        self.captureMic = captureMic
        self.captureSystem = captureSystem
        super.init()
    }

    // MARK: - Public API

    /// Start capturing audio. Suspends until stopCapture() is called.
    func startCapture() async throws {
        Log.info("Starting audio capture (mic: \(captureMic), system: \(captureSystem))")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            handlePermissionError(error)
            throw error
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        Log.debug("Using display: \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = captureSystem
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.captureMicrophone = captureMic

        // System audio sample rate (mic uses device native rate, read from CMSampleBuffer)
        config.sampleRate = 48000
        sourceSampleRate = 48000
        Log.debug("System audio sample rate: \(sourceSampleRate) Hz")

        // We don't need video
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = captureStream

        let queue = DispatchQueue(label: "com.scribe.audio-capture", qos: .userInitiated)

        if captureSystem {
            try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            Log.debug("Added system audio output")
        }
        if captureMic {
            try captureStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            Log.debug("Added microphone output")
        }

        do {
            try await captureStream.startCapture()
        } catch {
            handlePermissionError(error)
            throw error
        }

        Log.info("Audio capture started")

        // Suspend until stopCapture() resumes the continuation
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.continuation = cont
        }
    }

    /// Stop capturing and return the mixed, resampled audio samples.
    func stopCapture() -> [Float] {
        Log.info("Stopping audio capture...")

        // Stop the stream
        if let stream = self.stream {
            // Fire and forget the async stop - samples are already captured
            let streamToStop = stream
            Task { @Sendable in
                do {
                    try await streamToStop.stopCapture()
                } catch {
                    Log.warning("Error stopping stream: \(error.localizedDescription)")
                }
            }
        }
        self.stream = nil

        // Resume the continuation so startCapture() returns
        continuation?.resume()
        continuation = nil

        Log.debug("Raw samples - mic: \(micSamples.count), system: \(systemSamples.count)")

        // Resample both streams to 16kHz mono
        var resampledMic: [Float] = []
        var resampledSystem: [Float] = []

        if !micSamples.isEmpty {
            if let resampled = AudioWriter.resample(micSamples, fromRate: micSampleRate, channels: 1) {
                resampledMic = resampled
                Log.debug("Resampled mic (\(micSampleRate) Hz -> 16 kHz): \(resampled.count) samples (\(String(format: "%.1f", Double(resampled.count) / AudioWriter.sampleRate))s)")
            } else {
                Log.warning("Failed to resample microphone audio")
            }
        }

        if !systemSamples.isEmpty {
            if let resampled = AudioWriter.resample(systemSamples, fromRate: sourceSampleRate, channels: 2) {
                resampledSystem = resampled
                Log.debug("Resampled system: \(resampled.count) samples (\(String(format: "%.1f", Double(resampled.count) / AudioWriter.sampleRate))s)")
            } else {
                Log.warning("Failed to resample system audio")
            }
        }

        // Mix mic and system audio
        let mixed: [Float]
        if !resampledMic.isEmpty && !resampledSystem.isEmpty {
            mixed = AudioWriter.mix(resampledMic, resampledSystem)
            Log.debug("Mixed audio: \(mixed.count) samples")
        } else if !resampledMic.isEmpty {
            mixed = resampledMic
        } else if !resampledSystem.isEmpty {
            mixed = resampledSystem
        } else {
            Log.warning("No audio samples captured")
            return []
        }

        // Remove silence
        let trimmed = AudioWriter.removeSilence(from: mixed)
        let duration = Double(trimmed.count) / AudioWriter.sampleRate
        Log.info("Final audio: \(trimmed.count) samples (\(String(format: "%.1f", duration))s)")

        return trimmed
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        // Only process audio types
        guard type == .audio || type == .microphone else { return }

        guard let samples = AudioWriter.extractSamples(from: sampleBuffer) else { return }

        // Read actual sample rate from the buffer's format description
        var bufferSampleRate = sourceSampleRate
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            bufferSampleRate = asbd.pointee.mSampleRate
        }

        switch type {
        case .audio:
            systemSamples.append(contentsOf: samples)
            if systemSamples.count % 100000 < samples.count {
                Log.debug("System audio: \(systemSamples.count) samples buffered (\(bufferSampleRate) Hz)")
            }
        case .microphone:
            // Store mic sample rate - it may differ from system audio
            micSampleRate = bufferSampleRate
            micSamples.append(contentsOf: samples)
            if micSamples.count % 100000 < samples.count {
                Log.debug("Mic audio: \(micSamples.count) samples buffered (\(bufferSampleRate) Hz)")
            }
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.error("Stream stopped with error: \(error.localizedDescription)")
        handlePermissionError(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - Private

    private func handlePermissionError(_ error: any Error) {
        let nsError = error as NSError
        // SCStream permission errors are typically in the SCStreamError domain
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" ||
           nsError.localizedDescription.lowercased().contains("permission") ||
           nsError.code == -3801 {
            Log.error("Screen recording permission denied.")
            Log.status("To grant permission, open:")
            Log.status("  System Settings > Privacy & Security > Screen & System Audio Recording")
            Log.status("Then enable access for your terminal application (e.g., Terminal, iTerm2).")
        }
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture"
        }
    }
}
