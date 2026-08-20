import Foundation
import Testing
@testable import scribe

/// Tests for `AudioWriter`'s WAV writer and its fallback parser, covering the
/// header layout, the Float/Int16 conversions, and the malformed files the
/// parser has to survive.
@Suite("WAV File I/O")
struct WAVFileIOTests {

    // MARK: - Helpers

    /// Run a block against a temporary file path and clean it up afterwards.
    static func withTemporaryWAV(_ body: (String) throws -> Void) rethrows {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-wav-test-\(UUID().uuidString).wav")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    /// Assemble a WAV file by hand so tests can express malformed headers.
    /// `declaredDataSize` defaults to the real payload size.
    static func makeWAV(
        samples: [Int16],
        channels: UInt16 = 1,
        sampleRate: UInt32 = 16000,
        bitsPerSample: UInt16 = 16,
        audioFormat: UInt16 = 1,
        extraChunks: [(id: String, payload: Data)] = [],
        declaredDataSize: UInt32? = nil
    ) -> Data {
        var payload = Data()
        samples.forEach { payload.append(littleEndianBytes: $0) }

        var body = Data()
        body.append(contentsOf: "fmt ".utf8)
        body.append(littleEndianBytes: UInt32(16))
        body.append(littleEndianBytes: audioFormat)
        body.append(littleEndianBytes: channels)
        body.append(littleEndianBytes: sampleRate)
        body.append(littleEndianBytes: sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8))
        body.append(littleEndianBytes: channels * (bitsPerSample / 8))
        body.append(littleEndianBytes: bitsPerSample)

        for chunk in extraChunks {
            body.append(contentsOf: chunk.id.utf8)
            body.append(littleEndianBytes: UInt32(chunk.payload.count))
            body.append(chunk.payload)
        }

        body.append(contentsOf: "data".utf8)
        body.append(littleEndianBytes: declaredDataSize ?? UInt32(payload.count))
        body.append(payload)

        var file = Data()
        file.append(contentsOf: "RIFF".utf8)
        file.append(littleEndianBytes: UInt32(4 + body.count))
        file.append(contentsOf: "WAVE".utf8)
        file.append(body)
        return file
    }

    /// Write bytes to a temporary file and hand the URL to the block.
    static func withTemporaryFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try body(url)
    }

    static func readLE<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        data[offset..<offset + MemoryLayout<T>.size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    /// Widest gap the 16-bit quantization can open up in a write/read round trip.
    static let quantizationTolerance: Float = 1.0 / 16384.0

    // MARK: - Header

    @Test("Writer emits a 44-byte canonical PCM header")
    func writerEmitsCanonicalHeader() throws {
        try Self.withTemporaryWAV { path in
            let samples = [Float](repeating: 0.25, count: 800)
            try AudioWriter.writeWAV(samples: samples, to: path)

            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(data.count == 44 + samples.count * 2, "File should be header plus 16-bit payload")

            #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
            #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
            #expect(String(data: data[12..<16], encoding: .ascii) == "fmt ")
            #expect(String(data: data[36..<40], encoding: .ascii) == "data")

            let riffSize: UInt32 = Self.readLE(data, at: 4)
            let dataSize: UInt32 = Self.readLE(data, at: 40)
            #expect(riffSize == UInt32(data.count - 8), "RIFF size covers everything after the size field")
            #expect(dataSize == UInt32(samples.count * 2))

            let audioFormat: UInt16 = Self.readLE(data, at: 20)
            let channels: UInt16 = Self.readLE(data, at: 22)
            let rate: UInt32 = Self.readLE(data, at: 24)
            let byteRate: UInt32 = Self.readLE(data, at: 28)
            let blockAlign: UInt16 = Self.readLE(data, at: 32)
            let bits: UInt16 = Self.readLE(data, at: 34)
            #expect(audioFormat == 1)
            #expect(channels == 1)
            #expect(rate == 16000)
            #expect(byteRate == 32000)
            #expect(blockAlign == 2)
            #expect(bits == 16)
        }
    }

    @Test("Samples are written as little-endian Int16")
    func samplesAreLittleEndianInt16() throws {
        try Self.withTemporaryWAV { path in
            // 1.0 scales to 32767 (0x7FFF) and -1.0 to -32767 (0x8001)
            try AudioWriter.writeWAV(samples: [1.0, -1.0, 0.0], to: path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect([UInt8](data[44..<50]) == [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00])
        }
    }

    // MARK: - Round Trip

    @Test("Round trip preserves samples within quantization error")
    func roundTripPreservesSamples() throws {
        try Self.withTemporaryWAV { path in
            let samples = (0..<16000).map { sinf(2.0 * .pi * 440.0 * Float($0) / 16000.0) * 0.8 }
            try AudioWriter.writeWAV(samples: samples, to: path)
            let decoded = try AudioWriter.readRawWAV(from: URL(fileURLWithPath: path))

            #expect(decoded.count == samples.count)
            let worst = zip(samples, decoded).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < Self.quantizationTolerance, "Worst round-trip error was \(worst)")
        }
    }

    @Test("Round trip handles the boundary values")
    func roundTripHandlesBoundaries() throws {
        try Self.withTemporaryWAV { path in
            let samples: [Float] = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1e-6, -1e-6]
            try AudioWriter.writeWAV(samples: samples, to: path)
            let decoded = try AudioWriter.readRawWAV(from: URL(fileURLWithPath: path))

            #expect(decoded.count == samples.count)
            let worst = zip(samples, decoded).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < Self.quantizationTolerance, "Worst round-trip error was \(worst)")
        }
    }

    @Test("Out-of-range samples are clipped instead of wrapping")
    func outOfRangeSamplesAreClipped() throws {
        try Self.withTemporaryWAV { path in
            try AudioWriter.writeWAV(samples: [5.0, -5.0, 1.5, -1.5], to: path)
            let decoded = try AudioWriter.readRawWAV(from: URL(fileURLWithPath: path))

            #expect(decoded.count == 4)
            #expect(decoded[0] > 0.999 && decoded[1] < -0.999, "Clipping must not wrap the sign")
            #expect(decoded[2] > 0.999 && decoded[3] < -0.999)
        }
    }

    @Test("Empty input produces a header-only file that reads back as empty")
    func emptyInputRoundTrips() throws {
        try Self.withTemporaryWAV { path in
            try AudioWriter.writeWAV(samples: [], to: path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(data.count == 44)

            // The parser rejects a zero-length data chunk rather than returning nothing
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Parser

    @Test("Chunks before the data chunk are skipped")
    func extraChunksAreSkipped() throws {
        let samples: [Int16] = [0, 8192, -8192, 32767, -32768]
        let wav = Self.makeWAV(
            samples: samples,
            extraChunks: [
                ("LIST", Data(repeating: 0x20, count: 26)),
                ("FLLR", Data(repeating: 0x00, count: 4060)),
            ]
        )
        try Self.withTemporaryFile(wav) { url in
            let decoded = try AudioWriter.readRawWAV(from: url)
            #expect(decoded.count == samples.count)
            for (i, expected) in samples.enumerated() {
                #expect(decoded[i] == Float(expected) / 32768.0, "Sample \(i) mismatched")
            }
        }
    }

    @Test("An oversized data size yields silence instead of reading past the file")
    func oversizedDataSizeIsClamped() throws {
        let samples: [Int16] = (0..<64).map { Int16($0 * 500) }
        let realSize = UInt32(samples.count * 2)
        let wav = Self.makeWAV(samples: samples, declaredDataSize: realSize + 200)

        try Self.withTemporaryFile(wav) { url in
            let decoded = try AudioWriter.readRawWAV(from: url)
            #expect(decoded.count == Int(realSize + 200) / 2, "Length follows the declared size")
            for (i, expected) in samples.enumerated() {
                #expect(decoded[i] == Float(expected) / 32768.0, "Sample \(i) mismatched")
            }
            #expect(decoded[samples.count...].allSatisfy { $0 == 0 }, "Missing tail should be silent")
        }
    }

    @Test("A trailing half sample is ignored")
    func trailingHalfSampleIsIgnored() throws {
        let samples: [Int16] = (0..<32).map { Int16($0 * 1000) }
        var wav = Self.makeWAV(samples: samples, declaredDataSize: UInt32(samples.count * 2 + 1))
        wav.append(0x7F)

        try Self.withTemporaryFile(wav) { url in
            let decoded = try AudioWriter.readRawWAV(from: url)
            #expect(decoded.count == samples.count)
            for (i, expected) in samples.enumerated() {
                #expect(decoded[i] == Float(expected) / 32768.0, "Sample \(i) mismatched")
            }
        }
    }

    @Test("Interleaved channels are averaged into mono")
    func multiChannelIsMixedToMono() throws {
        // Frame n holds (left, right); the mono result should be their mean
        let interleaved: [Int16] = [1000, 3000, -2000, 2000, 32767, -32768, 0, 0]
        let wav = Self.makeWAV(samples: interleaved, channels: 2)

        try Self.withTemporaryFile(wav) { url in
            let decoded = try AudioWriter.readRawWAV(from: url)
            #expect(decoded.count == interleaved.count / 2)

            for frame in 0..<decoded.count {
                let left = Float(interleaved[frame * 2]) / 32768.0
                let right = Float(interleaved[frame * 2 + 1]) / 32768.0
                #expect(abs(decoded[frame] - (left + right) / 2) < 1e-6, "Frame \(frame) mismatched")
            }
        }
    }

    @Test("Three channels are averaged into mono")
    func threeChannelIsMixedToMono() throws {
        let interleaved: [Int16] = [3000, 6000, 9000, -1200, 0, 1200]
        let wav = Self.makeWAV(samples: interleaved, channels: 3)

        try Self.withTemporaryFile(wav) { url in
            let decoded = try AudioWriter.readRawWAV(from: url)
            #expect(decoded.count == 2)
            #expect(abs(decoded[0] - (3000 + 6000 + 9000) / 3.0 / 32768.0) < 1e-6)
            #expect(abs(decoded[1] - (-1200 + 0 + 1200) / 3.0 / 32768.0) < 1e-6)
        }
    }

    // MARK: - Malformed Input

    @Test("A zero bit depth is rejected rather than dividing by zero")
    func zeroBitDepthIsRejected() throws {
        let wav = Self.makeWAV(samples: [1, 2, 3, 4], bitsPerSample: 0, declaredDataSize: 8)
        try Self.withTemporaryFile(wav) { url in
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: url)
            }
        }
    }

    @Test(
        "Unsupported bit depths are rejected",
        arguments: [UInt16(8), UInt16(24), UInt16(32)]
    )
    func unsupportedBitDepthIsRejected(bits: UInt16) throws {
        let wav = Self.makeWAV(samples: [1, 2, 3, 4], bitsPerSample: bits)
        try Self.withTemporaryFile(wav) { url in
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: url)
            }
        }
    }

    @Test("Non-PCM files are rejected")
    func nonPCMIsRejected() throws {
        let wav = Self.makeWAV(samples: [1, 2, 3, 4], audioFormat: 3)
        try Self.withTemporaryFile(wav) { url in
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: url)
            }
        }
    }

    @Test("A file that is not RIFF/WAVE is rejected")
    func nonRIFFIsRejected() throws {
        let junk = Data(repeating: 0x5A, count: 128)
        try Self.withTemporaryFile(junk) { url in
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: url)
            }
        }
    }

    @Test("A file too short to hold a header is rejected")
    func truncatedHeaderIsRejected() throws {
        try Self.withTemporaryFile(Data(repeating: 0, count: 20)) { url in
            #expect(throws: AudioWriterError.self) {
                _ = try AudioWriter.readRawWAV(from: url)
            }
        }
    }

    // MARK: - Fixtures

    @Test(
        "The fallback parser agrees with AVAudioFile on the fixtures",
        arguments: ["sample_weather_ja", "sample_meeting_ja", "sample_thanks_ja"]
    )
    func fallbackParserMatchesAVAudioFile(fixture: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: fixture, withExtension: "wav", subdirectory: "Fixtures"),
            "Fixture \(fixture).wav is missing"
        )

        let parsed = try AudioWriter.readRawWAV(from: url)
        let viaAVFoundation = try AudioWriter.readWAV(from: url.path)

        #expect(parsed.count == viaAVFoundation.count, "Sample counts differ")
        let worst = zip(parsed, viaAVFoundation).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < Self.quantizationTolerance, "Worst per-sample difference was \(worst)")
    }
}

// MARK: - Test Helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndianBytes value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
