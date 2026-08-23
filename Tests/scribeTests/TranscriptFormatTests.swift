import Testing
@testable import scribe

/// Tests for transcript rendering: the timecode arithmetic and the layout of
/// each output format.
@Suite("Transcript Format")
struct TranscriptFormatTests {

    // MARK: - Helpers

    static let sample = [
        TranscriptSegment(start: 0, end: 3.48, text: "今日の会議を始めます。"),
        TranscriptSegment(start: 3.48, end: 7.12, text: "まず先週の進捗から。")
    ]

    // MARK: - txt

    @Test("txt はタイムスタンプなしで 1 セグメント 1 行になる")
    func txtJoinsLines() {
        let output = TranscriptFormat.txt.render(Self.sample)

        #expect(output == "今日の会議を始めます。\nまず先週の進捗から。")
    }

    // MARK: - srt

    @Test("srt は 1 始まりの連番と HH:MM:SS,mmm 形式のキューを出力する")
    func srtRendersNumberedCues() {
        let output = TranscriptFormat.srt.render(Self.sample)

        #expect(output == """
            1
            00:00:00,000 --> 00:00:03,480
            今日の会議を始めます。

            2
            00:00:03,480 --> 00:00:07,120
            まず先週の進捗から。
            """)
    }

    // MARK: - vtt

    @Test("vtt は WEBVTT ヘッダ付きで HH:MM:SS.mmm 形式のキューを出力する")
    func vttRendersHeaderAndCues() {
        let output = TranscriptFormat.vtt.render(Self.sample)

        #expect(output == """
            WEBVTT

            00:00:00.000 --> 00:00:03.480
            今日の会議を始めます。

            00:00:03.480 --> 00:00:07.120
            まず先週の進捗から。
            """)
    }

    // MARK: - Timecode

    @Test("1 時間を超えるセグメントでも時・分・秒が繰り上がる")
    func timecodeCarriesIntoHours() {
        let segments = [TranscriptSegment(start: 3661.5, end: 7325.004, text: "長時間録音")]

        #expect(TranscriptFormat.srt.render(segments).contains("01:01:01,500 --> 02:02:05,004"))
    }

    @Test("100 時間を超えると時の桁が広がる")
    func timecodeWidensPastHundredHours() {
        let segments = [TranscriptSegment(start: 360000, end: 360001, text: "境界")]

        #expect(TranscriptFormat.srt.render(segments).contains("100:00:00,000 --> 100:00:01,000"))
    }

    @Test("ミリ秒未満は四捨五入される")
    func timecodeRoundsSubMilliseconds() {
        let segments = [TranscriptSegment(start: 1.0004, end: 1.0006, text: "丸め")]

        #expect(TranscriptFormat.vtt.render(segments).contains("00:00:01.000 --> 00:00:01.001"))
    }

    // MARK: - Edge cases

    @Test(
        "空文字のセグメントは空のキューを作らずに落とされる",
        arguments: TranscriptFormat.allCases
    )
    func emptySegmentsAreDropped(format: TranscriptFormat) {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "有効"),
            TranscriptSegment(start: 1, end: 2, text: ""),
            TranscriptSegment(start: 2, end: 3, text: "有効")
        ]

        let output = format.render(segments)
        #expect(!output.contains("\n\n\n"), "Blank cue leaked into output: \(output)")

        if format == .srt {
            // 連番は残ったセグメントに対して振り直される
            #expect(output.contains("\n2\n"))
            #expect(!output.contains("\n3\n"))
        }
    }

    @Test("セグメントが 1 つもなければ空文字か形式のヘッダだけを返す", arguments: TranscriptFormat.allCases)
    func emptyInputRendersMinimally(format: TranscriptFormat) {
        let output = format.render([])

        #expect(output == (format == .vtt ? "WEBVTT" : ""))
    }
}
