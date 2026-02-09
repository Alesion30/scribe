import Foundation

/// Configuration for the scribe CLI tool.
/// All properties are optional; built-in defaults are used for any missing values.
struct ScribeConfig: Codable {
    var model: String?
    var language: String?
    var recordingDir: String?
    var noMic: Bool?
    var noSystem: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case language
        case recordingDir
        case noMic
        case noSystem
    }

    // MARK: - Defaults

    static let defaultModel = "large-v3-turbo"
    static let defaultLanguage = "auto"

    var resolvedModel: String { model ?? Self.defaultModel }
    var resolvedLanguage: String { language ?? Self.defaultLanguage }
    var resolvedNoMic: Bool { noMic ?? false }
    var resolvedNoSystem: Bool { noSystem ?? false }

    // MARK: - Directories

    /// Base directory for scribe data. Respects SCRIBE_HOME env var, defaults to ~/.scribe.
    static var scribeHome: String {
        if let env = ProcessInfo.processInfo.environment["SCRIBE_HOME"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".scribe")
    }

    /// Directory where whisper models are stored.
    static var modelsDir: String {
        (scribeHome as NSString).appendingPathComponent("models")
    }

    /// Directory where recordings are stored. Can be overridden by config.
    static var recordingsDir: String {
        let config = (try? Self.load()) ?? ScribeConfig()
        return config.resolvedRecordingsDir
    }

    /// Resolved recordings directory for this config instance.
    var resolvedRecordingsDir: String {
        if let dir = recordingDir, !dir.isEmpty {
            return (dir as NSString).expandingTildeInPath
        }
        return (Self.scribeHome as NSString).appendingPathComponent("recordings")
    }

    // MARK: - Loading

    /// Load configuration from scribeHome/config.json.
    /// Returns a default (empty) config if the file does not exist.
    static func load() throws -> ScribeConfig {
        let configPath = (scribeHome as NSString).appendingPathComponent("config.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: configPath) else {
            Log.debug("No config file at \(configPath), using defaults")
            return ScribeConfig()
        }

        Log.debug("Loading config from \(configPath)")
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let decoder = JSONDecoder()
        let config = try decoder.decode(ScribeConfig.self, from: data)
        Log.debug("Config loaded: model=\(config.resolvedModel), language=\(config.resolvedLanguage)")
        return config
    }

    // MARK: - Directory Setup

    /// Create scribeHome, models, and recordings directories if they don't exist.
    func ensureDirectories() throws {
        let fm = FileManager.default
        let dirs = [Self.scribeHome, Self.modelsDir, resolvedRecordingsDir]

        for dir in dirs {
            if !fm.fileExists(atPath: dir) {
                Log.debug("Creating directory: \(dir)")
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }
}
