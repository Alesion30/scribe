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
            Run without a subcommand to record and transcribe in one step.
            """,
        version: "0.1.0",
        subcommands: [
            DefaultCommand.self,
            Record.self,
            Transcribe.self,
            Model.self,
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

        @Option(name: [.customShort("w"), .long], help: "WAV file save path.")
        var wavPath: String?

        @Option(name: .shortAndLong, help: "Language hint (ISO 639-1, e.g. ja, en). 'auto' for detection.")
        var language: String?

        @Option(name: [.customShort("f"), .long], help: "Transcript output format.")
        var format: TranscriptFormat?

        @Flag(name: .long, help: "Disable microphone input (system audio only).")
        var noMic: Bool = false

        @Flag(name: .long, help: "Disable system audio (microphone only).")
        var noSystem: Bool = false

        mutating func run() async throws {
            let config = try resolveConfig(global: global, model: model, language: language, format: format, noMic: noMic, noSystem: noSystem)

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

            // Transcribe
            let segments = try await performTranscription(
                samples: recording.samples,
                modelName: config.model,
                language: config.language
            )

            // Output
            try writeOutput(config.format.render(segments), to: output)

            if let wav = recording.wavPath {
                Log.status("Recording saved to: \(wav) (\(recording.spanDescription))")
            }
        }
    }
}

// MARK: - Record Subcommand

extension Scribe {
    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Record audio and save as WAV (no transcription)."
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

        mutating func run() async throws {
            let config = try resolveConfig(global: global, model: model, language: language, format: format)

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

            let segments = try await performTranscription(
                samples: samples,
                modelName: config.model,
                language: config.language
            )

            try writeOutput(config.format.render(segments), to: output)
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
    noMic: Bool = false,
    noSystem: Bool = false
) throws -> ResolvedConfig {
    setupVerbose(global)

    let fileConfig = try ScribeConfig.load()
    try fileConfig.ensureDirectories()

    let resolved = ResolvedConfig(
        model: model ?? fileConfig.resolvedModel,
        language: language ?? fileConfig.resolvedLanguage,
        format: format ?? fileConfig.resolvedFormat,
        noMic: noMic || fileConfig.resolvedNoMic,
        noSystem: noSystem || fileConfig.resolvedNoSystem,
        recordingsDir: fileConfig.resolvedRecordingsDir
    )

    Log.status("Config:")
    Log.status("  model        = \(resolved.model)\(model != nil ? " (CLI)" : fileConfig.model != nil ? " (config)" : " (default)")")
    Log.status("  language     = \(resolved.language)\(language != nil ? " (CLI)" : fileConfig.language != nil ? " (config)" : " (default)")")
    Log.status("  format       = \(resolved.format.rawValue)\(format != nil ? " (CLI)" : fileConfig.format != nil ? " (config)" : " (default)")")
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

/// Record audio, save WAV, return the session result.
private func performRecording(
    captureMic: Bool,
    captureSystem: Bool,
    wavPath: String?,
    config: ResolvedConfig
) async throws -> RecordingResult {
    let capture = AudioCapture(captureMic: captureMic, captureSystem: captureSystem)

    Log.status("Recording... Press Ctrl+C to stop.")

    // Set up SIGINT handler for graceful stop
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN) // Ignore default SIGINT handling

    let stopTask = Task {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sigintSource.setEventHandler {
                cont.resume()
            }
            sigintSource.resume()
        }
    }

    // Stamp the start here: naming the WAV by its end time hides the recorded span.
    let startedAt = Date()

    // Start capture in background
    let captureTask = Task {
        try await capture.startCapture()
    }

    // Wait for SIGINT
    await stopTask.value

    // Stop capture and get samples
    Log.status("") // newline after ^C
    let samples = capture.stopCapture()
    let endedAt = Date()
    sigintSource.cancel()
    signal(SIGINT, SIG_DFL)

    // Cancel capture task
    captureTask.cancel()

    // Save WAV
    let resolvedWavPath: String
    if let explicit = wavPath {
        resolvedWavPath = (explicit as NSString).expandingTildeInPath
    } else {
        resolvedWavPath = defaultWavPath(startedAt: startedAt, in: config.recordingsDir)
    }

    if !samples.isEmpty {
        try AudioWriter.writeWAV(samples: samples, to: resolvedWavPath)
        return RecordingResult(samples: samples, wavPath: resolvedWavPath, startedAt: startedAt, endedAt: endedAt)
    }

    return RecordingResult(samples: [], wavPath: nil, startedAt: startedAt, endedAt: endedAt)
}

/// Transcribe audio samples using whisper.cpp.
/// Downloads the model first if it is a known model that hasn't been fetched yet.
private func performTranscription(
    samples: [Float],
    modelName: String,
    language: String
) async throws -> [TranscriptSegment] {
    let modelPath = try await ModelManager.ensureModel(modelName)

    Log.status("Loading model: \(modelName)")
    let whisper = try WhisperContext(modelPath: modelPath)

    Log.status("Transcribing \(String(format: "%.1f", Double(samples.count) / AudioWriter.sampleRate))s of audio...")
    let segments = try whisper.transcribe(samples: samples, language: language)

    if Log.verbose {
        FileHandle.standardError.write(Data("\n".utf8))
    }

    return segments
}

/// Write text to file or stdout.
private func writeOutput(_ text: String, to path: String) throws {
    if path == "-" {
        print(text)
    } else {
        let expandedPath = (path as NSString).expandingTildeInPath
        try text.write(toFile: expandedPath, atomically: true, encoding: .utf8)
        Log.status("Transcript written to: \(expandedPath)")
    }
}

// MARK: - Errors

enum ScribeError: LocalizedError {
    case noAudioCaptured
    case fileNotFound(String)
    case unknownModel(String)
    case invalidURL(String)
    case invalidTimeRange(String)

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
        case .invalidTimeRange(let reason):
            return "Invalid time range: \(reason)"
        }
    }
}
