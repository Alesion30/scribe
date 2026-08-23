import Testing
@testable import scribe

/// Tests for placing one source's buffers on the host clock while it streams to disk.
@Suite("Capture Timeline")
struct CaptureTimelineTests {

    @Test("Back-to-back buffers need no silence between them")
    func contiguousBuffersNeedNoSilence() {
        var timeline = CaptureTimeline()

        #expect(timeline.silenceNeeded(before: 100.0, written: 0) == 0)
        #expect(timeline.silenceNeeded(before: 100.5, written: 8000) == 0)
        #expect(timeline.silenceNeeded(before: 101.0, written: 16000) == 0)
        #expect(timeline.startSeconds == 100.0)
    }

    @Test("Timestamp jitter is ridden out rather than filled")
    func jitterIsIgnored() {
        var timeline = CaptureTimeline()
        _ = timeline.silenceNeeded(before: 100.0, written: 0)

        // 20 ms short of where the buffer was expected, inside the 50 ms tolerance.
        #expect(timeline.silenceNeeded(before: 100.5, written: 7680) == 0)
    }

    @Test("A dropped buffer leaves a gap to fill")
    func dropIsFilledWithSilence() {
        var timeline = CaptureTimeline()
        _ = timeline.silenceNeeded(before: 100.0, written: 0)

        // Half a second of capture never arrived, so the next buffer lands 8000 samples late.
        #expect(timeline.silenceNeeded(before: 101.0, written: 8000) == 8000)
    }

    @Test("A buffer stamped early is written where it lands")
    func earlyStampIsNotTrimmed() {
        var timeline = CaptureTimeline()
        _ = timeline.silenceNeeded(before: 100.0, written: 0)

        #expect(timeline.silenceNeeded(before: 100.4, written: 8000) == 0)
    }

    @Test("Untimed buffers are written as they come")
    func untimedBuffersPassThrough() {
        var timeline = CaptureTimeline()

        #expect(timeline.silenceNeeded(before: nil, written: 0) == 0)
        #expect(timeline.silenceNeeded(before: nil, written: 8000) == 0)
        #expect(timeline.startSeconds == nil)
    }

    @Test("The first stamp accounts for what was already written")
    func originReachesBackOverUntimedAudio() {
        var timeline = CaptureTimeline()
        _ = timeline.silenceNeeded(before: nil, written: 0)

        // Half a second went to disk unstamped, so the source began half a second before this buffer.
        #expect(timeline.silenceNeeded(before: 100.5, written: 8000) == 0)
        #expect(timeline.startSeconds == 100.0)
    }
}
