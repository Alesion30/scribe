@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Accelerate

/// Captures microphone (via AVAudioEngine) and/or system audio (via ScreenCaptureKit).
///
/// Microphone capture deliberately does NOT go through ScreenCaptureKit:
/// running a display-scoped SCStream blocks other apps (e.g. Google Meet)
/// from initiating screen sharing while scribe is recording. By isolating
/// mic capture to AVAudioEngine, mic-only sessions touch ScreenCaptureKit
/// not at all, and mic+system sessions only run an audio-only SCStream.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let captureMic: Bool
    let captureSystem: Bool

    // ScreenCaptureKit — system audio only
    private var stream: SCStream?
    private var systemSamples: [Float] = []
    private var sourceSampleRate: Double = 48000

    // AVAudioEngine — microphone
    private var audioEngine: AVAudioEngine?
    private var micSamples: [Float] = []
    private var micSampleRate: Double = 48000
    private var micChannelCount: Int = 1

    private var continuation: CheckedContinuation<Void, any Error>?

    // Mic and system audio arrive on independent threads — guard the buffers.
    private let samplesLock = NSLock()

    init(captureMic: Bool = true, captureSystem: Bool = true) {
        self.captureMic = captureMic
        self.captureSystem = captureSystem
        super.init()
    }

    // MARK: - Public API

    /// Start capturing audio. Suspends until stopCapture() is called.
    func startCapture() async throws {
        Log.info("Starting audio capture (mic: \(captureMic), system: \(captureSystem))")

        if captureMic {
            try startMicrophoneCapture()
        }

        if captureSystem {
            try await startSystemAudioCapture()
        }

        // Suspend until stopCapture() resumes the continuation
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.continuation = cont
        }
    }

    /// Stop capturing and return the mixed, resampled audio samples.
    func stopCapture() -> [Float] {
        Log.info("Stopping audio capture...")

        // Stop microphone (AVAudioEngine)
        if let engine = self.audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.audioEngine = nil

        // Stop system audio stream (ScreenCaptureKit)
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

        samplesLock.lock()
        let rawMic = micSamples
        let rawSystem = systemSamples
        samplesLock.unlock()

        Log.debug("Raw samples - mic: \(rawMic.count), system: \(rawSystem.count)")

        // Resample both streams to 16kHz mono
        var resampledMic: [Float] = []
        var resampledSystem: [Float] = []

        if !rawMic.isEmpty {
            if let resampled = AudioWriter.resample(rawMic, fromRate: micSampleRate, channels: micChannelCount) {
                resampledMic = resampled
                Log.debug("Resampled mic (\(micSampleRate) Hz, \(micChannelCount)ch -> 16 kHz mono): \(resampled.count) samples (\(String(format: "%.1f", Double(resampled.count) / AudioWriter.sampleRate))s)")
            } else {
                Log.warning("Failed to resample microphone audio")
            }
        }

        if !rawSystem.isEmpty {
            if let resampled = AudioWriter.resample(rawSystem, fromRate: sourceSampleRate, channels: 2) {
                resampledSystem = resampled
                Log.debug("Resampled system: \(resampled.count) samples (\(String(format: "%.1f", Double(resampled.count) / AudioWriter.sampleRate))s)")
            } else {
                Log.warning("Failed to resample system audio")
            }
        }

        // Detect near-silent sources and exclude them from the mix.
        // Prevents amplifying system noise during offline meetings
        // (where no meaningful system audio exists) and vice versa.
        let silenceRMSThreshold: Float = 0.01
        if !resampledSystem.isEmpty {
            var sumSq: Float = 0
            vDSP_svesq(resampledSystem, 1, &sumSq, vDSP_Length(resampledSystem.count))
            let rms = sqrtf(sumSq / Float(resampledSystem.count))
            if rms < silenceRMSThreshold {
                Log.info("System audio is near-silent (RMS=\(String(format: "%.5f", rms))), excluding from mix")
                resampledSystem = []
            } else {
                Log.debug("System audio RMS: \(String(format: "%.5f", rms))")
            }
        }
        if !resampledMic.isEmpty {
            var sumSq: Float = 0
            vDSP_svesq(resampledMic, 1, &sumSq, vDSP_Length(resampledMic.count))
            let rms = sqrtf(sumSq / Float(resampledMic.count))
            if rms < silenceRMSThreshold {
                Log.info("Mic audio is near-silent (RMS=\(String(format: "%.5f", rms))), excluding from mix")
                resampledMic = []
            } else {
                Log.debug("Mic audio RMS: \(String(format: "%.5f", rms))")
            }
        }

        // Normalize each source to the same level before mixing
        // so quiet mic doesn't get buried by louder system audio.
        let mixTarget: Float = 0.5
        if !resampledMic.isEmpty {
            resampledMic = AudioWriter.normalize(resampledMic, targetPeak: mixTarget)
        }
        if !resampledSystem.isEmpty {
            resampledSystem = AudioWriter.normalize(resampledSystem, targetPeak: mixTarget)
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

        // Reduce background noise before amplification
        let denoised = AudioWriter.reduceNoise(from: mixed)

        // Normalize volume (peak → 0.9 to leave headroom)
        let normalized = AudioWriter.normalize(denoised)

        let duration = Double(normalized.count) / AudioWriter.sampleRate
        Log.info("Final audio: \(normalized.count) samples (\(String(format: "%.1f", duration))s)")

        return normalized
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw AudioCaptureError.invalidMicrophoneFormat
        }

        micSampleRate = format.sampleRate
        micChannelCount = Int(format.channelCount)
        Log.debug("Microphone format: \(micSampleRate) Hz, \(micChannelCount) channel(s)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            handleMicrophonePermissionError(error)
            throw error
        }

        self.audioEngine = engine
        Log.info("Microphone capture started (AVAudioEngine)")
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameCount > 0, channels > 0 else { return }

        let samples: [Float]
        if channels == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            // Interleave (L,R,L,R,...) so AudioWriter.resample can deinterleave.
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for ch in 0..<channels {
                let src = channelData[ch]
                for frame in 0..<frameCount {
                    interleaved[frame * channels + ch] = src[frame]
                }
            }
            samples = interleaved
        }

        samplesLock.lock()
        micSamples.append(contentsOf: samples)
        let total = micSamples.count
        samplesLock.unlock()

        if total % 100000 < frameCount * channels {
            Log.debug("Mic audio: \(total) samples buffered (\(micSampleRate) Hz)")
        }
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
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
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        // Mic is captured via AVAudioEngine — keep ScreenCaptureKit audio-only.
        config.captureMicrophone = false

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
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        Log.debug("Added system audio output")

        do {
            try await captureStream.startCapture()
        } catch {
            handlePermissionError(error)
            throw error
        }

        Log.info("System audio capture started (ScreenCaptureKit)")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        // Mic comes from AVAudioEngine; only system audio flows through SCStream now.
        guard type == .audio else { return }

        guard let samples = AudioWriter.extractSamples(from: sampleBuffer) else { return }

        var bufferSampleRate = sourceSampleRate
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            bufferSampleRate = asbd.pointee.mSampleRate
        }

        samplesLock.lock()
        systemSamples.append(contentsOf: samples)
        let total = systemSamples.count
        samplesLock.unlock()

        if total % 100000 < samples.count {
            Log.debug("System audio: \(total) samples buffered (\(bufferSampleRate) Hz)")
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

    private func handleMicrophonePermissionError(_ error: any Error) {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("permission") || description.contains("microphone") || nsError.code == 561017449 {
            Log.error("Microphone permission denied.")
            Log.status("To grant permission, open:")
            Log.status("  System Settings > Privacy & Security > Microphone")
            Log.status("Then enable access for your terminal application (e.g., Terminal, iTerm2).")
        }
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case invalidMicrophoneFormat

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture"
        case .invalidMicrophoneFormat:
            return "Microphone returned an invalid audio format (sample rate is 0)"
        }
    }
}
