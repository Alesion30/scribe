import Foundation

/// Information about a downloaded whisper model.
struct ModelInfo {
    let name: String
    let size: UInt64
    let path: String

    /// Human-readable file size string.
    var formattedSize: String {
        ModelManager.formatBytes(size)
    }
}

/// Manages whisper model files: download, list, and remove.
enum ModelManager {

    // MARK: - Path Resolution

    /// Resolve a model name or path to an absolute file path.
    /// If the input starts with `/` or `~`, treat it as a direct path.
    /// Otherwise, look for it in the models directory as {name}.bin.
    static func resolveModelPath(_ nameOrPath: String) -> String {
        if nameOrPath.hasPrefix("/") {
            return nameOrPath
        }
        if nameOrPath.hasPrefix("~") {
            return (nameOrPath as NSString).expandingTildeInPath
        }
        let name = nameOrPath.hasSuffix(".bin") ? String(nameOrPath.dropLast(4)) : nameOrPath
        return (ScribeConfig.modelsDir as NSString).appendingPathComponent("\(name).bin")
    }

    // MARK: - Download

    /// Download a model from the given URL and save it to the models directory.
    static func download(name: String, url: URL) async throws {
        let fm = FileManager.default
        let modelsDir = ScribeConfig.modelsDir

        if !fm.fileExists(atPath: modelsDir) {
            Log.debug("Creating models directory: \(modelsDir)")
            try fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        }

        let destPath = (modelsDir as NSString).appendingPathComponent("\(name).bin")

        if fm.fileExists(atPath: destPath) {
            Log.warning("Model '\(name)' already exists at \(destPath), overwriting")
            try fm.removeItem(atPath: destPath)
        }

        Log.status("Downloading model '\(name)' from \(url.absoluteString)")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)

        let totalBytes = (response as? HTTPURLResponse)
            .flatMap { Int64($0.value(forHTTPHeaderField: "Content-Length") ?? "") }

        let tempPath = destPath + ".download"
        fm.createFile(atPath: tempPath, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        defer { try? fileHandle.close() }

        var downloadedBytes: Int64 = 0
        let bufferSize = 256 * 1024
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if let total = totalBytes, total > 0 {
                    let pct = Double(downloadedBytes) / Double(total) * 100.0
                    Log.progress("Downloading \(name): \(formatBytes(UInt64(downloadedBytes)))/\(formatBytes(UInt64(total))) (\(String(format: "%.1f", pct))%)")
                } else {
                    Log.progress("Downloading \(name): \(formatBytes(UInt64(downloadedBytes)))")
                }
            }
        }

        if !buffer.isEmpty {
            fileHandle.write(buffer)
            downloadedBytes += Int64(buffer.count)
        }

        try fileHandle.close()
        try fm.moveItem(atPath: tempPath, toPath: destPath)

        // Print newline after progress overwrites
        FileHandle.standardError.write(Data("\n".utf8))
        Log.status("Model '\(name)' downloaded to \(destPath) (\(formatBytes(UInt64(downloadedBytes))))")
    }

    // MARK: - List

    /// List all downloaded models in the models directory.
    static func list() throws -> [ModelInfo] {
        let fm = FileManager.default
        let modelsDir = ScribeConfig.modelsDir

        guard fm.fileExists(atPath: modelsDir) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(atPath: modelsDir)
        return contents
            .filter { $0.hasSuffix(".bin") }
            .sorted()
            .compactMap { filename -> ModelInfo? in
                let path = (modelsDir as NSString).appendingPathComponent(filename)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64 else {
                    return nil
                }
                let name = String(filename.dropLast(4)) // remove .bin
                return ModelInfo(name: name, size: size, path: path)
            }
    }

    // MARK: - Remove

    /// Remove a downloaded model by name.
    static func remove(name: String) throws {
        let fm = FileManager.default
        let path = (ScribeConfig.modelsDir as NSString).appendingPathComponent("\(name).bin")

        guard fm.fileExists(atPath: path) else {
            throw ModelManagerError.modelNotFound(name)
        }

        try fm.removeItem(atPath: path)
        Log.status("Removed model '\(name)'")
    }

    // MARK: - Helpers

    /// Format a byte count into a human-readable string.
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

enum ModelManagerError: LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Model '\(name)' not found in \(ScribeConfig.modelsDir)"
        }
    }
}
