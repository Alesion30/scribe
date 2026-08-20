import Foundation

/// Streams transcript segments to stdout or a file as whisper decodes them.
///
/// Writing incrementally is what makes a long transcription observable: the output
/// grows while it runs, and an interrupted run keeps everything decoded so far.
final class TranscriptWriter {
    /// True when the transcript goes to stdout, where a progress line would tangle with it.
    let isStdout: Bool

    private let handle: FileHandle
    private let path: String?

    init(path: String) throws {
        if path == "-" {
            isStdout = true
            handle = .standardOutput
            self.path = nil
            return
        }

        let expanded = (path as NSString).expandingTildeInPath
        // Truncate up front so a rerun replaces the previous transcript instead of appending to it.
        guard FileManager.default.createFile(atPath: expanded, contents: nil),
              let file = FileHandle(forWritingAtPath: expanded)
        else {
            throw ScribeError.cannotWriteOutput(expanded)
        }
        isStdout = false
        handle = file
        self.path = expanded
    }

    /// Append one segment as a line, unbuffered so an aborted run keeps what it wrote.
    func write(segment: String) {
        let line = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        handle.write(Data("\(line)\n".utf8))
    }

    /// Close the file and report where the transcript ended up. No-op for stdout.
    func close() {
        guard let path else { return }
        try? handle.close()
        Log.status("Transcript written to: \(path)")
    }
}
