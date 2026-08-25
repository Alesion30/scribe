import Foundation
import Accelerate

// MARK: - Recording Layout

/// File layout of one recording session.
///
/// Each source is written to its own file while recording, because the mix
/// gains can only be chosen once both sources are complete. The source files
/// are removed as soon as `output` has been written.
struct RecordingPaths {
    let output: String

    var mic: String { sourcePath(suffix: "mic") }
    var system: String { sourcePath(suffix: "system") }

    /// Create the directory holding the recording, so capture fails before recording rather than after.
    func prepareDirectory() throws {
        let directory = (output as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func sourcePath(suffix: String) -> String {
        "\((output as NSString).deletingPathExtension).\(suffix).wav"
    }
}

/// A capture source on disk, with the levels needed to decide how to mix it.
struct CapturedSource {
    let path: String
    let sampleCount: Int
    let peak: Float
    let rms: Float
    /// Level the source speaks at, independent of how much of the session was silence.
    let activeLevel: Float
    /// Host-clock instant of the first sample, or nil when no buffer carried a timestamp.
    let startSeconds: Double?
}

struct CaptureResult {
    let mic: CapturedSource?
    let system: CapturedSource?

    var sources: [CapturedSource] { [mic, system].compactMap(\.self) }
}

// MARK: - Finalizer

/// Turns the per-source recordings into the final mixed WAV.
enum RecordingFinalizer {
    /// Sources that never speak above this are left out of the mix entirely.
    /// Prevents amplifying system noise during offline meetings
    /// (where no meaningful system audio exists) and vice versa.
    ///
    /// Sits between room tone and speech: a quiet room meters around -57 dBFS, and even a
    /// microphone whose input level is set low reaches -38 dBFS once someone talks.
    static let silenceLevelThreshold: Float = 0.003

    /// Level each source is brought to before mixing, so a quiet mic doesn't get buried.
    static let mixTargetLevel: Float = 0.08

    /// Ceiling the mix gain is held under, leaving both sources room to sum without clipping.
    static let mixPeakCeiling: Float = 0.7

    /// Samples mixed per iteration. Bounds the working set, not the result.
    static let chunkSize = 1 << 16

    /// Mix, denoise and normalize the captured sources into `outputPath`.
    ///
    /// Returns the processed samples, or an empty array when there is nothing
    /// worth transcribing. Source files are kept when the result is empty so a
    /// misjudged silence threshold can't destroy a recording.
    static func finalize(_ result: CaptureResult, to outputPath: String) throws -> [Float] {
        guard !result.sources.isEmpty else {
            Log.warning("No audio samples captured")
            return []
        }

        let mic = includeIfAudible(result.mic, label: "Mic")
        let system = includeIfAudible(result.system, label: "System")
        let active = [mic, system].compactMap(\.self)

        guard !active.isEmpty else {
            Log.warning("Every source was near-silent; keeping the source recordings:")
            for source in result.sources {
                Log.status("  \(source.path) (level=\(String(format: "%.5f", source.activeLevel)), peak=\(String(format: "%.4f", source.peak)))")
            }
            return []
        }

        if let micStart = mic?.startSeconds, let systemStart = system?.startSeconds {
            Log.debug("System audio starts \(String(format: "%+.3f", systemStart - micStart))s relative to the mic")
        }

        var mixed = try mix(active, clipping: active.count > 1)
        Log.debug("Mixed audio: \(mixed.count) samples")

        // Reduce background noise before amplification
        AudioWriter.reduceNoise(inPlace: &mixed)

        // Normalize volume (peak → 0.9 to leave headroom)
        AudioWriter.normalize(inPlace: &mixed, targetPeak: 0.9)

        let duration = Double(mixed.count) / AudioWriter.sampleRate
        Log.info("Final audio: \(mixed.count) samples (\(String(format: "%.1f", duration))s)")

        try AudioWriter.writeWAV(samples: mixed, to: outputPath)

        for source in result.sources {
            try? FileManager.default.removeItem(atPath: source.path)
        }

        return mixed
    }

    // MARK: - Private

    private static func includeIfAudible(_ source: CapturedSource?, label: String) -> CapturedSource? {
        guard let source else { return nil }

        guard source.activeLevel >= silenceLevelThreshold else {
            Log.info("\(label) audio is near-silent (level=\(String(format: "%.5f", source.activeLevel))), excluding from mix")
            return nil
        }

        Log.debug("\(label) audio level: \(String(format: "%.5f", source.activeLevel)) (overall RMS \(String(format: "%.5f", source.rms)))")
        return source
    }

    /// Gain that brings a source's speaking level to the mix target.
    ///
    /// Matched on the speaking level rather than the peak so that one cough or table knock
    /// cannot decide the gain for the whole recording and bury everything that was said.
    static func mixGain(for source: CapturedSource) -> Float {
        guard source.activeLevel > 0 else { return 1.0 }

        let gain = mixTargetLevel / source.activeLevel
        guard source.peak > 0 else { return gain }
        return min(gain, mixPeakCeiling / source.peak)
    }

    /// Silence each source needs at the front so they line up on the host clock.
    ///
    /// The two capture APIs never start together — ScreenCaptureKit needs an await round trip the
    /// microphone does not — so mixing them head to head lays one source's audio over what the other
    /// heard moments earlier, and whisper transcribes the same speech twice. Sources stay where they
    /// are unless every one of them is stamped: an unstamped source has nothing to line up against.
    static func leadSamples(for sources: [CapturedSource]) -> [Int] {
        let stamps = sources.compactMap(\.startSeconds)
        guard stamps.count == sources.count, let origin = stamps.min() else {
            return Array(repeating: 0, count: sources.count)
        }

        return stamps.map { max(0, Int((($0 - origin) * AudioWriter.sampleRate).rounded())) }
    }

    /// Sum sources chunk by chunk, each one held at the offset the host clock gives it.
    private static func mix(_ sources: [CapturedSource], clipping: Bool) throws -> [Float] {
        let offsets = leadSamples(for: sources)
        let length = zip(sources, offsets).map { $0.sampleCount + $1 }.max() ?? 0
        let readers = try sources.map { try SourceFileReader($0) }
        defer { readers.forEach { $0.close() } }

        let gains = sources.map(mixGain(for:))

        var mixed = [Float]()
        mixed.reserveCapacity(length)

        var written = 0
        while written < length {
            let count = min(chunkSize, length - written)
            var accumulator = [Float](repeating: 0, count: count)

            for ((reader, gain), offset) in zip(zip(readers, gains), offsets) {
                let padding = max(0, offset - written)
                let available = count - padding
                guard available > 0 else { continue }
                var samples = try reader.read(available)
                guard !samples.isEmpty else { continue }
                if gain != 1.0 {
                    AudioWriter.applyGain(gain, to: &samples)
                }
                add(samples, into: &accumulator, at: padding)
            }

            if clipping {
                clamp(&accumulator)
            }

            mixed.append(contentsOf: accumulator)
            written += count
        }

        return mixed
    }

    private static func add(_ samples: [Float], into accumulator: inout [Float], at offset: Int = 0) {
        let count = min(samples.count, accumulator.count - offset)
        guard count > 0 else { return }

        accumulator.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return }
                vDSP_vadd(destinationBase + offset, 1, sourceBase, 1, destinationBase + offset, 1, vDSP_Length(count))
            }
        }
    }

    private static func clamp(_ samples: inout [Float]) {
        var lowerBound: Float = -1.0
        var upperBound: Float = 1.0

        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vclip(base, 1, &lowerBound, &upperBound, base, 1, vDSP_Length(buffer.count))
        }
    }
}

// MARK: - Source File Reader

/// Sequential reader for the 16 kHz mono files StreamingWAVWriter produces.
private final class SourceFileReader {
    private let handle: FileHandle
    private var remaining: Int

    init(_ source: CapturedSource) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
        remaining = source.sampleCount
        try handle.seek(toOffset: UInt64(StreamingWAVWriter.headerSize))
    }

    /// Read up to `count` samples. Returns fewer (or none) once the file runs out.
    func read(_ count: Int) throws -> [Float] {
        let wanted = min(count, remaining)
        guard wanted > 0 else { return [] }

        guard let data = try handle.read(upToCount: wanted * MemoryLayout<Int16>.size), !data.isEmpty else {
            remaining = 0
            return []
        }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        remaining -= sampleCount

        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let value = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                samples[i] = Float(Int16(littleEndian: value)) / 32768.0
            }
        }

        return samples
    }

    func close() {
        try? handle.close()
    }
}
