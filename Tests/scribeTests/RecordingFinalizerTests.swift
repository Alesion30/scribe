import Foundation
import Testing
import Accelerate
@testable import scribe

/// Tests for the post-capture path: mixing the per-source recordings into the
/// final WAV must produce what the old in-memory pipeline produced.
@Suite("Recording Finalizer")
struct RecordingFinalizerTests {

    // MARK: - Helpers

    static func withTemporaryDirectory<T>(_ body: (String) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.path)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(samples, 1, &sumSq, vDSP_Length(samples.count))
        return sqrtf(sumSq / Float(samples.count))
    }

    static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    static func tone(frequency: Float, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { i in
            amplitude * sinf(2.0 * .pi * frequency * Float(i) / Float(AudioWriter.sampleRate))
        }
    }

    /// Loud bursts over a quiet floor, so the noise gate has something to act on.
    static func speechLike(count: Int) -> [Float] {
        let loud = tone(frequency: 440, amplitude: 0.4, count: count)
        let quiet = tone(frequency: 90, amplitude: 0.006, count: count)
        return (0..<count).map { i in
            // 0.5s of speech followed by 0.5s of room tone
            (i / 8000) % 2 == 0 ? loud[i] : quiet[i]
        }
    }

    /// Write a source recording the way SourceRecorder does, stats included.
    static func writeSource(_ samples: [Float], to path: String, startSeconds: Double? = nil) throws -> CapturedSource {
        let writer = try StreamingWAVWriter(path: path)
        try writer.append(samples)
        try writer.finalize()

        return CapturedSource(
            path: path,
            sampleCount: samples.count,
            peak: peak(samples),
            rms: rms(samples),
            startSeconds: startSeconds
        )
    }

    /// The pipeline stopCapture() ran before the sources were streamed to disk.
    static func referenceMix(mic: [Float], system: [Float]) -> [Float] {
        var resampledMic = mic
        var resampledSystem = system

        if rms(resampledSystem) < 0.01 { resampledSystem = [] }
        if rms(resampledMic) < 0.01 { resampledMic = [] }

        if !resampledMic.isEmpty {
            resampledMic = AudioWriter.normalize(resampledMic, targetPeak: 0.5)
        }
        if !resampledSystem.isEmpty {
            resampledSystem = AudioWriter.normalize(resampledSystem, targetPeak: 0.5)
        }

        let mixed: [Float]
        if !resampledMic.isEmpty && !resampledSystem.isEmpty {
            mixed = AudioWriter.mix(resampledMic, resampledSystem)
        } else if !resampledMic.isEmpty {
            mixed = resampledMic
        } else if !resampledSystem.isEmpty {
            mixed = resampledSystem
        } else {
            return []
        }

        return AudioWriter.normalize(AudioWriter.reduceNoise(from: mixed))
    }

    static func maxDelta(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var delta: Float = 0
        for i in 0..<min(lhs.count, rhs.count) {
            delta = max(delta, abs(lhs[i] - rhs[i]))
        }
        return delta
    }

    // MARK: - Behavior parity

    @Test("Mixing from disk matches the in-memory pipeline")
    func mixMatchesReference() throws {
        let mic = Self.speechLike(count: 48000)
        let system = Self.tone(frequency: 220, amplitude: 0.6, count: 48000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic),
                system: try Self.writeSource(system, to: paths.system)
            )

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)
            let expected = Self.referenceMix(mic: mic, system: system)

            #expect(mixed.count == expected.count)
            // Only 16-bit quantization of the source files separates the two paths.
            #expect(Self.maxDelta(mixed, expected) < 0.01, "drifted by \(Self.maxDelta(mixed, expected))")
        }
    }

    @Test("Single source matches the in-memory pipeline")
    func singleSourceMatchesReference() throws {
        let mic = Self.speechLike(count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(mic: try Self.writeSource(mic, to: paths.mic), system: nil)

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)
            let expected = Self.referenceMix(mic: mic, system: [])

            #expect(mixed.count == expected.count)
            #expect(Self.maxDelta(mixed, expected) < 0.01, "drifted by \(Self.maxDelta(mixed, expected))")
        }
    }

    @Test("Near-silent source is excluded from the mix")
    func nearSilentSourceExcluded() throws {
        let mic = Self.speechLike(count: 32000)
        let system = Self.tone(frequency: 1000, amplitude: 0.002, count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic),
                system: try Self.writeSource(system, to: paths.system)
            )

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)
            let expected = Self.referenceMix(mic: mic, system: system)

            #expect(Self.maxDelta(mixed, expected) < 0.01)
        }
    }

    @Test("Sources of different lengths are padded with silence")
    func unevenSourcesPadded() throws {
        let mic = Self.tone(frequency: 440, amplitude: 0.5, count: 40000)
        let system = Self.tone(frequency: 220, amplitude: 0.5, count: 16000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic),
                system: try Self.writeSource(system, to: paths.system)
            )

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)

            #expect(mixed.count == 40000)
            #expect(Self.maxDelta(mixed, Self.referenceMix(mic: mic, system: system)) < 0.01)
        }
    }

    // MARK: - Stream alignment

    @Test("A source that started later is held back by the difference")
    func laterSourceIsDelayed() throws {
        let mic = Self.tone(frequency: 440, amplitude: 0.5, count: 32000)
        let system = Self.tone(frequency: 220, amplitude: 0.5, count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic, startSeconds: 100.0),
                system: try Self.writeSource(system, to: paths.system, startSeconds: 100.5)
            )

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)

            // 2 s of mic plus the half second the system stream came up late.
            #expect(mixed.count == 40000, "expected 40000 samples, got \(mixed.count)")
            // The system tone only starts once its lead-in has played out.
            #expect(Self.rms(Array(mixed[0..<8000])) < Self.rms(Array(mixed[8000..<32000])))
        }
    }

    @Test("Sources are left where they are when one carries no timestamps")
    func unstampedSourceIsNotDelayed() throws {
        let mic = Self.tone(frequency: 440, amplitude: 0.5, count: 32000)
        let system = Self.tone(frequency: 220, amplitude: 0.5, count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic, startSeconds: 100.0),
                system: try Self.writeSource(system, to: paths.system, startSeconds: nil)
            )

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)

            #expect(mixed.count == 32000, "expected 32000 samples, got \(mixed.count)")
        }
    }

    @Test("Lead-in silence is measured from the earliest source")
    func leadSamplesMeasuredFromEarliest() {
        let sources = [
            CapturedSource(path: "a", sampleCount: 16000, peak: 1, rms: 1, startSeconds: 100.5),
            CapturedSource(path: "b", sampleCount: 16000, peak: 1, rms: 1, startSeconds: 100.0),
            CapturedSource(path: "c", sampleCount: 16000, peak: 1, rms: 1, startSeconds: 101.0)
        ]

        #expect(RecordingFinalizer.leadSamples(for: sources) == [8000, 0, 16000])
    }

    // MARK: - File handling

    @Test("Source files are removed once the output is written")
    func sourceFilesRemoved() throws {
        let mic = Self.speechLike(count: 32000)
        let system = Self.tone(frequency: 1000, amplitude: 0.002, count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(
                mic: try Self.writeSource(mic, to: paths.mic),
                system: try Self.writeSource(system, to: paths.system)
            )

            _ = try RecordingFinalizer.finalize(result, to: paths.output)

            #expect(FileManager.default.fileExists(atPath: paths.output))
            // The excluded system source is cleaned up too.
            #expect(!FileManager.default.fileExists(atPath: paths.mic))
            #expect(!FileManager.default.fileExists(atPath: paths.system))
        }
    }

    @Test("Output is readable back as 16 kHz mono")
    func outputRoundTrips() throws {
        let mic = Self.speechLike(count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(mic: try Self.writeSource(mic, to: paths.mic), system: nil)

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)
            let read = try AudioWriter.readWAV(from: paths.output)

            #expect(read.count == mixed.count)
            #expect(Self.maxDelta(read, mixed) < 0.001)
        }
    }

    @Test("Sources are kept when everything is near-silent")
    func silentRecordingKeepsSources() throws {
        let mic = Self.tone(frequency: 440, amplitude: 0.001, count: 32000)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let result = CaptureResult(mic: try Self.writeSource(mic, to: paths.mic), system: nil)

            let mixed = try RecordingFinalizer.finalize(result, to: paths.output)

            #expect(mixed.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: paths.output))
            #expect(FileManager.default.fileExists(atPath: paths.mic), "a silent recording must not be deleted")
        }
    }

    @Test("Nothing captured produces no output")
    func nothingCaptured() throws {
        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))

            let mixed = try RecordingFinalizer.finalize(CaptureResult(mic: nil, system: nil), to: paths.output)

            #expect(mixed.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: paths.output))
        }
    }

    // MARK: - Capture to output

    @Test("A streamed source flows through to the final mix")
    func recorderFeedsFinalizer() throws {
        // 1 second of 48 kHz stereo, as the capture callbacks deliver it.
        let frames = 48000
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = 0.5 * sinf(2.0 * .pi * 440.0 * Float(frame) / 48000.0)
            interleaved[frame * 2] = value
            interleaved[frame * 2 + 1] = value
        }

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let recorder = try SourceRecorder(label: "Mic", path: paths.mic, sampleRate: 48000, channels: 2)

            var offset = 0
            while offset < interleaved.count {
                let end = min(offset + 4096 * 2, interleaved.count)
                recorder.append(Array(interleaved[offset..<end]))
                offset = end
            }

            let source = try #require(recorder.finish())
            #expect(abs(source.sampleCount - 16000) < 200, "expected ~1s at 16 kHz, got \(source.sampleCount)")
            #expect(abs(source.peak - 0.5) < 0.05)
            #expect(abs(source.rms - 0.354) < 0.02)

            let mixed = try RecordingFinalizer.finalize(CaptureResult(mic: source, system: nil), to: paths.output)
            #expect(mixed.count == source.sampleCount)
            #expect(!FileManager.default.fileExists(atPath: paths.mic))
            #expect(FileManager.default.fileExists(atPath: paths.output))
        }
    }

    @Test("A dropped buffer is restored as silence")
    func recorderFillsDroppedBuffers() throws {
        // 0.1 s chunks of 16 kHz mono, with the one covering 0.2-0.3 s never delivered.
        let chunk = Self.tone(frequency: 440, amplitude: 0.5, count: 1600)

        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let recorder = try SourceRecorder(label: "Mic", path: paths.mic, sampleRate: 16000, channels: 1)

            recorder.append(chunk, startingAt: 100.0)
            recorder.append(chunk, startingAt: 100.1)
            recorder.append(chunk, startingAt: 100.3)

            let source = try #require(recorder.finish())

            // The three delivered chunks, plus the hole the missing one left.
            #expect(source.sampleCount == 6400, "expected 6400 samples, got \(source.sampleCount)")
            #expect(source.startSeconds == 100.0)
        }
    }

    @Test("An empty source leaves no file behind")
    func emptyRecorderCleansUp() throws {
        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let recorder = try SourceRecorder(label: "Mic", path: paths.mic, sampleRate: 48000, channels: 1)

            #expect(recorder.finish() == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.mic))
        }
    }

    @Test("A discarded source leaves no file behind")
    func discardedRecorderCleansUp() throws {
        try Self.withTemporaryDirectory { dir in
            let paths = RecordingPaths(output: (dir as NSString).appendingPathComponent("out.wav"))
            let recorder = try SourceRecorder(label: "Mic", path: paths.mic, sampleRate: 48000, channels: 1)

            recorder.append(Self.tone(frequency: 440, amplitude: 0.5, count: 4800))
            recorder.discard()

            #expect(!FileManager.default.fileExists(atPath: paths.mic))
        }
    }

    // MARK: - Paths

    @Test("Source paths sit next to the output")
    func sourcePathsDerived() {
        let paths = RecordingPaths(output: "/tmp/recordings/2025-01-15_14-30-00.wav")

        #expect(paths.mic == "/tmp/recordings/2025-01-15_14-30-00.mic.wav")
        #expect(paths.system == "/tmp/recordings/2025-01-15_14-30-00.system.wav")
    }

    @Test("Missing output directory is created up front")
    func outputDirectoryCreated() throws {
        try Self.withTemporaryDirectory { dir in
            let nested = (dir as NSString).appendingPathComponent("a/b/c")
            let paths = RecordingPaths(output: (nested as NSString).appendingPathComponent("out.wav"))

            try paths.prepareDirectory()

            #expect(FileManager.default.fileExists(atPath: nested))
        }
    }
}
