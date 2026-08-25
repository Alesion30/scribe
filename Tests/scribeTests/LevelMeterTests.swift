import Foundation
import Testing
import Accelerate
@testable import scribe

/// Tests for the level statistic the mix decisions are made from.
///
/// The property that matters throughout is that the reported level describes how loud the source
/// gets, not how much of the session it spends getting there — an overall RMS confuses the two.
@Suite("Level Meter")
struct LevelMeterTests {

    // MARK: - Helpers

    static func tone(amplitude: Float, seconds: Double, frequency: Float = 300) -> [Float] {
        let count = Int(AudioWriter.sampleRate * seconds)
        return (0..<count).map { i in
            amplitude * sinf(2.0 * .pi * frequency * Float(i) / Float(AudioWriter.sampleRate))
        }
    }

    /// Built by repeating one block: drawing ten minutes of samples one at a time dominates the suite.
    static func silence(seconds: Double, amplitude: Float = 0) -> [Float] {
        let count = Int(AudioWriter.sampleRate * seconds)
        guard amplitude > 0 else { return [Float](repeating: 0, count: count) }

        let block = (0..<LevelMeter.windowSamples).map { _ in Float.random(in: -amplitude...amplitude) }
        var samples = [Float]()
        samples.reserveCapacity(count)
        while samples.count < count {
            samples.append(contentsOf: block.prefix(count - samples.count))
        }
        return samples
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        return sqrtf(sumSquares / Float(samples.count))
    }

    /// Relative error, so expectations can be written against the quantization the bins impose.
    static func error(_ measured: Float, _ expected: Float) -> Float {
        abs(measured - expected) / expected
    }

    // MARK: - Accuracy

    @Test("A steady tone measures at its RMS")
    func steadyToneMeasuresAtItsRMS() {
        let samples = Self.tone(amplitude: 0.4, seconds: 5)
        let level = LevelMeter.activeLevel(of: samples)

        // 0.25 dB bins put the worst case at 1.5%.
        #expect(Self.error(level, Self.rms(samples)) < 0.02, "measured \(level), expected \(Self.rms(samples))")
    }

    @Test("Digital silence measures as no signal")
    func digitalSilenceMeasuresAsNothing() {
        #expect(LevelMeter.activeLevel(of: Self.silence(seconds: 5)) == 0)
    }

    @Test("Empty input measures as no signal")
    func emptyInputMeasuresAsNothing() {
        #expect(LevelMeter.activeLevel(of: []) == 0)
    }

    @Test("A recording shorter than one window still measures")
    func shorterThanOneWindowStillMeasures() {
        let samples = Array(Self.tone(amplitude: 0.4, seconds: 1).prefix(LevelMeter.windowSamples / 2))
        #expect(LevelMeter.activeLevel(of: samples) > 0)
    }

    // MARK: - Streaming

    @Test("Chunking the input does not change the level", arguments: [1, 7, 320, 999, 4096])
    func chunkingDoesNotChangeTheLevel(chunk: Int) {
        let samples = Self.tone(amplitude: 0.25, seconds: 3)

        var meter = LevelMeter()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            meter.add(Array(samples[offset..<end]))
            offset = end
        }
        meter.finalize()

        #expect(Self.error(meter.activeLevel, LevelMeter.activeLevel(of: samples)) < 0.02)
    }

    // MARK: - The properties the mix decisions rely on

    @Test("Padding a recording with silence does not change its level")
    func silenceDoesNotDiluteTheLevel() {
        let speech = Self.tone(amplitude: 0.1, seconds: 2)
        let short = speech + Self.silence(seconds: 2, amplitude: 0.001)
        let long = speech + Self.silence(seconds: 600, amplitude: 0.001)

        // The whole point: a ten-minute meeting with two seconds of talking still reports speech.
        #expect(Self.error(LevelMeter.activeLevel(of: long), LevelMeter.activeLevel(of: short)) < 0.02)
    }

    @Test("Overall RMS collapses where the active level holds")
    func overallRMSCollapsesWhereActiveLevelHolds() {
        let speech = Self.tone(amplitude: 0.1, seconds: 2)
        let long = speech + Self.silence(seconds: 600, amplitude: 0.001)

        // Guards the premise of the fix: the statistic that was used before really does collapse.
        #expect(Self.rms(long) < Self.rms(speech) / 10)
        #expect(LevelMeter.activeLevel(of: long) > 0.05)
    }

    @Test("A single click does not pass for speech")
    func singleClickDoesNotPassForSpeech() {
        var room = Self.silence(seconds: 30, amplitude: 0.002)
        // One slammed door: full scale, but far shorter than the span the level is read across.
        for i in 0..<(LevelMeter.windowSamples * 2) {
            room[16000 + i] = i.isMultiple(of: 2) ? 1.0 : -1.0
        }

        #expect(LevelMeter.activeLevel(of: room) < RecordingFinalizer.silenceLevelThreshold,
                "a click measured \(LevelMeter.activeLevel(of: room))")
    }

    @Test("A click does not lift the level of speech either")
    func clickDoesNotLiftSpeechLevel() {
        let speech = Self.tone(amplitude: 0.1, seconds: 10)
        var withClick = speech
        for i in 0..<(LevelMeter.windowSamples * 2) {
            withClick[16000 + i] = i.isMultiple(of: 2) ? 1.0 : -1.0
        }

        #expect(Self.error(LevelMeter.activeLevel(of: withClick), LevelMeter.activeLevel(of: speech)) < 0.02)
    }
}
