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

// MARK: - Options

/// Knobs for a transcription run.
struct TranscribeOptions {
    /// Language hint (ISO 639-1) or "auto" to let whisper detect it.
    var language: String = "auto"

    /// Seconds of audio per `whisper_full` call; zero or less feeds the whole recording at once.
    ///
    /// whisper normalizes the spectrogram over its whole input; one loud moment buries the rest.
    var chunkLength: TimeInterval = 600

    /// Seconds of the previous chunk replayed so a word split by a boundary still decodes whole.
    var chunkOverlap: TimeInterval = 2

    /// Path to a Silero VAD model, or nil to feed silence to the decoder as-is.
    var vadModelPath: String?
}

// MARK: - Context

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

    /// Transcribe Float PCM samples (16 kHz mono) and return the segments with their timestamps.
    func transcribe(samples: [Float], options: TranscribeOptions = TranscribeOptions()) throws -> [TranscriptSegment] {
        let chunks = Self.chunks(sampleCount: samples.count, options: options)
        if chunks.count > 1 {
            Log.info("Split into \(chunks.count) chunks of \(String(format: "%.0f", options.chunkLength))s")
        }

        var segments: [TranscriptSegment] = []
        for (index, chunk) in chunks.enumerated() {
            let decoded = try decode(
                samples: samples,
                range: chunk.fed,
                options: options,
                progress: ProgressReporter(chunkIndex: index, chunkCount: chunks.count)
            )

            let offset = TimeInterval(chunk.fed.lowerBound) / AudioWriter.sampleRate
            let ownedStart = TimeInterval(chunk.owned.lowerBound) / AudioWriter.sampleRate

            for segment in decoded {
                let start = segment.start + offset
                let end = segment.end + offset

                // Assign by midpoint so the lead-in never emits the same line twice
                guard (start + end) / 2 >= ownedStart else { continue }

                segments.append(TranscriptSegment(start: start, end: end, text: segment.text))
            }
        }

        return TranscriptSegment.collapsingRepeats(segments)
    }

    /// Run `whisper_full` over one range of samples. Timestamps are relative to `range.lowerBound`.
    private func decode(
        samples: [Float],
        range: Range<Int>,
        options: TranscribeOptions,
        progress: ProgressReporter
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

        // A loop latches onto non-speech tokens; whisper.cpp leaves them unsuppressed by default
        params.suppress_nst = true

        if Log.verbose {
            params.progress_callback = { (_, _, percent: Int32, userData: UnsafeMutableRawPointer?) in
                guard let userData else { return }
                Unmanaged<ProgressReporter>.fromOpaque(userData).takeUnretainedValue().report(percent)
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(progress).toOpaque()
        }

        let result: Int32 = try withExtendedLifetime(progress) {
            // whisper.cpp maps timestamps back to the original audio after dropping silence
            try Self.withOptionalCString(options.vadModelPath) { vadPtr in
                if let vadPtr {
                    params.vad = true
                    params.vad_model_path = vadPtr
                    params.vad_params = whisper_vad_default_params()
                }

                return try options.language.withCString { langPtr in
                    params.language = langPtr

                    return try samples.withUnsafeBufferPointer { bufferPtr in
                        guard let baseAddress = bufferPtr.baseAddress else {
                            throw WhisperError.transcriptionFailed
                        }
                        return whisper_full(context, params, baseAddress + range.lowerBound, Int32(range.count))
                    }
                }
            }
        }

        if result != 0 {
            throw WhisperError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(Int(segmentCount))

        for i in 0..<segmentCount {
            guard let cStr = whisper_full_get_segment_text(context, i) else { continue }

            // whisper prefixes segment text with a space; strip it so every output format starts clean.
            let text = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            segments.append(
                TranscriptSegment(
                    start: Self.seconds(from: whisper_full_get_segment_t0(context, i)),
                    end: Self.seconds(from: whisper_full_get_segment_t1(context, i)),
                    text: text
                )
            )
        }

        return segments
    }

    // MARK: - Chunking

    /// One `whisper_full` call: the samples it decodes and the span it is responsible for.
    struct Chunk: Equatable {
        /// Samples handed to whisper, including the lead-in borrowed from the previous chunk.
        let fed: Range<Int>
        /// Samples this chunk owns; the lead-in belongs to its predecessor.
        let owned: Range<Int>
    }

    static func chunks(sampleCount: Int, options: TranscribeOptions) -> [Chunk] {
        let step = Int((options.chunkLength * AudioWriter.sampleRate).rounded())
        guard step > 0, sampleCount > step else {
            return [Chunk(fed: 0..<sampleCount, owned: 0..<sampleCount)]
        }

        let leadIn = max(0, Int((options.chunkOverlap * AudioWriter.sampleRate).rounded()))
        return stride(from: 0, to: sampleCount, by: step).map { start in
            let owned = start..<min(start + step, sampleCount)
            return Chunk(fed: max(0, start - leadIn)..<owned.upperBound, owned: owned)
        }
    }

    // MARK: - Helpers

    /// `String.withCString` that tolerates nil, so an optional path can be borrowed the same way.
    private static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> R
    ) rethrows -> R {
        guard let string else { return try body(nil) }
        return try string.withCString(body)
    }

    /// whisper reports segment boundaries in centiseconds.
    private static func seconds(from timestamp: Int64) -> TimeInterval {
        TimeInterval(timestamp) / 100.0
    }
}

/// Carries chunk position into the progress callback, a C function pointer that cannot capture.
private final class ProgressReporter {
    private let chunkIndex: Int
    private let chunkCount: Int

    init(chunkIndex: Int, chunkCount: Int) {
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }

    func report(_ percent: Int32) {
        if chunkCount > 1 {
            Log.progress("Transcribing chunk \(chunkIndex + 1)/\(chunkCount)... \(percent)%")
        } else {
            Log.progress("Transcribing... \(percent)%")
        }
    }
}
