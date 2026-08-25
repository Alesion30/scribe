import ArgumentParser
import Foundation

// MARK: - Global Options

/// Options shared across all subcommands.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Enable verbose output to stderr.")
    var verbose: Bool = false
}

// MARK: - Root Command

@main
struct Scribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scribe",
        abstract: "macOS audio capture & transcription CLI.",
        discussion: """
            Record audio from the microphone and/or system audio using ScreenCaptureKit, \
            then transcribe with a local whisper model. \
            Run without a subcommand to record and transcribe in one step; \
            the recording is deleted once the transcript is written, unless you pass --keep-audio or -w.
            """,
        version: "0.2.1",
        subcommands: [
            DefaultCommand.self,
            Record.self,
            Transcribe.self,
            Model.self
        ],
        defaultSubcommand: DefaultCommand.self
    )
}

// MARK: - Default Command (record → transcribe)

extension Scribe {
    struct DefaultCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Record audio and transcribe (default action).",
            shouldDisplay: false
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: [.customShort("m"), .long], help: "Whisper model name or path.")
        var model: String?

        @Option(name: .shortAndLong, help: "Output file for transcript (- for stdout).")
        var output: String = "-"

        @Option(name: [.customShort("w"), .long], help: "WAV file save path. A recording saved here is kept.")
        var wavPath: String?

        @Option(name: .shortAndLong, help: "Language hint (ISO 639-1, e.g. ja, en). 'auto' for detection.")
        var language: String?

        @Option(name: [.customShort("f"), .long], help: "Transcript output format.")
        var format: TranscriptFormat?

        @Flag(name: .long, inversion: .prefixedNo, help: "Skip silence with a VAD model before transcribing.")
        var vad: Bool?

        @Option(name: .long, help: "Seconds of audio per whisper call (0 to disable splitting).")
        var chunkLength: Double?

        @Flag(name: .long, help: "Disable microphone input (system audio only).")
        var noMic: Bool = false

        @Flag(name: .long, help: "Disable system audio (microphone only).")
        var noSystem: Bool = false

        @Flag(name: .long, help: "Keep the recording instead of deleting it after transcribing.")
        var keepAudio: Bool = false

        mutating func run() async throws {
            let config = try resolveConfig(
                global: global,
                model: model,
                language: language,
                format: format,
                vad: vad,
                chunkLength: chunkLength,
                noMic: noMic,
                noSystem: noSystem
            )

            // Ensure the model exists before recording so a missing model
            // (or a declined download) doesn't waste a recording session.
            _ = try await ModelManager.ensureModel(config.model)

            // Record
            let recording = try await performRecording(
                captureMic: !config.noMic,
                captureSystem: !config.noSystem,
                wavPath: wavPath,
                config: config
            )

            guard !recording.samples.isEmpty else {
                throw ScribeError.noAudioCaptured
            }

            // Transcribe, streaming segments to the output as they are decoded.
            let writer = try TranscriptWriter(path: output, format: config.format)
            defer { writer.close() }

            try await performTranscription(
                samples: recording.samples,
                config: config,
                showProgress: !writer.isStdout,
                onSegment: writer.write
            )

            if let wav = recording.wavPath {
                let deleted = try disposeRecording(at: wav, userSpecifiedWavPath: wavPath, keepAudio: keepAudio)
                if deleted {
                    Log.status("Recording deleted after transcription (\(recording.spanDescription))")
                } else {
                    Log.status("Recording saved to: \(wav) (\(recording.spanDescription))")
                }
            }
        }
    }
}

// MARK: - Record Subcommand

extension Scribe {
    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Record audio and save as WAV (no transcription). The WAV is always kept."
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .shortAndLong, help: "Output WAV file path.")
        var output: String?

        @Flag(name: .long, help: "Disable microphone input (system audio only).")
        var noMic: Bool = false

        @Flag(name: .long, help: "Disable system audio (microphone only).")
        var noSystem: Bool = false

        mutating func run() async throws {
            let config = try resolveConfig(global: global, noMic: noMic, noSystem: noSystem)

            let recording = try await performRecording(
                captureMic: !config.noMic,
                captureSystem: !config.noSystem,
                wavPath: output,
                config: config
            )

            if let wav = recording.wavPath {
                Log.status("Recording saved to: \(wav) (\(recording.spanDescription))")
            }
        }
    }
}

// MARK: - Transcribe Subcommand

extension Scribe {
    struct Transcribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Transcribe an existing WAV file."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Input WAV file path.")
        var input: String

        @Option(name: [.customShort("m"), .long], help: "Whisper model name or path.")
        var model: String?

        @Option(name: .shortAndLong, help: "Output file for transcript (- for stdout).")
        var output: String = "-"

        @Option(name: .shortAndLong, help: "Language hint (ISO 639-1, e.g. ja, en). 'auto' for detection.")
        var language: String?

        @Option(name: .long, help: "Start offset in seconds.")
        var start: Double = 0

        @Option(name: .long, help: "Length in seconds to transcribe (default: to end of file).")
        var duration: Double?

        @Option(name: [.customShort("f"), .long], help: "Transcript output format.")
        var format: TranscriptFormat?

        @Flag(name: .long, inversion: .prefixedNo, help: "Skip silence with a VAD model before transcribing.")
        var vad: Bool?

        @Option(name: .long, help: "Seconds of audio per whisper call (0 to disable splitting).")
        var chunkLength: Double?

        mutating func run() async throws {
            let config = try resolveConfig(
                global: global,
                model: model,
                language: language,
                format: format,
                vad: vad,
                chunkLength: chunkLength
            )

            // Reject a bad range up front so a long WAV isn't decoded for nothing.
            guard start.isFinite, start >= 0 else {
                throw ScribeError.invalidTimeRange("--start must be zero or greater")
            }
            if let duration {
                guard duration.isFinite, duration > 0 else {
                    throw ScribeError.invalidTimeRange("--duration must be greater than zero")
                }
            }

            let path = (input as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw ScribeError.fileNotFound(path)
            }

            Log.status("Reading \(path)...")
            var samples = try AudioWriter.readWAV(from: path)
            let totalSeconds = Double(samples.count) / AudioWriter.sampleRate
            Log.info("Read \(samples.count) samples (\(String(format: "%.1f", totalSeconds))s)")

            if start > 0 || duration != nil {
                // Slicing past the end yields an empty transcript, which looks like a broken file.
                guard start < totalSeconds else {
                    throw ScribeError.invalidTimeRange(
                        "--start \(String(format: "%.1f", start))s is past the end of the \(String(format: "%.1f", totalSeconds))s audio"
                    )
                }

                samples = AudioWriter.slice(samples, startSeconds: start, durationSeconds: duration)
                let end = start + Double(samples.count) / AudioWriter.sampleRate
                Log.status("Range: \(String(format: "%.1f", start))s - \(String(format: "%.1f", end))s")
            }

            let writer = try TranscriptWriter(path: output, format: config.format)
            defer { writer.close() }

            // Timestamps stay on the source file's clock, so subtitles from a slice still line up.
            let offset = start
            try await performTranscription(
                samples: samples,
                config: config,
                showProgress: !writer.isStdout,
                onSegment: { writer.write(segment: $0.shifted(by: offset)) }
            )
        }
    }
}

// MARK: - Model Subcommand Group

extension Scribe {
    struct Model: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage whisper model files.",
            subcommands: [Download.self, List.self, Remove.self],
            defaultSubcommand: List.self
        )
    }
}

extension Scribe.Model {
    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a whisper model."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Model name (saved as ~/.scribe/models/<name>.bin).")
        var name: String

        @Option(name: .shortAndLong, help: "Download URL for the model file (optional for standard models).")
        var url: String?

        mutating func run() async throws {
            setupVerbose(global)

            let downloadURL: URL
            if let url {
                guard let parsed = URL(string: url) else {
                    throw ScribeError.invalidURL(url)
                }
                downloadURL = parsed
            } else if let known = ModelManager.knownModelURL(for: name) {
                downloadURL = known
            } else {
                throw ScribeError.unknownModel(name)
            }

            try await ModelManager.download(name: name, url: downloadURL)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List downloaded models."
        )

        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            setupVerbose(global)

            let models = try ModelManager.list()

            if models.isEmpty {
                Log.status("No models found in \(ScribeConfig.modelsDir)")
                Log.status("Download a model with: scribe model download <name>")
                return
            }

            // Print table header
            let nameWidth = max(18, models.map(\.name.count).max()! + 2)
            let header = "NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + "SIZE".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "PATH"
            print(header)

            for model in models {
                let row = model.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    + model.formattedSize.padding(toLength: 12, withPad: " ", startingAt: 0)
                    + model.path
                print(row)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a downloaded model."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Model name to remove.")
        var name: String

        mutating func run() async throws {
            setupVerbose(global)
            try ModelManager.remove(name: name)
        }
    }
}

// MARK: - Shared Helpers

/// Resolved configuration combining CLI options, config.json, and built-in defaults.
private struct ResolvedConfig {
    let model: String
    let language: String
    let format: TranscriptFormat
    let vad: Bool
    let chunkLength: Double
    let noMic: Bool
    let noSystem: Bool
    let recordingsDir: String
}

/// Resolve configuration: CLI option > config.json > built-in default.
private func resolveConfig(
    global: GlobalOptions,
    model: String? = nil,
    language: String? = nil,
    format: TranscriptFormat? = nil,
    vad: Bool? = nil,
    chunkLength: Double? = nil,
    noMic: Bool = false,
    noSystem: Bool = false
) throws -> ResolvedConfig {
    setupVerbose(global)

    let fileConfig = try ScribeConfig.load()
    try fileConfig.ensureDirectories()

    if let chunkLength, !chunkLength.isFinite || chunkLength < 0 {
        throw ScribeError.invalidChunkLength(chunkLength)
    }

    let resolved = ResolvedConfig(
        model: model ?? fileConfig.resolvedModel,
        language: language ?? fileConfig.resolvedLanguage,
        format: format ?? fileConfig.resolvedFormat,
        vad: vad ?? fileConfig.resolvedVAD,
        chunkLength: chunkLength ?? fileConfig.resolvedChunkLength,
        noMic: noMic || fileConfig.resolvedNoMic,
        noSystem: noSystem || fileConfig.resolvedNoSystem,
        recordingsDir: fileConfig.resolvedRecordingsDir
    )

    Log.status("Config:")
    Log.status("  model        = \(resolved.model)\(model != nil ? " (CLI)" : fileConfig.model != nil ? " (config)" : " (default)")")
    Log.status("  language     = \(resolved.language)\(language != nil ? " (CLI)" : fileConfig.language != nil ? " (config)" : " (default)")")
    Log.status("  format       = \(resolved.format.rawValue)\(format != nil ? " (CLI)" : fileConfig.format != nil ? " (config)" : " (default)")")
    Log.status("  vad          = \(resolved.vad)\(vad != nil ? " (CLI)" : fileConfig.vad != nil ? " (config)" : " (default)")")
    Log.status("  chunkLength  = \(resolved.chunkLength)s\(chunkLength != nil ? " (CLI)" : fileConfig.chunkLength != nil ? " (config)" : " (default)")")
    Log.status("  noMic        = \(resolved.noMic)\(noMic ? " (CLI)" : fileConfig.noMic == true ? " (config)" : " (default)")")
    Log.status("  noSystem     = \(resolved.noSystem)\(noSystem ? " (CLI)" : fileConfig.noSystem == true ? " (config)" : " (default)")")
    Log.status("  recordingsDir = \(resolved.recordingsDir)\(fileConfig.recordingDir != nil ? " (config)" : " (default)")")

    return resolved
}

private func setupVerbose(_ global: GlobalOptions) {
    Log.verbose = global.verbose
}

/// A finished recording session and the wall-clock span it covered.
private struct RecordingResult {
    let samples: [Float]
    /// nil when nothing was captured and no file was written.
    let wavPath: String?
    let startedAt: Date
    let endedAt: Date

    /// Span for the "saved to" line, e.g. "10:01:33 → 12:09:21, 2h 7m 48s".
    var spanDescription: String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let elapsed = max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
        return "\(clock.string(from: startedAt)) → \(clock.string(from: endedAt)), \(formatDuration(elapsed))"
    }
}

/// Build the default WAV path, named for when the recording started.
func defaultWavPath(startedAt: Date, in directory: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return (directory as NSString).appendingPathComponent("\(formatter.string(from: startedAt)).wav")
}

/// Render a duration as "2h 7m 48s", dropping units that would lead with zero.
func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60

    if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
    if minutes > 0 { return "\(minutes)m \(remainder)s" }
    return "\(remainder)s"
}

/// Drop the recording now that the transcript is written. Returns true when the file was deleted.
///
/// Only a path scribe picked itself is deleted; a location the user named is theirs to keep.
func disposeRecording(at path: String, userSpecifiedWavPath: String?, keepAudio: Bool) throws -> Bool {
    guard userSpecifiedWavPath == nil, !keepAudio else { return false }

    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        throw ScribeError.recordingCleanupFailed(path: path, reason: error.localizedDescription)
    }
    return true
}

/// Record audio, save WAV, return the session result.
private func performRecording(
    captureMic: Bool,
    captureSystem: Bool,
    wavPath: String?,
    config: ResolvedConfig
) async throws -> RecordingResult {
    // Stamp the start before creating source files so every file names the session start.
    let startedAt = Date()
    let output = wavPath.map { ($0 as NSString).expandingTildeInPath }
        ?? defaultWavPath(startedAt: startedAt, in: config.recordingsDir)
    let paths = RecordingPaths(output: output)
    try paths.prepareDirectory()

    let capture = AudioCapture(captureMic: captureMic, captureSystem: captureSystem, paths: paths)

    Log.status("Recording to: \(paths.output)")

    let stopSignal = StopSignal()

    // Set up SIGINT handler for graceful stop
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN) // Ignore default SIGINT handling
    sigintSource.setEventHandler { stopSignal.signal(.interrupted) }
    sigintSource.resume()

    // Start capture in background
    let captureTask = Task {
        do {
            try await capture.startCapture {
                Log.status("Recording... Press Ctrl+C to stop.")
            }
        } catch {
            // startCapture only throws while setting up, so this never races a real recording.
            stopSignal.signal(.failed(error))
        }
    }

    // Wait for SIGINT, or for capture to give up before it ever started
    let reason = await stopSignal.wait()

    sigintSource.cancel()
    signal(SIGINT, SIG_DFL)

    if case .failed(let error) = reason {
        captureTask.cancel()
        for source in capture.stopCapture().sources {
            Log.status("  Source recording kept: \(source.path)")
        }
        throw error
    }

    // Stop capture and close the per-source recordings
    Log.status("") // newline after ^C
    let result = capture.stopCapture()
    let endedAt = Date()

    // Cancel capture task
    captureTask.cancel()

    do {
        let samples = try RecordingFinalizer.finalize(result, to: paths.output)
        return RecordingResult(
            samples: samples,
            wavPath: samples.isEmpty ? nil : paths.output,
            startedAt: startedAt,
            endedAt: endedAt
        )
    } catch {
        Log.error("Failed to write \(paths.output): \(error.localizedDescription)")
        for source in result.sources {
            Log.status("  Source recording kept: \(source.path)")
        }
        throw error
    }
}

/// Transcribe audio samples using whisper.cpp and forward each decoded segment immediately.
/// Downloads the model first if it is a known model that hasn't been fetched yet.
@discardableResult
private func performTranscription(
    samples: [Float],
    config: ResolvedConfig,
    showProgress: Bool,
    onSegment: @escaping (TranscriptSegment) -> Void
) async throws -> [TranscriptSegment] {
    let modelPath = try await ModelManager.ensureModel(config.model)

    var options = TranscribeOptions(language: config.language, chunkLength: config.chunkLength)
    if config.vad {
        options.vadModelPath = try await ModelManager.ensureModel(ModelManager.vadModel.name)
    }

    Log.status("Loading model: \(config.model)")
    let whisper = try WhisperContext(modelPath: modelPath)

    Log.status("Transcribing \(String(format: "%.1f", Double(samples.count) / AudioWriter.sampleRate))s of audio...")
    let segments = try whisper.transcribe(
        samples: samples,
        options: options,
        showProgress: showProgress,
        onSegment: onSegment
    )

    // The progress line is rewritten with \r, so close it before anything else writes to stderr.
    if showProgress {
        eprintln("")
    }

    return segments
}

// MARK: - Errors

enum ScribeError: LocalizedError {
    case noAudioCaptured
    case fileNotFound(String)
    case unknownModel(String)
    case invalidURL(String)
    case cannotWriteOutput(String)
    case invalidTimeRange(String)
    case invalidChunkLength(Double)
    case recordingCleanupFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return "No audio was captured during the recording session"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unknownModel(let name):
            let known = ModelManager.knownModels.map(\.name).joined(separator: ", ")
            return """
                Unknown model '\(name)'. Standard models: \(known)
                For other models, specify a URL with: scribe model download \(name) -u <url>
                """
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .cannotWriteOutput(let path):
            return "Cannot write transcript to: \(path)"
        case .invalidTimeRange(let reason):
            return "Invalid time range: \(reason)"
        case .invalidChunkLength(let seconds):
            return "Invalid --chunk-length \(seconds): must be zero or greater"
        case .recordingCleanupFailed(let path, let reason):
            return """
                Transcription finished, but the recording could not be deleted: \(reason)
                The recording is still at: \(path)
                """
        }
    }
}
