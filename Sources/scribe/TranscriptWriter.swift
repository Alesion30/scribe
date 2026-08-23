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
    private let format: TranscriptFormat
    private var cueNumber = 0

    init(path: String, format: TranscriptFormat) throws {
        self.format = format
        if path == "-" {
            isStdout = true
            handle = .standardOutput
            self.path = nil
            if format == .vtt {
                handle.write(Data("WEBVTT\n\n".utf8))
            }
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
        if format == .vtt {
            handle.write(Data("WEBVTT\n\n".utf8))
        }
    }

    convenience init(path: String) throws {
        try self.init(path: path, format: .txt)
    }

    /// Append one segment, unbuffered so an aborted run keeps what it wrote.
    func write(segment: TranscriptSegment) {
        guard !segment.text.isEmpty else { return }
        let output: String
        switch format {
        case .txt:
            output = "\(segment.text)\n"
        case .srt:
            cueNumber += 1
            output = "\(cueNumber)\n\(TranscriptFormat.timecode(segment.start, millisecondSeparator: \",\")) --> \(TranscriptFormat.timecode(segment.end, millisecondSeparator: \",\"))\n\(segment.text)\n\n"
        case .vtt:
            output = "\(TranscriptFormat.timecode(segment.start, millisecondSeparator: \".\")) --> \(TranscriptFormat.timecode(segment.end, millisecondSeparator: \".\"))\n\(segment.text)\n\n"
        }
        handle.write(Data(output.utf8))
    }

    func write(segment: String) {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        write(segment: TranscriptSegment(start: 0, end: 0, text: text))
    }

    /// Close the file and report where the transcript ended up. No-op for stdout.
    func close() {
        guard let path else { return }
        try? handle.close()
        Log.status("Transcript written to: \(path)")
    }
}
