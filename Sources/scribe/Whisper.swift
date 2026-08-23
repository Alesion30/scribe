import Foundation
import whisper

enum WhisperError: LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper model from: \(path)"
        case .transcriptionFailed:
            return "Whisper transcription failed"
        }
    }
}

/// Thread-safe whisper.cpp context wrapper.
final class WhisperContext {
    private let context: OpaquePointer

    /// Initialize from a model file path.
    init(modelPath: String) throws {
        var cparams = whisper_context_default_params()
        cparams.flash_attn = true
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.context = ctx
        Log.info("Whisper model loaded from \(modelPath)")
    }

    deinit {
        whisper_free(context)
        Log.debug("Whisper context freed")
    }

    /// Transcribe Float PCM samples (16 kHz mono), emitting each timestamped segment as it is decoded.
    func transcribe(
        samples: [Float],
        language: String = "auto",
        showProgress: Bool = false,
        onSegment: @escaping (TranscriptSegment) -> Void
    ) throws -> [TranscriptSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        params.n_threads = threadCount
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true

        if showProgress {
            params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, progress: Int32, _: UnsafeMutableRawPointer?) in
                Log.progress("Transcribing... \(progress)%")
            }
        }

        let collector = SegmentCollector(onSegment: onSegment)
        params.new_segment_callback = { (ctx: OpaquePointer?, _: OpaquePointer?, newCount: Int32, userData: UnsafeMutableRawPointer?) in
            guard let ctx, let userData else { return }
            let collector = Unmanaged<SegmentCollector>.fromOpaque(userData).takeUnretainedValue()
            let total = whisper_full_n_segments(ctx)
            for i in max(0, total - newCount)..<total {
                guard let cStr = whisper_full_get_segment_text(ctx, i) else { continue }
                collector.append(
                    TranscriptSegment(
                        start: WhisperContext.seconds(from: whisper_full_get_segment_t0(ctx, i)),
                        end: WhisperContext.seconds(from: whisper_full_get_segment_t1(ctx, i)),
                        text: String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }
        params.new_segment_callback_user_data = Unmanaged.passUnretained(collector).toOpaque()

        let result: Int32 = try language.withCString { langPtr in
            params.language = langPtr
            return try samples.withUnsafeBufferPointer { bufferPtr in
                guard let baseAddress = bufferPtr.baseAddress else {
                    throw WhisperError.transcriptionFailed
                }
                return whisper_full(context, params, baseAddress, Int32(samples.count))
            }
        }

        if result != 0 {
            throw WhisperError.transcriptionFailed
        }

        return collector.segments
    }

    /// whisper reports segment boundaries in centiseconds.
    private static func seconds(from timestamp: Int64) -> TimeInterval {
        TimeInterval(timestamp) / 100.0
    }
}

/// Bridges whisper.cpp's C segment callback back into Swift.
private final class SegmentCollector {
    private let onSegment: (TranscriptSegment) -> Void
    private(set) var segments: [TranscriptSegment] = []

    init(onSegment: @escaping (TranscriptSegment) -> Void) {
        self.onSegment = onSegment
    }

    func append(_ segment: TranscriptSegment) {
        guard !segment.text.isEmpty else { return }
        segments.append(segment)
        onSegment(segment)
    }
}
