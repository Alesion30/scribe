import Foundation
import Testing
@testable import scribe

/// Tests for what happens to the recording once the transcript is written.
/// The default command throws away the WAV it generated, but never one the user asked for.
@Suite("Recording Disposal")
struct RecordingDisposalTests {

    // MARK: - Helpers

    static func withTemporaryRecording<T>(_ body: (String) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("2026-08-23_14-30-00.wav").path
        FileManager.default.createFile(atPath: path, contents: Data("RIFF".utf8))
        return try body(path)
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Deleting

    @Test("A recording scribe named itself is deleted after transcribing")
    func deletesGeneratedRecording() throws {
        try Self.withTemporaryRecording { path in
            let deleted = try disposeRecording(at: path, userSpecifiedWavPath: nil, keepAudio: false)

            #expect(deleted)
            #expect(!Self.exists(path))
        }
    }

    // MARK: - Keeping

    @Test("--keep-audio keeps the recording")
    func keepAudioKeepsRecording() throws {
        try Self.withTemporaryRecording { path in
            let deleted = try disposeRecording(at: path, userSpecifiedWavPath: nil, keepAudio: true)

            #expect(!deleted)
            #expect(Self.exists(path), "--keep-audio must leave the recording alone")
        }
    }

    @Test("A path the user asked for with -w is kept")
    func userSpecifiedPathKeepsRecording() throws {
        try Self.withTemporaryRecording { path in
            let deleted = try disposeRecording(at: path, userSpecifiedWavPath: path, keepAudio: false)

            #expect(!deleted)
            #expect(Self.exists(path), "a path the user chose is theirs to keep")
        }
    }

    @Test("A user-specified path is kept even with a tilde still in it")
    func userSpecifiedPathIsRecognisedBeforeExpansion() throws {
        try Self.withTemporaryRecording { path in
            let deleted = try disposeRecording(at: path, userSpecifiedWavPath: "~/meeting.wav", keepAudio: false)

            #expect(!deleted)
            #expect(Self.exists(path))
        }
    }

    // MARK: - Failure

    @Test("A recording that cannot be deleted is reported, not swallowed")
    func reportsDeletionFailure() {
        let missing = "/nonexistent-scribe-dir/2026-08-23_14-30-00.wav"

        #expect(throws: ScribeError.self) {
            _ = try disposeRecording(at: missing, userSpecifiedWavPath: nil, keepAudio: false)
        }
    }

    @Test("The failure message says the transcript survived and where the recording is")
    func failureMessageNamesTheLeftoverRecording() {
        let missing = "/nonexistent-scribe-dir/2026-08-23_14-30-00.wav"
        let message = ScribeError.recordingCleanupFailed(path: missing, reason: "no such file").errorDescription

        #expect(message?.contains(missing) == true)
        #expect(message?.contains("Transcription finished") == true)
    }
}
