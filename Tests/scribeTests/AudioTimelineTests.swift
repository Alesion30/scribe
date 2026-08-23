import Testing
@testable import scribe

/// Tests for laying captured buffers out on a shared host-clock timeline, so that mic and system
/// audio line up instead of being mixed head to head.
@Suite("Audio Timeline")
struct AudioTimelineTests {

    // MARK: - Helpers

    /// Chunks laid down back to back from `start`, at 16 kHz mono.
    static func chunks(from start: Double, count: Int, frames: Int, value: Float) -> [TimedChunk] {
        (0..<count).map { index in
            TimedChunk(
                startSeconds: start + Double(index * frames) / 16000,
                samples: [Float](repeating: value, count: frames)
            )
        }
    }

    // MARK: - Run Splitting

    @Test("Contiguous chunks stay in one run")
    func contiguousChunksFormOneRun() {
        let runs = AudioTimeline.runs(
            from: Self.chunks(from: 10.0, count: 4, frames: 1600, value: 0.5),
            sampleRate: 16000,
            channels: 1
        )

        #expect(runs.count == 1, "Expected one run, got \(runs.count)")
        #expect(runs[0].startSeconds == 10.0)
        #expect(runs[0].samples.count == 6400)
    }

    @Test("Jitter within the tolerance does not split a run")
    func jitterKeepsOneRun() {
        var chunks = Self.chunks(from: 0, count: 4, frames: 1600, value: 0.5)
        // Nudge each stamp by up to 20 ms — inside the 50 ms tolerance.
        chunks = chunks.enumerated().map { index, chunk in
            let jitter = index.isMultiple(of: 2) ? 0.02 : -0.02
            return TimedChunk(startSeconds: chunk.startSeconds + jitter, samples: chunk.samples)
        }

        let runs = AudioTimeline.runs(from: chunks, sampleRate: 16000, channels: 1)

        #expect(runs.count == 1, "Jitter should not look like a drop, got \(runs.count) runs")
    }

    @Test("A dropped buffer splits the run")
    func dropSplitsRun() {
        var chunks = Self.chunks(from: 0, count: 2, frames: 1600, value: 0.5)
        chunks.append(TimedChunk(startSeconds: 0.5, samples: [Float](repeating: 0.5, count: 1600)))

        let runs = AudioTimeline.runs(from: chunks, sampleRate: 16000, channels: 1)

        #expect(runs.count == 2, "Expected the 0.3 s gap to split the run, got \(runs.count)")
        #expect(runs[1].startSeconds == 0.5)
    }

    @Test("Multi-channel chunks are measured in frames, not samples")
    func multiChannelIsMeasuredInFrames() {
        // 1600 stereo frames span 0.1 s, so the chunk stamped at 0.1 s continues the run.
        let chunks = [
            TimedChunk(startSeconds: 0.0, samples: [Float](repeating: 0.5, count: 3200)),
            TimedChunk(startSeconds: 0.1, samples: [Float](repeating: 0.5, count: 3200)),
        ]

        let runs = AudioTimeline.runs(from: chunks, sampleRate: 16000, channels: 2)

        #expect(runs.count == 1, "Stereo frames were counted as samples, got \(runs.count) runs")
    }

    // MARK: - Rendering

    @Test("Gaps are filled with silence so later audio keeps its position")
    func gapsBecomeSilence() {
        let chunks = [
            TimedChunk(startSeconds: 0.0, samples: [Float](repeating: 0.5, count: 1600)),
            TimedChunk(startSeconds: 0.3, samples: [Float](repeating: 0.5, count: 1600)),
        ]

        let track = AudioTimeline.track(from: chunks, sampleRate: 16000, channels: 1)

        #expect(track.samples.count == 6400, "Expected 0.4 s of timeline, got \(track.samples.count) samples")
        #expect(track.samples[2400] == 0, "The gap should be silent")
        #expect(track.samples[5000] == 0.5, "Audio after the gap should keep its offset")
    }

    @Test("Overlapping stamps keep every sample")
    func overlappingStampsKeepAudio() {
        // A stamp that points backwards must not rewind the write head over what is already down.
        let chunks = [
            TimedChunk(startSeconds: 1.0, samples: [Float](repeating: 0.5, count: 1600)),
            TimedChunk(startSeconds: 1.0, samples: [Float](repeating: 0.25, count: 1600)),
        ]

        let track = AudioTimeline.track(from: chunks, sampleRate: 16000, channels: 1)

        #expect(track.samples.count == 3200, "Expected both chunks to survive, got \(track.samples.count)")
        #expect(track.samples[0] == 0.5)
        #expect(track.samples[1600] == 0.25)
    }

    @Test("No chunks yields an empty track")
    func emptyInputYieldsEmptyTrack() {
        let track = AudioTimeline.track(from: [], sampleRate: 16000, channels: 1)

        #expect(track.isEmpty)
    }

    // MARK: - Alignment

    @Test("The later track is padded up to the earlier start time")
    func alignPadsLaterTrack() {
        let mic = AudioTrack(startSeconds: 100.0, samples: [Float](repeating: 0.5, count: 16000))
        let system = AudioTrack(startSeconds: 100.75, samples: [Float](repeating: 0.25, count: 16000))

        let (alignedMic, alignedSystem) = AudioTimeline.align(mic, system)

        #expect(alignedMic.startSeconds == alignedSystem.startSeconds)
        #expect(alignedMic.samples.count == 16000, "The earlier track should be untouched")
        #expect(alignedSystem.samples.count == 28000, "Expected 0.75 s of leading silence")
        #expect(alignedSystem.samples[0] == 0)
        #expect(alignedSystem.samples[12000] == 0.25)
    }

    @Test("Aligning lines up a sound that reached the two streams at different times")
    func alignLinesUpTheSameSound() {
        // A burst sounds 0.5 s after the mic starts; the system stream only comes up in time to
        // catch the burst from its first sample. Head-to-head mixing would leave the two copies
        // 0.5 s apart, which is what whisper transcribes twice.
        let burst = (0..<16000).map { Float($0 % 100) / 100 }
        let mic = AudioTrack(startSeconds: 100.0, samples: [Float](repeating: 0, count: 8000) + burst)
        let system = AudioTrack(startSeconds: 100.5, samples: burst)

        let (alignedMic, alignedSystem) = AudioTimeline.align(mic, system)

        #expect(alignedMic.samples.count == alignedSystem.samples.count)
        let offsets = stride(from: 0, to: burst.count, by: 997)
        #expect(
            offsets.allSatisfy { alignedMic.samples[8000 + $0] == alignedSystem.samples[8000 + $0] },
            "The two copies of the burst should sit at the same offset after alignment"
        )
    }

    @Test("An empty track leaves the other one untouched")
    func alignIgnoresEmptyTracks() {
        let system = AudioTrack(startSeconds: 5.0, samples: [Float](repeating: 0.5, count: 1600))

        let (alignedMic, alignedSystem) = AudioTimeline.align(.empty, system)

        #expect(alignedMic.isEmpty)
        #expect(alignedSystem.samples.count == 1600, "Nothing to align against, so no padding")
    }
}
