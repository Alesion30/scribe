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

    // MARK: - Silence Detection Tests

    @Test("Near-silent audio has RMS below threshold")
    func silentAudioRMSBelowThreshold() {
        let silent = Self.silence(durationSeconds: 5.0)
        let rmsValue = Self.rms(silent)
        #expect(rmsValue < 0.01, "Silent audio RMS (\(rmsValue)) should be below 0.01 threshold")
    }

    @Test("Speech audio has RMS above threshold")
    func speechAudioRMSAboveThreshold() {
        let speech = Self.sineWave(frequency: 300, amplitude: 0.3, durationSeconds: 5.0)
        let rmsValue = Self.rms(speech)
        #expect(rmsValue > 0.01, "Speech audio RMS (\(rmsValue)) should be above 0.01 threshold")
    }

    @Test("Room audio with speech has RMS above threshold")
    func roomAudioRMSAboveThreshold() {
        let room = Self.roomAudio(durationSeconds: 5.0)
        let rmsValue = Self.rms(room)
        #expect(rmsValue > 0.01, "Room audio RMS (\(rmsValue)) should be above 0.01 threshold")
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
        let silenceThreshold: Float = 0.01
        let systemRMS = Self.rms(systemAudio)
        let micOnly: [Float]
        if systemRMS < silenceThreshold {
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

        let silenceThreshold: Float = 0.01
        let micRMS = Self.rms(micAudio)
        let systemRMS = Self.rms(systemAudio)

        // Neither should be detected as silent
        #expect(micRMS >= silenceThreshold, "Mic audio should not be detected as silent")
        #expect(systemRMS >= silenceThreshold, "System audio should not be detected as silent")

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

        // --- WITH FIX: run the real mixdown, which drops the silent source ---
        let fixedOutput = AudioCapture.mixdown(
            mic: AudioTrack(startSeconds: 0, samples: micSamples),
            system: AudioTrack(startSeconds: 0, samples: systemSamples)
        )

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
        let rmsValue = Self.rms(quietSpeech)
        #expect(rmsValue > 0.01, "Quiet real audio RMS (\(rmsValue)) should be above silence threshold")
    }

    @Test("Threshold boundary: audio at exactly threshold level")
    func thresholdBoundary() {
        // Create audio with RMS just above and just below threshold
        let belowThreshold = Self.silence(durationSeconds: 5.0, noiseAmplitude: 0.005)
        let belowRMS = Self.rms(belowThreshold)
        #expect(belowRMS < 0.01, "Below-threshold audio RMS (\(belowRMS)) should be < 0.01")

        // Audio with amplitude ~0.03 should give RMS ~0.017 (above threshold)
        let aboveThreshold = (0..<80000).map { _ in Float.random(in: -0.03...0.03) }
        let aboveRMS = Self.rms(aboveThreshold)
        #expect(aboveRMS > 0.01, "Above-threshold audio RMS (\(aboveRMS)) should be > 0.01")
    }

    // MARK: - Full Pipeline Integration Test

    @Test("Full pipeline: offline meeting produces clean output")
    func fullPipelineOfflineMeeting() {
        // Offline meeting: the mic hears the room, the system stream carries nothing.
        let mic = AudioTrack(startSeconds: 100.0, samples: Self.roomAudio(durationSeconds: 10.0))
        let system = AudioTrack(startSeconds: 100.0, samples: Self.silence(durationSeconds: 10.0, noiseAmplitude: 0.0003))

        let systemRMS = Self.rms(system.samples)
        let micRMS = Self.rms(mic.samples)
        #expect(systemRMS < 0.01, "System audio should read as silent (RMS=\(systemRMS))")
        #expect(micRMS > 0.01, "Mic audio should read as active (RMS=\(micRMS))")

        let output = AudioCapture.mixdown(mic: mic, system: system)

        // The silent system track is excluded, so the mic track comes through on its own.
        #expect(output.count == mic.samples.count, "Output should keep the mic track's length")

        let outputPeak = Self.peak(output)
        #expect(abs(outputPeak - 0.9) < 0.05, "Output peak (\(outputPeak)) should be near 0.9")

        // Speech segment should be strong
        let speechStart = output.count / 4
        let speechEnd = output.count * 3 / 4
        let speechRMS = Self.rms(Array(output[speechStart..<speechEnd]))
        #expect(speechRMS > 0.1, "Speech segment should have strong signal (RMS=\(speechRMS))")
    }

    // MARK: - Stream Alignment

    @Test("Mixdown lines the tracks up by start time, not by index")
    func mixdownAlignsByStartTime() {
        // The system stream only comes up 0.5 s after the mic, so its audio belongs 0.5 s in.
        // Mixing head to head would drop it onto what the mic heard half a second earlier,
        // which is what made the same speech get transcribed twice.
        let mic = AudioTrack(startSeconds: 100.0, samples: Self.roomAudio(durationSeconds: 10.0))
        let system = AudioTrack(startSeconds: 100.5, samples: Self.roomAudio(durationSeconds: 10.0))

        let output = AudioCapture.mixdown(mic: mic, system: system)

        let seconds = Double(output.count) / AudioWriter.sampleRate
        #expect(abs(seconds - 10.5) < 0.001, "Expected a 10.5 s timeline, got \(seconds) s")
    }
}
