import Testing
@testable import scribe

/// Tests for the post-processing that keeps a hallucination loop from burying the transcript.
@Suite("Transcript Segment")
struct TranscriptSegmentTests {

    // MARK: - Helpers

    static func segments(_ texts: [String]) -> [TranscriptSegment] {
        texts.enumerated().map { index, text in
            TranscriptSegment(start: Double(index) * 2, end: Double(index) * 2 + 2, text: text)
        }
    }

    // MARK: - Repeat collapsing

    @Test("連続して繰り返された行は最初の 1 件だけ残す")
    func collapsesConsecutiveRepeats() {
        let collapsed = TranscriptSegment.collapsingRepeats(
            Self.segments(["おはようございます", "おはようございます", "おはようございます", "本題に入ります"])
        )

        #expect(collapsed.map(\.text) == ["おはようございます", "本題に入ります"])
    }

    @Test("残した行のタイムスタンプは最初の出現のまま変わらない")
    func keepsTimestampsOfFirstOccurrence() {
        let collapsed = TranscriptSegment.collapsingRepeats(
            Self.segments(["お茶をつくってもらえますか?", "お茶をつくってもらえますか?", "はい"])
        )

        #expect(collapsed[0] == TranscriptSegment(start: 0, end: 2, text: "お茶をつくってもらえますか?"))
        #expect(collapsed[1] == TranscriptSegment(start: 4, end: 6, text: "はい"))
    }

    @Test("間に別の行を挟んだ繰り返しは残す")
    func keepsRepeatsSeparatedByOtherLines() {
        let collapsed = TranscriptSegment.collapsingRepeats(Self.segments(["はい", "そうですね", "はい"]))

        #expect(collapsed.map(\.text) == ["はい", "そうですね", "はい"])
    }

    @Test("繰り返しがなければ入力をそのまま返す")
    func leavesDistinctSegmentsUntouched() {
        let input = Self.segments(["今日の会議を始めます。", "まず先週の進捗から。"])

        #expect(TranscriptSegment.collapsingRepeats(input) == input)
    }

    @Test("空の入力は空のまま返す")
    func handlesEmptyInput() {
        #expect(TranscriptSegment.collapsingRepeats([]).isEmpty)
    }
}
