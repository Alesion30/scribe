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

        @Flag(name: .long, help: "Disable microphone input (system audio only).")
        var noMic: Bool = false

        @Flag(name: .long, help: "Disable system audio (microphone only).")
        var noSystem: Bool = false

        mutating func run() async throws {
            let config = try resolveConfig(global: global, model: model, language: language, noMic: noMic, noSystem: noSystem)

            // Ensure the model exists before recording so a missing model
            // (or a declined download) doesn't waste a recording session.
            _ = try await ModelManager.ensureModel(config.model)

            // Record
            let (samples, wavFile) = try await performRecording(
                captureMic: !config.noMic,
                captureSystem: !config.noSystem,
                wavPath: wavPath,
                config: config
            )

            guard !samples.isEmpty else {
                throw ScribeError.noAudioCaptured
            }

            // Transcribe
            let text = try await performTranscription(
                samples: samples,
                modelName: config.model,
                language: config.language
            )

            // Output
            try writeOutput(text, to: output)

            if let wav = wavFile {
                Log.status("Recording saved to: \(wav)")
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

            let (_, wavFile) = try await performRecording(
                captureMic: !config.noMic,
                captureSystem: !config.noSystem,
                wavPath: output,
                config: config
            )

            if let wav = wavFile {
                Log.status("Recording saved to: \(wav)")
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

        mutating func run() async throws {
            let config = try resolveConfig(global: global, model: model, language: language)

            let path = (input as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw ScribeError.fileNotFound(path)
            }

            Log.status("Reading \(path)...")
            let samples = try AudioWriter.readWAV(from: path)
            Log.info("Read \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / AudioWriter.sampleRate))s)")

            let text = try await performTranscription(
                samples: samples,
                modelName: config.model,
                language: config.language
            )

            try writeOutput(text, to: output)
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
    let noMic: Bool
    let noSystem: Bool
    let recordingsDir: String
}

/// Resolve configuration: CLI option > config.json > built-in default.
private func resolveConfig(
    global: GlobalOptions,
    model: String? = nil,
    language: String? = nil,
    noMic: Bool = false,
    noSystem: Bool = false
) throws -> ResolvedConfig {
    setupVerbose(global)

    let fileConfig = try ScribeConfig.load()
    try fileConfig.ensureDirectories()

    let resolved = ResolvedConfig(
        model: model ?? fileConfig.resolvedModel,
        language: language ?? fileConfig.resolvedLanguage,
        noMic: noMic || fileConfig.resolvedNoMic,
        noSystem: noSystem || fileConfig.resolvedNoSystem,
        recordingsDir: fileConfig.resolvedRecordingsDir
    )

    Log.status("Config:")
    Log.status("  model        = \(resolved.model)\(model != nil ? " (CLI)" : fileConfig.model != nil ? " (config)" : " (default)")")
    Log.status("  language     = \(resolved.language)\(language != nil ? " (CLI)" : fileConfig.language != nil ? " (config)" : " (default)")")
    Log.status("  noMic        = \(resolved.noMic)\(noMic ? " (CLI)" : fileConfig.noMic == true ? " (config)" : " (default)")")
    Log.status("  noSystem     = \(resolved.noSystem)\(noSystem ? " (CLI)" : fileConfig.noSystem == true ? " (config)" : " (default)")")
    Log.status("  recordingsDir = \(resolved.recordingsDir)\(fileConfig.recordingDir != nil ? " (config)" : " (default)")")

    return resolved
}

private func setupVerbose(_ global: GlobalOptions) {
    Log.verbose = global.verbose
}

/// Record audio, save WAV, return (samples, wavPath).
private func performRecording(
    captureMic: Bool,
    captureSystem: Bool,
    wavPath: String?,
    config: ResolvedConfig
) async throws -> ([Float], String?) {
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

    // Start capture in background
    let captureTask = Task {
        try await capture.startCapture()
    }

    // Wait for SIGINT
    await stopTask.value

    // Stop capture and get samples
    Log.status("") // newline after ^C
    let samples = capture.stopCapture()
    sigintSource.cancel()
    signal(SIGINT, SIG_DFL)

    // Cancel capture task
    captureTask.cancel()

    // Save WAV
    let resolvedWavPath: String
    if let explicit = wavPath {
        resolvedWavPath = (explicit as NSString).expandingTildeInPath
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        resolvedWavPath = (config.recordingsDir as NSString).appendingPathComponent("\(timestamp).wav")
    }

    if !samples.isEmpty {
        try AudioWriter.writeWAV(samples: samples, to: resolvedWavPath)
        return (samples, resolvedWavPath)
    }

    return ([], nil)
}

/// Transcribe audio samples using whisper.cpp.
/// Downloads the model first if it is a known model that hasn't been fetched yet.
private func performTranscription(
    samples: [Float],
    modelName: String,
    language: String
) async throws -> String {
    let modelPath = try await ModelManager.ensureModel(modelName)

    Log.status("Loading model: \(modelName)")
    let whisper = try WhisperContext(modelPath: modelPath)

    Log.status("Transcribing \(String(format: "%.1f", Double(samples.count) / AudioWriter.sampleRate))s of audio...")
    let text = try whisper.transcribe(samples: samples, language: language)

    if Log.verbose {
        FileHandle.standardError.write(Data("\n".utf8))
    }

    return text
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
        }
    }
}
