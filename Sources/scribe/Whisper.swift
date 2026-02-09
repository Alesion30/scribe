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
    func transcribe(samples: [Float], language: String = "auto") throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        params.n_threads = threadCount
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true

        if Log.verbose {
            params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, progress: Int32, _: UnsafeMutableRawPointer?) in
                Log.progress("Transcribing... \(progress)%")
            }
        }

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

        let segmentCount = whisper_full_n_segments(context)
        var text = ""
        for i in 0..<segmentCount {
            guard let cStr = whisper_full_get_segment_text(context, i) else { continue }
            if !text.isEmpty { text += "\n" }
            text += String(cString: cStr)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
