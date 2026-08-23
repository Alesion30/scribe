import Foundation
import Testing
@testable import scribe

/// Tests for the incremental transcript output introduced so that long
/// transcriptions show progress and survive an interrupted run.
@Suite("Transcript Writer")
struct TranscriptWriterTests {

    /// Unique path inside a temporary directory, removed by the caller.
    static func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-transcript-\(UUID().uuidString).txt")
            .path
    }

    @Test("Segments land in the file before the writer is closed")
    func writesIncrementally() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = try TranscriptWriter(path: path)
        writer.write(segment: "最初のセグメント")

        // Read back while the writer is still open — this is the whole point.
        let midRun = try String(contentsOfFile: path, encoding: .utf8)
        #expect(midRun == "最初のセグメント\n")

        writer.write(segment: "次のセグメント")
        writer.close()

        let final = try String(contentsOfFile: path, encoding: .utf8)
        #expect(final == "最初のセグメント\n次のセグメント\n")
    }

    @Test("Existing file is truncated instead of appended to")
    func truncatesExistingFile() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "前回の実行結果\n".write(toFile: path, atomically: true, encoding: .utf8)

        let writer = try TranscriptWriter(path: path)
        writer.write(segment: "今回の実行結果")
        writer.close()

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "今回の実行結果\n")
    }

    @Test("Leading whitespace from whisper segments is trimmed")
    func trimsSegments() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = try TranscriptWriter(path: path)
        writer.write(segment: " こんにちは ")
        writer.close()

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "こんにちは\n")
    }

    @Test("Blank segments produce no line")
    func skipsBlankSegments() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = try TranscriptWriter(path: path)
        writer.write(segment: "   ")
        writer.write(segment: "\n")
        writer.write(segment: "本文")
        writer.close()

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "本文\n")
    }

    @Test("Unwritable path is rejected up front")
    func rejectsUnwritablePath() throws {
        let path = "/nonexistent-scribe-dir/transcript.txt"
        #expect(throws: ScribeError.self) {
            _ = try TranscriptWriter(path: path)
        }
    }

    @Test("Tilde in the output path is expanded")
    func expandsTilde() throws {
        let name = "scribe-transcript-\(UUID().uuidString).txt"
        let expanded = ("~/\(name)" as NSString).expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: expanded) }

        let writer = try TranscriptWriter(path: "~/\(name)")
        writer.write(segment: "本文")
        writer.close()

        #expect(FileManager.default.fileExists(atPath: expanded))
    }

    @Test("Stdout output is flagged so progress output can step aside")
    func stdoutIsFlagged() throws {
        #expect(try TranscriptWriter(path: "-").isStdout)

        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try TranscriptWriter(path: path)
        #expect(!writer.isStdout)
        writer.close()
    }
}
