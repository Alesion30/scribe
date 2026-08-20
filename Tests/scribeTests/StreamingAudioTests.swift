import Foundation
import Testing
import Accelerate
@testable import scribe

/// Tests for the streaming capture primitives: incremental WAV writing and
/// chunk-by-chunk resampling.
@Suite("Streaming Audio")
struct StreamingAudioTests {

    // MARK: - Helpers

    static func withTemporaryDirectory<T>(_ body: (String) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.path)
    }

    static func sineWave(frequency: Float, amplitude: Float, count: Int, sampleRate: Float) -> [Float] {
        (0..<count).map { i in
            amplitude * sinf(2.0 * .pi * frequency * Float(i) / sampleRate)
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(samples, 1, &sumSq, vDSP_Length(samples.count))
        return sqrtf(sumSq / Float(samples.count))
    }

    // MARK: - StreamingWAVWriter

    @Test("Chunked writes round-trip through readWAV")
    func chunkedWriteRoundTrip() throws {
        let samples = Self.sineWave(frequency: 440, amplitude: 0.5, count: 16000, sampleRate: 16000)

        try Self.withTemporaryDirectory { dir in
            let path = (dir as NSString).appendingPathComponent("chunked.wav")
            let writer = try StreamingWAVWriter(path: path)

            var offset = 0
            while offset < samples.count {
                let end = min(offset + 1000, samples.count)
                try writer.append(samples[offset..<end])
                offset = end
            }
            try writer.finalize()

            #expect(writer.sampleCount == samples.count)

            let read = try AudioWriter.readWAV(from: path)
            #expect(read.count == samples.count)

            var maxDelta: Float = 0
            for i in 0..<min(read.count, samples.count) {
                maxDelta = max(maxDelta, abs(read[i] - samples[i]))
            }
            #expect(maxDelta < 0.001, "16-bit round-trip drifted by \(maxDelta)")
        }
    }

    @Test("Chunked writes match writeWAV byte for byte")
    func chunkedWriteMatchesOneShot() throws {
        let samples = Self.sineWave(frequency: 220, amplitude: 0.8, count: 8000, sampleRate: 16000)

        try Self.withTemporaryDirectory { dir in
            let streamed = (dir as NSString).appendingPathComponent("streamed.wav")
            let writer = try StreamingWAVWriter(path: streamed)
            try writer.append(samples[0..<3000])
            try writer.append(samples[3000..<8000])
            try writer.finalize()

            let oneShot = (dir as NSString).appendingPathComponent("oneshot.wav")
            try AudioWriter.writeWAV(samples: samples, to: oneShot)

            let a = try Data(contentsOf: URL(fileURLWithPath: streamed))
            let b = try Data(contentsOf: URL(fileURLWithPath: oneShot))
            #expect(a == b)
        }
    }

    @Test("File is readable before finalize (crash mid-recording)")
    func readableBeforeFinalize() throws {
        let samples = Self.sineWave(frequency: 440, amplitude: 0.5, count: 4000, sampleRate: 16000)

        try Self.withTemporaryDirectory { dir in
            let path = (dir as NSString).appendingPathComponent("partial.wav")
            let writer = try StreamingWAVWriter(path: path, refreshInterval: 1000)

            var offset = 0
            while offset < samples.count {
                let end = min(offset + 500, samples.count)
                try writer.append(samples[offset..<end])
                offset = end
            }

            // No finalize() — the last header refresh must still describe a valid file.
            let read = try AudioWriter.readWAV(from: path)
            #expect(read.count == samples.count)
            #expect(Self.rms(read) > 0.3)
        }
    }

    @Test("Empty recording produces a valid zero-length WAV")
    func emptyRecording() throws {
        try Self.withTemporaryDirectory { dir in
            let path = (dir as NSString).appendingPathComponent("empty.wav")
            let writer = try StreamingWAVWriter(path: path)
            try writer.append([])
            try writer.finalize()

            #expect(writer.sampleCount == 0)

            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            #expect(size == StreamingWAVWriter.headerSize)
        }
    }

    // MARK: - StreamingResampler

    @Test("Chunked resampling matches one-shot resampling")
    func chunkedResampleMatchesOneShot() throws {
        // 1 second of 48 kHz stereo, both channels carrying the same tone.
        let frames = 48000
        var interleaved = [Float](repeating: 0, count: frames * 2)
        let tone = Self.sineWave(frequency: 440, amplitude: 0.6, count: frames, sampleRate: 48000)
        for frame in 0..<frames {
            interleaved[frame * 2] = tone[frame]
            interleaved[frame * 2 + 1] = tone[frame]
        }

        let resampler = try #require(StreamingResampler(sampleRate: 48000, channels: 2))

        var streamed: [Float] = []
        var offset = 0
        while offset < interleaved.count {
            let end = min(offset + 4096 * 2, interleaved.count)
            let chunk = Array(interleaved[offset..<end])
            streamed.append(contentsOf: try #require(resampler.resample(chunk)))
            offset = end
        }

        let oneShot = try #require(AudioWriter.resample(interleaved, fromRate: 48000, channels: 2))

        // Converter latency shifts the streamed output slightly; length and level should still line up.
        #expect(abs(streamed.count - oneShot.count) < 200, "\(streamed.count) vs \(oneShot.count)")
        #expect(abs(Self.rms(streamed) - Self.rms(oneShot)) < 0.02)
    }

    @Test("Chunk boundaries do not drop or duplicate audio")
    func chunkBoundariesPreserveDuration() throws {
        let frames = 48000
        let tone = Self.sineWave(frequency: 300, amplitude: 0.5, count: frames, sampleRate: 48000)
        let resampler = try #require(StreamingResampler(sampleRate: 48000, channels: 1))

        var streamed: [Float] = []
        var offset = 0
        while offset < tone.count {
            // Deliberately uneven chunks, as the capture callbacks deliver them.
            let size = (offset / 4096) % 2 == 0 ? 1024 : 4096
            let end = min(offset + size, tone.count)
            streamed.append(contentsOf: try #require(resampler.resample(Array(tone[offset..<end]))))
            offset = end
        }

        #expect(abs(streamed.count - 16000) < 200, "expected ~1 second at 16 kHz, got \(streamed.count)")
        #expect(Self.rms(streamed) > 0.3)
    }

    @Test("16 kHz mono input passes through untouched")
    func passthroughFormat() throws {
        let samples = Self.sineWave(frequency: 440, amplitude: 0.5, count: 1600, sampleRate: 16000)
        let resampler = try #require(StreamingResampler(sampleRate: 16000, channels: 1))

        let output = try #require(resampler.resample(samples))
        #expect(output == samples)
    }

    @Test("Invalid source format is rejected")
    func invalidFormatRejected() {
        #expect(StreamingResampler(sampleRate: 0, channels: 1) == nil)
        #expect(StreamingResampler(sampleRate: 48000, channels: 0) == nil)
    }
}
