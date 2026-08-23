import Foundation
import Testing
@testable import scribe

/// Tests for how decoded segments are placed in the full recording before they reach the output.
@Suite("Segment Collector")
struct SegmentCollectorTests {

    // MARK: - Helpers

    /// Collector that records everything it emits, so the streamed and returned segments can both be checked.
    static func makeCollector() -> (SegmentCollector, () -> [TranscriptSegment]) {
        var streamed: [TranscriptSegment] = []
        let collector = SegmentCollector { streamed.append($0) }
        return (collector, { streamed })
    }

    // MARK: - Repeat collapsing

    @Test("連続して繰り返された行は最初の 1 件だけ残す")
    func collapsesConsecutiveRepeats() {
        let (collector, streamed) = Self.makeCollector()

        for (index, text) in ["おはようございます", "おはようございます", "おはようございます", "本題に入ります"].enumerated() {
            collector.append(TranscriptSegment(start: Double(index) * 2, end: Double(index) * 2 + 2, text: text))
        }

        #expect(collector.segments.map(\.text) == ["おはようございます", "本題に入ります"])
        #expect(streamed().map(\.text) == ["おはようございます", "本題に入ります"])
        #expect(collector.droppedRepeats == 2)
    }

    @Test("残した行のタイムスタンプは最初の出現のまま変わらない")
    func keepsTimestampsOfFirstOccurrence() {
        let (collector, _) = Self.makeCollector()

        collector.append(TranscriptSegment(start: 0, end: 2, text: "お茶をつくってもらえますか?"))
        collector.append(TranscriptSegment(start: 2, end: 4, text: "お茶をつくってもらえますか?"))
        collector.append(TranscriptSegment(start: 4, end: 6, text: "はい"))

        #expect(collector.segments[0] == TranscriptSegment(start: 0, end: 2, text: "お茶をつくってもらえますか?"))
        #expect(collector.segments[1] == TranscriptSegment(start: 4, end: 6, text: "はい"))
    }

    @Test("間に別の行を挟んだ繰り返しは残す")
    func keepsRepeatsSeparatedByOtherLines() {
        let (collector, _) = Self.makeCollector()

        for (index, text) in ["はい", "そうですね", "はい"].enumerated() {
            collector.append(TranscriptSegment(start: Double(index) * 2, end: Double(index) * 2 + 2, text: text))
        }

        #expect(collector.segments.map(\.text) == ["はい", "そうですね", "はい"])
        #expect(collector.droppedRepeats == 0)
    }

    @Test("空文字のセグメントは捨てられ、重複判定にも影響しない")
    func dropsEmptySegments() {
        let (collector, _) = Self.makeCollector()

        collector.append(TranscriptSegment(start: 0, end: 2, text: "はい"))
        collector.append(TranscriptSegment(start: 2, end: 4, text: ""))
        collector.append(TranscriptSegment(start: 4, end: 6, text: "はい"))

        #expect(collector.segments.map(\.text) == ["はい"])
        #expect(collector.droppedRepeats == 1)
    }

    // MARK: - Chunk placement

    @Test("チャンクの開始位置がタイムスタンプに加算される")
    func offsetsTimestampsByChunkPosition() {
        let (collector, _) = Self.makeCollector()

        collector.startChunk(offset: 598, ownedStart: 600)
        collector.append(TranscriptSegment(start: 5, end: 8, text: "続きです"))

        #expect(collector.segments == [TranscriptSegment(start: 603, end: 606, text: "続きです")])
    }

    @Test("リードインに収まるセグメントは前のチャンクのものとして捨てられる")
    func dropsSegmentsOwnedByThePreviousChunk() {
        let (collector, _) = Self.makeCollector()

        collector.startChunk(offset: 598, ownedStart: 600)
        collector.append(TranscriptSegment(start: 0, end: 1.5, text: "前のチャンクの発話"))

        #expect(collector.segments.isEmpty)
    }

    @Test("境界をまたぐセグメントは中点のある側のチャンクが拾う")
    func assignsStraddlingSegmentsByMidpoint() {
        let (collector, _) = Self.makeCollector()

        collector.startChunk(offset: 598, ownedStart: 600)
        collector.append(TranscriptSegment(start: 1, end: 4, text: "境界をまたぐ発話"))

        #expect(collector.segments.map(\.text) == ["境界をまたぐ発話"])
    }
}
