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

    /// Transcribe Float PCM samples (16 kHz mono) and return text.
    ///
    /// `onSegment` fires as each segment is decoded, so callers can emit results
    /// while a long file is still running instead of waiting for the whole thing.
    @discardableResult
    func transcribe(
        samples: [Float],
        language: String = "auto",
        showProgress: Bool = false,
        onSegment: ((String) -> Void)? = nil
    ) throws -> String {
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
                collector.append(String(cString: cStr))
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

        return collector.text
    }
}

/// Bridges whisper.cpp's C segment callback back into Swift.
private final class SegmentCollector {
    private let onSegment: ((String) -> Void)?
    private var lines: [String] = []

    init(onSegment: ((String) -> Void)?) {
        self.onSegment = onSegment
    }

    var text: String {
        lines.joined(separator: "\n")
    }

    /// whisper pads each segment with a leading space; trim per line since we emit them one by one.
    func append(_ segment: String) {
        let line = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        lines.append(line)
        onSegment?(line)
    }
}
