import Foundation

/// Samples tagged with the host-clock instant of their first frame.
///
/// Both capture paths stamp their buffers against the host clock — AVAudioEngine through
/// `AVAudioTime.hostTime`, ScreenCaptureKit through the sample buffer's presentation timestamp —
/// so chunks from either stream can be laid out on one shared timeline.
struct TimedChunk {
    let startSeconds: Double
    /// Interleaved when the source is multi-channel, at the source sample rate.
    let samples: [Float]
}

/// A stretch of 16 kHz mono audio together with the host-clock instant of its first sample.
struct AudioTrack {
    let startSeconds: Double
    let samples: [Float]

    static let empty = AudioTrack(startSeconds: 0, samples: [])

    var isEmpty: Bool { samples.isEmpty }

    var duration: Double { Double(samples.count) / AudioWriter.sampleRate }

    /// Replace the samples while keeping the track's position on the host clock.
    func with(samples: [Float]) -> AudioTrack {
        AudioTrack(startSeconds: startSeconds, samples: samples)
    }

    /// Prepend silence so the track begins at `origin` instead of its own start time.
    func padded(to origin: Double) -> AudioTrack {
        let lead = Int(((startSeconds - origin) * AudioWriter.sampleRate).rounded())
        guard lead > 0 else { return self }
        return AudioTrack(startSeconds: origin, samples: [Float](repeating: 0, count: lead) + samples)
    }
}

/// Places captured buffers on a shared host-clock timeline.
///
/// Appending buffers in arrival order loses the offset between streams: the microphone starts
/// the moment `AVAudioEngine` does, while ScreenCaptureKit needs an `await` round trip first.
/// Mixing those two arrays head to head overlays the same voice against itself a beat late,
/// which whisper then transcribes twice.
enum AudioTimeline {
    /// How far a chunk may land from where the previous one ended before it counts as a drop.
    ///
    /// Loose enough to ride out timestamp jitter, tight enough that a dropped buffer still splits
    /// the run instead of shifting everything after it.
    static let defaultGapTolerance: Double = 0.05

    /// Group chunks into stretches that are contiguous in time.
    ///
    /// Each stretch can then be resampled in one pass, and the silence between stretches stands in
    /// for what the capture dropped. Splitting on the gap also absorbs clock drift: a source that
    /// runs slightly fast or slow gets repositioned instead of sliding further out over hours.
    static func runs(
        from chunks: [TimedChunk],
        sampleRate: Double,
        channels: Int,
        tolerance: Double = defaultGapTolerance
    ) -> [TimedChunk] {
        guard sampleRate > 0, channels > 0 else { return [] }

        var runs: [TimedChunk] = []
        var start: Double = 0
        var samples: [Float] = []

        for chunk in chunks where !chunk.samples.isEmpty {
            if samples.isEmpty {
                start = chunk.startSeconds
            } else {
                let expected = start + Double(samples.count / channels) / sampleRate
                if abs(chunk.startSeconds - expected) > tolerance {
                    runs.append(TimedChunk(startSeconds: start, samples: samples))
                    start = chunk.startSeconds
                    samples = []
                }
            }
            samples.append(contentsOf: chunk.samples)
        }

        if !samples.isEmpty {
            runs.append(TimedChunk(startSeconds: start, samples: samples))
        }

        return runs
    }

    /// Lay runs out from `origin` at the transcription sample rate, leaving the gaps silent.
    static func render(_ runs: [TimedChunk], origin: Double) -> [Float] {
        var timeline: [Float] = []

        for run in runs where !run.samples.isEmpty {
            let offset = Int(((run.startSeconds - origin) * AudioWriter.sampleRate).rounded())
            // A run stamped before the origin is trimmed, not wrapped around to the front.
            let skip = max(0, -offset)
            guard skip < run.samples.count else { continue }

            // Runs of one stream cannot truly overlap — push a backwards stamp along, never trim it.
            let start = max(offset + skip, timeline.count)

            if timeline.count < start {
                timeline.append(contentsOf: repeatElement(0, count: start - timeline.count))
            }
            timeline.append(contentsOf: run.samples[skip...])
        }

        return timeline
    }

    /// Turn captured chunks into one 16 kHz mono track, silence standing in for dropped buffers.
    static func track(from chunks: [TimedChunk], sampleRate: Double, channels: Int) -> AudioTrack {
        let runs = runs(from: chunks, sampleRate: sampleRate, channels: channels)
        guard let origin = runs.first?.startSeconds else { return .empty }

        var resampled: [TimedChunk] = []
        for run in runs {
            guard let samples = AudioWriter.resample(run.samples, fromRate: sampleRate, channels: channels) else {
                let offset = run.startSeconds - origin
                Log.warning("Failed to resample the run at \(String(format: "%.1f", offset))s — dropping it")
                continue
            }
            resampled.append(TimedChunk(startSeconds: run.startSeconds, samples: samples))
        }

        let track = AudioTrack(startSeconds: origin, samples: render(resampled, origin: origin))
        logGaps(runs: runs, track: track, sampleRate: sampleRate, channels: channels)
        return track
    }

    /// Pad the later-starting track at the front so both share the earlier start time.
    static func align(_ first: AudioTrack, _ second: AudioTrack) -> (AudioTrack, AudioTrack) {
        guard !first.isEmpty, !second.isEmpty else { return (first, second) }

        let origin = min(first.startSeconds, second.startSeconds)
        return (first.padded(to: origin), second.padded(to: origin))
    }

    // MARK: - Private

    private static func logGaps(runs: [TimedChunk], track: AudioTrack, sampleRate: Double, channels: Int) {
        guard runs.count > 1 else { return }

        let captured = runs.reduce(0.0) { $0 + Double($1.samples.count / channels) / sampleRate }
        let filled = max(0, track.duration - captured)
        Log.debug("Capture dropped \(runs.count - 1) time(s); filled \(String(format: "%.2f", filled))s with silence")
    }
}
