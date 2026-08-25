import Foundation
import Accelerate

/// Level distribution of one capture source, accumulated in constant memory.
///
/// Whether a source carries speech cannot be read from its overall RMS: speech is sparse, so the
/// same voice measures quieter the longer the session runs, and a meeting's worth of pauses drags
/// a perfectly audible microphone below any fixed threshold. Short windows are binned by level
/// instead, and the loud end of that distribution is read back as the level the source speaks at.
struct LevelMeter {
    /// Window the level is measured over, short enough to separate speech from the gaps inside it.
    static let windowSeconds: Double = 0.02

    /// How much of the loudest audio the active level is read across.
    ///
    /// Taken as an order statistic halfway down this span, so a single slammed door cannot pass for
    /// speech while speech stays visible however small a fraction of the session it fills.
    static let activeSpanSeconds: Double = 1.0

    static let windowSamples = Int(AudioWriter.sampleRate * windowSeconds)

    /// Levels are binned in dBFS; 0.25 dB is finer than the mix gains need and the table costs 2 KB.
    private static let binWidthDB: Double = 0.25
    private static let floorDB: Double = -120
    private static let binCount = Int(-floorDB / binWidthDB) + 1

    private(set) var windowCount = 0

    private var bins = [Int](repeating: 0, count: LevelMeter.binCount)
    private var partialSumSquares: Double = 0
    private var partialCount = 0

    // MARK: - Measuring

    /// Fold one chunk in. Chunks may split windows; the remainder carries to the next call.
    mutating func add(_ samples: [Float]) {
        var offset = 0
        while offset < samples.count {
            let take = min(Self.windowSamples - partialCount, samples.count - offset)

            var sumSquares: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_svesq(base + offset, 1, &sumSquares, vDSP_Length(take))
            }
            partialSumSquares += Double(sumSquares)
            partialCount += take
            offset += take

            if partialCount == Self.windowSamples {
                recordWindow()
            }
        }
    }

    /// Close the trailing partial window, so a recording shorter than one window still measures.
    mutating func finalize() {
        guard partialCount > 0 else { return }
        recordWindow()
    }

    // MARK: - Reading

    /// Level the source speaks at, or 0 when nothing was measured.
    var activeLevel: Float {
        guard windowCount > 0 else { return 0 }

        let rank = Self.activeRank(windowCount: windowCount)
        var seen = 0
        for index in stride(from: Self.binCount - 1, through: 0, by: -1) {
            seen += bins[index]
            if seen >= rank {
                return Self.level(atBin: index)
            }
        }
        return 0
    }

    /// Active level of a complete buffer, for callers holding the whole recording already.
    static func activeLevel(of samples: [Float]) -> Float {
        var meter = LevelMeter()
        meter.add(samples)
        meter.finalize()
        return meter.activeLevel
    }

    /// Rank, counted down from the loudest window, that the active level is read at.
    ///
    /// Recordings too short to hold the full span fall back to their median: there is no
    /// loudest second to read, and reading the quietest window instead would report silence.
    static func activeRank(windowCount: Int) -> Int {
        let halfSpan = Int((activeSpanSeconds / windowSeconds / 2).rounded())
        return max(1, min(halfSpan, windowCount / 2))
    }

    // MARK: - Private

    private mutating func recordWindow() {
        let rms = (partialSumSquares / Double(partialCount)).squareRoot()
        bins[Self.bin(forLevel: rms)] += 1
        windowCount += 1
        partialSumSquares = 0
        partialCount = 0
    }

    /// Bin 0 is the silence bin: anything under the floor counts as no signal at all.
    private static func bin(forLevel rms: Double) -> Int {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(binCount - 1, Int(((db - floorDB) / binWidthDB).rounded()))
    }

    private static func level(atBin index: Int) -> Float {
        guard index > 0 else { return 0 }
        return Float(pow(10, (floorDB + Double(index) * binWidthDB) / 20))
    }
}
