import Foundation
import Accelerate

/// Writes 16 kHz mono 16-bit WAV data incrementally.
///
/// The RIFF and data size fields are refreshed while the file grows, so a
/// recording that never reaches finalize() is still a playable WAV covering
/// everything written up to the last refresh.
final class StreamingWAVWriter {
    /// Size of the canonical RIFF/fmt/data header this writer emits.
    static let headerSize = 44

    let path: String
    private(set) var sampleCount = 0

    private let handle: FileHandle
    private let refreshInterval: Int
    private var samplesSinceRefresh = 0
    private var isFinalized = false

    /// - Parameter refreshInterval: samples to write before rewriting the header (default: 1 second).
    init(path: String, refreshInterval: Int = Int(AudioWriter.sampleRate)) throws {
        self.path = path
        self.refreshInterval = max(1, refreshInterval)

        guard FileManager.default.createFile(atPath: path, contents: Self.header(dataSize: 0)) else {
            throw AudioWriterError.fileCreationFailed(path)
        }

        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - Writing

    func append(_ samples: [Float]) throws {
        try append(samples[...])
    }

    func append(_ samples: ArraySlice<Float>) throws {
        guard !isFinalized, !samples.isEmpty else { return }

        try handle.write(contentsOf: Self.encode(samples))
        sampleCount += samples.count
        samplesSinceRefresh += samples.count

        if samplesSinceRefresh >= refreshInterval {
            try refreshHeader()
            samplesSinceRefresh = 0
        }
    }

    /// Write the final sizes and close the file. Further appends are ignored.
    func finalize() throws {
        guard !isFinalized else { return }
        isFinalized = true

        try refreshHeader()
        try handle.close()
    }

    // MARK: - Private

    /// Rewrite the two size fields in place, then flush so a power loss keeps what was written.
    private func refreshHeader() throws {
        let dataSize = UInt32(sampleCount * MemoryLayout<Int16>.size)
        let end = try handle.offset()

        var riffSize = Data()
        riffSize.append(littleEndian: UInt32(Self.headerSize - 8) + dataSize)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: riffSize)

        var chunkSize = Data()
        chunkSize.append(littleEndian: dataSize)
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: chunkSize)

        try handle.seek(toOffset: end)
        try handle.synchronize()
    }

    static func header(dataSize: UInt32) -> Data {
        let numChannels = UInt16(AudioWriter.channels)
        let bitsPerSample: UInt16 = 16
        let sampleRateInt = UInt32(AudioWriter.sampleRate)
        let byteRate = sampleRateInt * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var data = Data(capacity: headerSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: UInt32(headerSize - 8) + dataSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))       // chunk size
        data.append(littleEndian: UInt16(1))        // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: sampleRateInt)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        return data
    }

    /// Convert Float [-1, 1] samples to little-endian 16-bit PCM bytes.
    static func encode(_ samples: ArraySlice<Float>) -> Data {
        let count = samples.count
        var scaled = [Float](repeating: 0, count: count)

        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            var lowerBound: Float = -1.0
            var upperBound: Float = 1.0
            vDSP_vclip(base, 1, &lowerBound, &upperBound, &scaled, 1, vDSP_Length(count))
        }

        var scale: Float = 32767.0
        scaled.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(count))
        }

        var pcm = [Int16](repeating: 0, count: count)
        scaled.withUnsafeBufferPointer { source in
            pcm.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                // The clip above bounds this to Int16's representable range.
                vDSP_vfix16(sourceBase, 1, destinationBase, 1, vDSP_Length(count))
            }
        }

        return pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
