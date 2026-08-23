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
    private var systemChunks: [TimedChunk] = []
    private var sourceSampleRate: Double = 48000
    private var systemChannelCount: Int = 2

    // AVAudioEngine — microphone
    private var audioEngine: AVAudioEngine?
    private var micChunks: [TimedChunk] = []
    private var micSampleRate: Double = 48000
    private var micChannelCount: Int = 1

    /// Sources quieter than this carry only noise, so they are left out of the mix.
    private static let silenceRMSThreshold: Float = 0.01

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
        let micBuffers = micChunks
        let systemBuffers = systemChunks
        let micRate = micSampleRate
        let micChannels = micChannelCount
        let systemRate = sourceSampleRate
        let systemChannels = systemChannelCount
        samplesLock.unlock()

        Log.debug("Captured buffers - mic: \(micBuffers.count), system: \(systemBuffers.count)")

        // Lay each stream out on the host clock. Appending buffers in arrival order would fold the
        // gap between the two capture start times into the mix, doubling whatever both streams heard.
        var micTrack = AudioTimeline.track(from: micBuffers, sampleRate: micRate, channels: micChannels)
        var systemTrack = AudioTimeline.track(from: systemBuffers, sampleRate: systemRate, channels: systemChannels)

        if !micTrack.isEmpty {
            Log.debug("Mic track (\(micRate) Hz, \(micChannels)ch -> 16 kHz mono): \(micTrack.samples.count) samples (\(String(format: "%.1f", micTrack.duration))s)")
        }
        if !systemTrack.isEmpty {
            Log.debug("System track (\(systemRate) Hz, \(systemChannels)ch -> 16 kHz mono): \(systemTrack.samples.count) samples (\(String(format: "%.1f", systemTrack.duration))s)")
        }
        if !micTrack.isEmpty && !systemTrack.isEmpty {
            let skew = systemTrack.startSeconds - micTrack.startSeconds
            Log.debug("System audio starts \(String(format: "%+.3f", skew))s relative to the mic")
        }

        // Detect near-silent sources and exclude them from the mix.
        // Prevents amplifying system noise during offline meetings
        // (where no meaningful system audio exists) and vice versa.
        systemTrack = Self.discardIfSilent(systemTrack, label: "System")
        micTrack = Self.discardIfSilent(micTrack, label: "Mic")

        // Normalize each source to the same level before mixing
        // so quiet mic doesn't get buried by louder system audio.
        let mixTarget: Float = 0.5
        if !micTrack.isEmpty {
            micTrack = micTrack.with(samples: AudioWriter.normalize(micTrack.samples, targetPeak: mixTarget))
        }
        if !systemTrack.isEmpty {
            systemTrack = systemTrack.with(samples: AudioWriter.normalize(systemTrack.samples, targetPeak: mixTarget))
        }

        // Mix mic and system audio, lined up by when each stream actually started
        let mixed: [Float]
        if !micTrack.isEmpty && !systemTrack.isEmpty {
            let (alignedMic, alignedSystem) = AudioTimeline.align(micTrack, systemTrack)
            mixed = AudioWriter.mix(alignedMic.samples, alignedSystem.samples)
            Log.debug("Mixed audio: \(mixed.count) samples")
        } else if !micTrack.isEmpty {
            mixed = micTrack.samples
        } else if !systemTrack.isEmpty {
            mixed = systemTrack.samples
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

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handleMicBuffer(buffer, at: time)
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

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
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

        // AVAudioEngine normally stamps the tap against the host clock; fall back if it does not.
        let startSeconds = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : Self.arrivalStart(frames: frameCount, sampleRate: micSampleRate)

        samplesLock.lock()
        micChunks.append(TimedChunk(startSeconds: startSeconds, samples: samples))
        let total = micChunks.count
        samplesLock.unlock()

        if total.isMultiple(of: 250) {
            Log.debug("Mic audio: \(total) buffers captured (\(micSampleRate) Hz)")
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
        var bufferChannels = systemChannelCount
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            bufferSampleRate = asbd.pointee.mSampleRate
            bufferChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
        guard bufferSampleRate > 0, bufferChannels > 0 else { return }

        // ScreenCaptureKit stamps against the host clock — the same one AVAudioEngine uses for the mic.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startSeconds = pts.isValid
            ? AVAudioTime.seconds(forHostTime: CMClockConvertHostTimeToSystemUnits(pts))
            : Self.arrivalStart(frames: samples.count / bufferChannels, sampleRate: bufferSampleRate)

        samplesLock.lock()
        sourceSampleRate = bufferSampleRate
        systemChannelCount = bufferChannels
        systemChunks.append(TimedChunk(startSeconds: startSeconds, samples: samples))
        let total = systemChunks.count
        samplesLock.unlock()

        if total.isMultiple(of: 250) {
            Log.debug("System audio: \(total) buffers captured (\(bufferSampleRate) Hz, \(bufferChannels)ch)")
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

    /// Host-clock instant of a buffer's first frame, worked back from when the buffer arrived.
    private static func arrivalStart(frames: Int, sampleRate: Double) -> Double {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guard sampleRate > 0 else { return now }
        return now - Double(frames) / sampleRate
    }

    /// Drop a source that carries no real audio, so the mix does not amplify its noise floor.
    private static func discardIfSilent(_ track: AudioTrack, label: String) -> AudioTrack {
        guard !track.isEmpty else { return track }

        var sumSq: Float = 0
        vDSP_svesq(track.samples, 1, &sumSq, vDSP_Length(track.samples.count))
        let rms = sqrtf(sumSq / Float(track.samples.count))

        guard rms < silenceRMSThreshold else {
            Log.debug("\(label) audio RMS: \(String(format: "%.5f", rms))")
            return track
        }

        Log.info("\(label) audio is near-silent (RMS=\(String(format: "%.5f", rms))), excluding from mix")
        return .empty
    }

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
