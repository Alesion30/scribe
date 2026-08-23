import ArgumentParser
import Foundation

/// A single whisper segment with its position in the source audio.
struct TranscriptSegment: Equatable {
    /// Seconds elapsed from the start of the audio.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

extension TranscriptSegment {
    /// Drop segments that repeat the line right before them.
    ///
    /// whisper loops on audio it cannot resolve; the first occurrence still marks the stretch.
    static func collapsingRepeats(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept: [TranscriptSegment] = []
        kept.reserveCapacity(segments.count)

        for segment in segments where segment.text != kept.last?.text {
            kept.append(segment)
        }

        let dropped = segments.count - kept.count
        if dropped > 0 {
            Log.debug("Collapsed \(dropped) repeated segments")
        }
        return kept
    }
}

/// Output format for a transcript.
enum TranscriptFormat: String, CaseIterable, Codable, ExpressibleByArgument {
    /// One line per segment, no timestamps.
    case txt
    /// SubRip subtitles: numbered cues with `HH:MM:SS,mmm` ranges.
    case srt
    /// WebVTT subtitles: a `WEBVTT` header followed by `HH:MM:SS.mmm` ranges.
    case vtt
}

extension TranscriptFormat {
    /// Render segments as text. Empty segments are dropped so a silent stretch doesn't emit a blank cue.
    func render(_ segments: [TranscriptSegment]) -> String {
        let usable = segments.filter { !$0.text.isEmpty }

        switch self {
        case .txt:
            return usable.map(\.text).joined(separator: "\n")

        case .srt:
            let cues = usable.enumerated().map { index, segment in
                """
                \(index + 1)
                \(Self.timecode(segment.start, millisecondSeparator: ",")) --> \(Self.timecode(segment.end, millisecondSeparator: ","))
                \(segment.text)
                """
            }
            return cues.joined(separator: "\n\n")

        case .vtt:
            let cues = usable.map { segment in
                """
                \(Self.timecode(segment.start, millisecondSeparator: ".")) --> \(Self.timecode(segment.end, millisecondSeparator: "."))
                \(segment.text)
                """
            }
            return (["WEBVTT"] + cues).joined(separator: "\n\n")
        }
    }

    /// Format seconds as `HH:MM:SS<sep>mmm`. Hours are not wrapped, so recordings past 100 hours widen the field.
    static func timecode(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000

        return String(
            format: "%02d:%02d:%02d%@%03d",
            totalSeconds / 3600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            millisecondSeparator,
            milliseconds
        )
    }
}
