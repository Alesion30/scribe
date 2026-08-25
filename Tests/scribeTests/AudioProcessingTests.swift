import Testing
import Accelerate
@testable import scribe

/// Tests for the audio processing pipeline, focusing on the offline meeting
/// transcription accuracy fix (silent source detection before mixing).
@Suite("Audio Processing Pipeline")
struct AudioProcessingTests {

    // MARK: - Helpers

    /// Generate a sine wave signal simulating speech.
    static func sineWave(frequency: Float, amplitude: Float, durationSeconds: Float, sampleRate: Float = 16000) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        return (0..<count).map { i in
            amplitude * sinf(2.0 * .pi * frequency * Float(i) / sampleRate)
        }
    }

    /// Generate near-silent noise (simulating system audio with no playback).
    static func silence(durationSeconds: Float, noiseAmplitude: Float = 0.0005, sampleRate: Float = 16000) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        return (0..<count).map { _ in
            Float.random(in: -noiseAmplitude...noiseAmplitude)
        }
    }

    /// Generate room noise (constant background + intermittent speech).
    static func roomAudio(durationSeconds: Float, sampleRate: Float = 16000) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)

        // Constant background noise (low amplitude)
        for i in 0..<count {
            samples[i] = Float.random(in: -0.02...0.02)
        }

        // Add speech-like bursts (sine wave at speech frequency)
        let speechStart = count / 4
        let speechEnd = count * 3 / 4
        for i in speechStart..<speechEnd {
            samples[i] += 0.3 * sinf(2.0 * .pi * 300.0 * Float(i) / sampleRate)
        }

        return samples
    }

    /// Compute RMS of audio samples.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(samples, 1, &sumSq, vDSP_Length(samples.count))
        return sqrtf(sumSq / Float(samples.count))
    }

    /// Compute peak of audio samples.
    static func peak(_ samples: [Float]) -> Float {
        var p: Float = 0
        vDSP_maxmgv(samples, 1, &p, vDSP_Length(samples.count))
        return p
    }

    /// The finalizer's own audibility test, so these cases track the rule that actually ships.
    static func isAudible(_ samples: [Float]) -> Bool {
        LevelMeter.activeLevel(of: samples) >= RecordingFinalizer.silenceLevelThreshold
    }

    // MARK: - Silence Detection Tests

    @Test("Near-silent audio is not audible")
    func silentAudioIsNotAudible() {
        let silent = Self.silence(durationSeconds: 5.0)
        #expect(!Self.isAudible(silent), "Silent audio level (\(LevelMeter.activeLevel(of: silent))) should be below the threshold")
    }

    @Test("Speech audio is audible")
    func speechAudioIsAudible() {
        let speech = Self.sineWave(frequency: 300, amplitude: 0.3, durationSeconds: 5.0)
        #expect(Self.isAudible(speech), "Speech level (\(LevelMeter.activeLevel(of: speech))) should be above the threshold")
    }

    @Test("Room audio with speech is audible")
    func roomAudioIsAudible() {
        let room = Self.roomAudio(durationSeconds: 5.0)
        #expect(Self.isAudible(room), "Room audio level (\(LevelMeter.activeLevel(of: room))) should be above the threshold")
    }

    // MARK: - Mixing Pipeline Tests (the core fix)

    @Test("Offline meeting: silent system audio should not degrade mic audio")
    func offlineMeetingSilentSystemAudioExcluded() {
        // Simulate offline meeting: mic has speech, system is near-silent
        let micAudio = Self.roomAudio(durationSeconds: 5.0)
        let systemAudio = Self.silence(durationSeconds: 5.0)

        // Pipeline WITHOUT fix: normalize both and mix
        let normalizedSystem = AudioWriter.normalize(systemAudio, targetPeak: 0.5)
        let normalizedMic = AudioWriter.normalize(micAudio, targetPeak: 0.5)
        let mixedWithoutFix = AudioWriter.mix(normalizedMic, normalizedSystem)

        // Pipeline WITH fix: detect silence, exclude system, use mic only
        let micOnly: [Float]
        if !Self.isAudible(systemAudio) {
            // Fix applied: skip system audio
            micOnly = AudioWriter.normalize(micAudio, targetPeak: 0.5)
        } else {
            // Both are valid
            micOnly = mixedWithoutFix
        }

        // The fix should produce cleaner audio:
        // Compare SNR by measuring how much noise was added

        // In the "without fix" case, the system noise was amplified hugely
        let systemNoiseGain = 0.5 / Self.peak(systemAudio)
        #expect(systemNoiseGain > 100, "System noise amplification (\(systemNoiseGain)x) should be extreme without fix")

        // The fixed output should have much lower noise in silent segments
        // Check the first quarter (before speech) - should be mostly quiet
        let silentSegmentCount = micOnly.count / 4
        let fixedSilentRMS = Self.rms(Array(micOnly[0..<silentSegmentCount]))
        let unfixedSilentRMS = Self.rms(Array(mixedWithoutFix[0..<silentSegmentCount]))

        #expect(fixedSilentRMS < unfixedSilentRMS,
                "Fixed pipeline silent segment RMS (\(fixedSilentRMS)) should be lower than unfixed (\(unfixedSilentRMS))")
    }

    @Test("Online meeting: both sources preserved when both have content")
    func onlineMeetingBothSourcesPreserved() {
        // Simulate online meeting: both mic and system have real audio
        let micAudio = Self.sineWave(frequency: 300, amplitude: 0.2, durationSeconds: 5.0)
        let systemAudio = Self.sineWave(frequency: 500, amplitude: 0.3, durationSeconds: 5.0)

        // Neither should be detected as silent
        #expect(Self.isAudible(micAudio), "Mic audio should not be detected as silent")
        #expect(Self.isAudible(systemAudio), "System audio should not be detected as silent")

        // Both should be mixed
        let normalizedMic = AudioWriter.normalize(micAudio, targetPeak: 0.5)
        let normalizedSystem = AudioWriter.normalize(systemAudio, targetPeak: 0.5)
        let mixed = AudioWriter.mix(normalizedMic, normalizedSystem)

        #expect(!mixed.isEmpty, "Mixed result should not be empty")
        #expect(Self.peak(mixed) > 0, "Mixed result should have audio content")
    }

    // MARK: - Normalize Tests

    @Test("Normalize scales to target peak")
    func normalizeScalesToTarget() {
        let samples = Self.sineWave(frequency: 440, amplitude: 0.1, durationSeconds: 1.0)
        let normalized = AudioWriter.normalize(samples, targetPeak: 0.9)
        let peakValue = Self.peak(normalized)
        #expect(abs(peakValue - 0.9) < 0.05, "Normalized peak (\(peakValue)) should be close to 0.9")
    }

    @Test("Normalize handles empty input")
    func normalizeHandlesEmpty() {
        let result = AudioWriter.normalize([], targetPeak: 0.9)
        #expect(result.isEmpty)
    }

    @Test("Normalize handles all-zero input")
    func normalizeHandlesZero() {
        let zeros = [Float](repeating: 0, count: 1000)
        let result = AudioWriter.normalize(zeros, targetPeak: 0.9)
        let peakValue = Self.peak(result)
        #expect(peakValue == 0, "All-zero input should remain zero after normalization")
    }

    // MARK: - Noise Gate Tests

    @Test("Noise gate preserves speech segments")
    func noiseGatePreservesSpeech() {
        let audio = Self.roomAudio(durationSeconds: 5.0)
        let denoised = AudioWriter.reduceNoise(from: audio)

        // The speech segment (middle half) should be largely preserved
        let speechStart = denoised.count / 4
        let speechEnd = denoised.count * 3 / 4
        let speechRMS = Self.rms(Array(denoised[speechStart..<speechEnd]))

        #expect(speechRMS > 0.05, "Speech segment should be preserved after noise gate (RMS=\(speechRMS))")
    }

    @Test("Noise gate attenuates silence segments")
    func noiseGateAttenuatesSilence() {
        let audio = Self.roomAudio(durationSeconds: 5.0)
        let denoised = AudioWriter.reduceNoise(from: audio)

        // The non-speech segment (first quarter) should be attenuated
        let silentCount = denoised.count / 4
        let originalSilentRMS = Self.rms(Array(audio[0..<silentCount]))
        let denoisedSilentRMS = Self.rms(Array(denoised[0..<silentCount]))

        #expect(denoisedSilentRMS <= originalSilentRMS,
                "Silent segment RMS should decrease after noise gate (before: \(originalSilentRMS), after: \(denoisedSilentRMS))")
    }

    @Test("Noise gate keeps the quiet half of a recording that never falls silent")
    func noiseGateKeepsQuietSpeechInADenseRecording() {
        // A meeting with no gaps: the quietest fifth is a softer speaker, not the room.
        // Estimating the noise floor from it puts the floor inside the voice.
        let sampleRate = Float(AudioWriter.sampleRate)
        let count = Int(sampleRate * 8)
        let quietStart = count * 3 / 4
        let audio = (0..<count).map { i -> Float in
            let amplitude: Float = i < quietStart ? 0.3 : 0.06
            return amplitude * sinf(2.0 * .pi * 300.0 * Float(i) / sampleRate)
        }

        let denoised = AudioWriter.reduceNoise(from: audio)

        // Measured clear of the window the gate ramps across.
        let from = quietStart + LevelMeter.windowSamples * 2
        let to = count - LevelMeter.windowSamples * 2
        let kept = Self.rms(Array(denoised[from..<to])) / Self.rms(Array(audio[from..<to]))

        #expect(kept > 0.5, "the softer speaker was cut to \(kept) of their level")
    }

    // MARK: - Mix Tests

    @Test("Mix preserves audio when one source is empty")
    func mixWithOneEmpty() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 1.0)
        let result = AudioWriter.mix(audio, [])
        #expect(result.count == audio.count)
        #expect(result == audio)
    }

    @Test("Mix clamps output to [-1, 1]")
    func mixClampsOutput() {
        let loud = Self.sineWave(frequency: 440, amplitude: 0.8, durationSeconds: 1.0)
        let mixed = AudioWriter.mix(loud, loud)
        let peakValue = Self.peak(mixed)
        #expect(peakValue <= 1.0, "Mixed output peak (\(peakValue)) should be <= 1.0")
    }

    // MARK: - Slice Tests

    @Test("Slice without a range returns the whole input")
    func sliceWithoutRange() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 3.0)
        let result = AudioWriter.slice(audio, startSeconds: 0)
        #expect(result == audio)
    }

    @Test("Slice drops samples before the start offset")
    func sliceDropsLeadingSamples() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 3.0)
        let result = AudioWriter.slice(audio, startSeconds: 1.0)
        #expect(result.count == audio.count - 16000)
        #expect(result.first == audio[16000])
    }

    @Test("Slice honors start and duration")
    func sliceHonorsStartAndDuration() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 10.0)
        let result = AudioWriter.slice(audio, startSeconds: 2.5, durationSeconds: 1.5)
        #expect(result.count == 24000)
        #expect(result == Array(audio[40000..<64000]))
    }

    @Test("Slice clamps a duration running past the end")
    func sliceClampsOverlongDuration() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 3.0)
        let result = AudioWriter.slice(audio, startSeconds: 2.0, durationSeconds: 60.0)
        #expect(result.count == 16000)
        #expect(result == Array(audio[32000...]))
    }

    @Test("Slice returns empty when the start offset is past the end")
    func sliceStartPastEnd() {
        let audio = Self.sineWave(frequency: 440, amplitude: 0.5, durationSeconds: 1.0)
        let result = AudioWriter.slice(audio, startSeconds: 5.0, durationSeconds: 1.0)
        #expect(result.isEmpty)
    }

    @Test("Slice handles empty input")
    func sliceHandlesEmpty() {
        let result = AudioWriter.slice([], startSeconds: 1.0, durationSeconds: 1.0)
        #expect(result.isEmpty)
    }

    // MARK: - Before/After Comparison

    @Test("Quantitative comparison: fix vs no-fix for offline meeting")
    func quantitativeBeforeAfterComparison() {
        // Simulate offline meeting: mic has speech, system has near-silent noise
        let micSamples = Self.roomAudio(durationSeconds: 10.0)
        let systemSamples = Self.silence(durationSeconds: 10.0, noiseAmplitude: 0.0003)

        // --- WITHOUT FIX: normalize both blindly and mix ---
        let unfixedMic = AudioWriter.normalize(micSamples, targetPeak: 0.5)
        let unfixedSystem = AudioWriter.normalize(systemSamples, targetPeak: 0.5)
        let unfixedMixed = AudioWriter.mix(unfixedMic, unfixedSystem)
        let unfixedDenoised = AudioWriter.reduceNoise(from: unfixedMixed)
        let unfixedOutput = AudioWriter.normalize(unfixedDenoised, targetPeak: 0.9)

        // --- WITH FIX: detect silence, exclude system audio ---
        var fixedMic = micSamples
        var fixedSystem = systemSamples

        if !Self.isAudible(fixedSystem) {
            fixedSystem = []
        }

        if !fixedMic.isEmpty {
            fixedMic = AudioWriter.normalize(fixedMic, targetPeak: 0.5)
        }
        if !fixedSystem.isEmpty {
            fixedSystem = AudioWriter.normalize(fixedSystem, targetPeak: 0.5)
        }

        let fixedMixed: [Float]
        if !fixedMic.isEmpty && !fixedSystem.isEmpty {
            fixedMixed = AudioWriter.mix(fixedMic, fixedSystem)
        } else if !fixedMic.isEmpty {
            fixedMixed = fixedMic
        } else {
            fixedMixed = fixedSystem
        }
        let fixedDenoised = AudioWriter.reduceNoise(from: fixedMixed)
        let fixedOutput = AudioWriter.normalize(fixedDenoised, targetPeak: 0.9)

        // --- Compare quality metrics ---

        // 1. Noise floor in silent segments (first quarter = no speech)
        let silentCount = min(unfixedOutput.count, fixedOutput.count) / 4
        let unfixedNoiseRMS = Self.rms(Array(unfixedOutput[0..<silentCount]))
        let fixedNoiseRMS = Self.rms(Array(fixedOutput[0..<silentCount]))

        #expect(fixedNoiseRMS < unfixedNoiseRMS,
                "Fixed noise floor (\(fixedNoiseRMS)) should be lower than unfixed (\(unfixedNoiseRMS))")

        // 2. Signal clarity in speech segments (middle half)
        let count = min(unfixedOutput.count, fixedOutput.count)
        let speechStart = count / 4
        let speechEnd = count * 3 / 4
        let unfixedSpeechRMS = Self.rms(Array(unfixedOutput[speechStart..<speechEnd]))
        let fixedSpeechRMS = Self.rms(Array(fixedOutput[speechStart..<speechEnd]))

        // 3. SNR improvement: speech RMS / noise RMS
        let unfixedSNR = unfixedSpeechRMS / max(unfixedNoiseRMS, 0.0001)
        let fixedSNR = fixedSpeechRMS / max(fixedNoiseRMS, 0.0001)

        #expect(fixedSNR > unfixedSNR,
                "Fixed SNR (\(String(format: "%.1f", fixedSNR))) should be better than unfixed (\(String(format: "%.1f", unfixedSNR)))")

        // 4. System noise amplification factor (diagnostic)
        let systemPeak = Self.peak(systemSamples)
        let amplificationFactor = 0.5 / systemPeak
        #expect(amplificationFactor > 100,
                "Without fix, system noise would be amplified \(String(format: "%.0f", amplificationFactor))x")
    }

    // MARK: - Edge Case: Very quiet but real audio

    @Test("Quiet but real system audio is NOT excluded")
    func quietRealAudioNotExcluded() {
        // Simulate system audio that's quiet but has real content
        // e.g., someone has their volume low in an online meeting
        let quietSpeech = Self.sineWave(frequency: 400, amplitude: 0.05, durationSeconds: 5.0)
        #expect(Self.isAudible(quietSpeech), "Quiet real audio level (\(LevelMeter.activeLevel(of: quietSpeech))) should be above the threshold")
    }

    @Test("Threshold boundary: noise floors either side of the audible level")
    func thresholdBoundary() {
        // Uniform noise meters at amplitude/sqrt(3), which puts these either side of the threshold.
        let belowThreshold = Self.silence(durationSeconds: 5.0, noiseAmplitude: 0.002)
        #expect(!Self.isAudible(belowThreshold), "level \(LevelMeter.activeLevel(of: belowThreshold)) should be below the threshold")

        let aboveThreshold = Self.silence(durationSeconds: 5.0, noiseAmplitude: 0.02)
        #expect(Self.isAudible(aboveThreshold), "level \(LevelMeter.activeLevel(of: aboveThreshold)) should be above the threshold")
    }

    // MARK: - Full Pipeline Integration Test

    @Test("Full pipeline: offline meeting produces clean output")
    func fullPipelineOfflineMeeting() {
        // Simulate the exact stopCapture() pipeline for an offline meeting
        let micSamples = Self.roomAudio(durationSeconds: 10.0)
        let systemSamples = Self.silence(durationSeconds: 10.0, noiseAmplitude: 0.0003)

        // Step 1: Silence detection (the fix)
        var activeMic = micSamples
        var activeSystem = systemSamples

        if !Self.isAudible(activeSystem) { activeSystem = [] }
        if !Self.isAudible(activeMic) { activeMic = [] }

        // Verify system was excluded, mic was kept
        #expect(activeSystem.isEmpty, "System audio should be excluded")
        #expect(!activeMic.isEmpty, "Mic audio should be kept")

        // Step 2: Normalize (only mic since system was excluded)
        let mixTarget: Float = 0.5
        if !activeMic.isEmpty {
            activeMic = AudioWriter.normalize(activeMic, targetPeak: mixTarget)
        }

        // Step 3: Mix (mic only)
        let mixed = activeMic

        // Step 4: Noise gate
        let denoised = AudioWriter.reduceNoise(from: mixed)

        // Step 5: Final normalize
        let output = AudioWriter.normalize(denoised, targetPeak: 0.9)

        // Verify output quality
        let outputPeak = Self.peak(output)
        #expect(abs(outputPeak - 0.9) < 0.05, "Output peak (\(outputPeak)) should be near 0.9")

        // Speech segment should be strong
        let speechStart = output.count / 4
        let speechEnd = output.count * 3 / 4
        let speechRMS = Self.rms(Array(output[speechStart..<speechEnd]))
        #expect(speechRMS > 0.1, "Speech segment should have strong signal (RMS=\(speechRMS))")
    }
}
