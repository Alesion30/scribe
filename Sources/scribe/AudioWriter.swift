@preconcurrency import AVFoundation
import CoreMedia
import Accelerate

/// Handles WAV file writing, audio format conversion, mixing, and silence removal.
struct AudioWriter {
    /// Target format for whisper.cpp: 16kHz, mono, 16-bit signed PCM.
    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1

    // MARK: - Sample Extraction

    /// Convert a CMSampleBuffer to Float samples normalized to [-1, 1].
    /// Returns interleaved samples when the source is multi-channel.
    static func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            Log.debug("No format description in sample buffer")
            return nil
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            Log.debug("No audio stream basic description")
            return nil
        }

        // Query the required AudioBufferList size first.
        // Non-interleaved stereo needs space for 2 AudioBuffer entries,
        // which exceeds MemoryLayout<AudioBufferList>.size (room for 1).
        var bufferListSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        let audioBufferListRaw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListRaw.deallocate() }
        let audioBufferListPtr = audioBufferListRaw.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            Log.debug("Failed to get audio buffer list: \(status)")
            return nil
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if isNonInterleaved && bufferList.count > 1 {
            // Non-interleaved: each AudioBuffer holds one channel.
            // Extract per-channel data and interleave (L,R,L,R,...).
            var channels: [[Float]] = []
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                guard let floats = convertToFloat(data: data, byteSize: Int(buffer.mDataByteSize), asbd: asbd) else {
                    return nil
                }
                channels.append(floats)
            }
            guard !channels.isEmpty else { return nil }

            let framesPerChannel = channels[0].count
            let channelCount = channels.count
            var interleaved = [Float](repeating: 0, count: framesPerChannel * channelCount)
            for ch in 0..<channelCount {
                for frame in 0..<framesPerChannel {
                    interleaved[frame * channelCount + ch] = channels[ch][frame]
                }
            }
            return interleaved
        } else {
            // Interleaved or single-channel: read from the first buffer.
            guard let buffer = bufferList.first, let data = buffer.mData else {
                Log.debug("Audio buffer has no data")
                return nil
            }
            return convertToFloat(data: data, byteSize: Int(buffer.mDataByteSize), asbd: asbd)
        }
    }

    /// Convert raw audio bytes to Float samples normalized to [-1, 1].
    private static func convertToFloat(data: UnsafeMutableRawPointer, byteSize: Int, asbd: AudioStreamBasicDescription) -> [Float]? {
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            // Float32 samples
            let count = byteSize / MemoryLayout<Float>.size
            let floatPtr = data.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: floatPtr, count: count))
        } else if asbd.mBitsPerChannel == 16 {
            // Int16 samples - convert to Float
            let sampleCount = byteSize / MemoryLayout<Int16>.size
            let int16Ptr = data.bindMemory(to: Int16.self, capacity: sampleCount)
            var floats = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt16(int16Ptr, 1, &floats, 1, vDSP_Length(sampleCount))
            var divisor: Float = 32768.0
            vDSP_vsdiv(floats, 1, &divisor, &floats, 1, vDSP_Length(sampleCount))
            return floats
        } else if asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            // Int32 samples - convert to Float
            let sampleCount = byteSize / MemoryLayout<Int32>.size
            let int32Ptr = data.bindMemory(to: Int32.self, capacity: sampleCount)
            var floats = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt32(int32Ptr, 1, &floats, 1, vDSP_Length(sampleCount))
            var divisor: Float = Float(Int32.max)
            vDSP_vsdiv(floats, 1, &divisor, &floats, 1, vDSP_Length(sampleCount))
            return floats
        }

        Log.debug("Unsupported audio format: \(asbd.mBitsPerChannel)-bit, flags=\(asbd.mFormatFlags)")
        return nil
    }

    // MARK: - Resampling

    /// Resample audio data to 16kHz mono using AVAudioConverter.
    static func resample(_ samples: [Float], fromRate: Double, channels: Int) -> [Float]? {
        guard !samples.isEmpty else { return [] }

        // If already at target format, just mix down to mono if needed
        if fromRate == sampleRate && channels == 1 {
            return samples
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: fromRate,
            channels: AVAudioChannelCount(channels),
            interleaved: channels > 1
        ) else {
            Log.warning("Failed to create input audio format")
            return nil
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: self.channels,
            interleaved: false
        ) else {
            Log.warning("Failed to create output audio format")
            return nil
        }

        let frameCount = AVAudioFrameCount(samples.count / channels)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            Log.warning("Failed to create input PCM buffer")
            return nil
        }
        inputBuffer.frameLength = frameCount

        // Copy samples into the input buffer
        if channels > 1 && inputFormat.isInterleaved {
            // Interleaved: copy directly into first buffer's float channel data
            if let channelData = inputBuffer.floatChannelData {
                memcpy(channelData[0], samples, samples.count * MemoryLayout<Float>.size)
            }
        } else if channels > 1 {
            // Non-interleaved multi-channel: deinterleave
            if let channelData = inputBuffer.floatChannelData {
                for ch in 0..<channels {
                    for frame in 0..<Int(frameCount) {
                        channelData[ch][frame] = samples[frame * channels + ch]
                    }
                }
            }
        } else {
            // Mono
            if let channelData = inputBuffer.floatChannelData {
                memcpy(channelData[0], samples, samples.count * MemoryLayout<Float>.size)
            }
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Log.warning("Failed to create audio converter")
            return nil
        }

        let outputFrameCount = AVAudioFrameCount(
            Double(frameCount) * (sampleRate / fromRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount + 1) else {
            Log.warning("Failed to create output PCM buffer")
            return nil
        }

        var error: NSError?
        let inputState = InputBlockState(buffer: inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputState.consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputState.consumed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        let conversionStatus = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if let error = error {
            Log.warning("Audio conversion failed: \(error.localizedDescription)")
            return nil
        }
        if conversionStatus == .error {
            Log.warning("Audio conversion returned error status")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    // MARK: - Mixing

    /// Mix two audio buffers (e.g., microphone + system) by summing and clamping.
    /// The shorter buffer is padded with zeros. Output is clamped to [-1, 1].
    static func mix(_ bufferA: [Float], _ bufferB: [Float]) -> [Float] {
        if bufferA.isEmpty { return bufferB }
        if bufferB.isEmpty { return bufferA }

        let length = max(bufferA.count, bufferB.count)

        // Pad shorter buffer with zeros
        var a = bufferA
        var b = bufferB
        if a.count < length { a.append(contentsOf: [Float](repeating: 0, count: length - a.count)) }
        if b.count < length { b.append(contentsOf: [Float](repeating: 0, count: length - b.count)) }

        // Sum using vDSP (no averaging — avoids halving when one source is silent)
        var result = [Float](repeating: 0, count: length)
        vDSP_vadd(a, 1, b, 1, &result, 1, vDSP_Length(length))

        // Clamp to [-1, 1]
        var lowerBound: Float = -1.0
        var upperBound: Float = 1.0
        vDSP_vclip(result, 1, &lowerBound, &upperBound, &result, 1, vDSP_Length(length))

        return result
    }

    // MARK: - Normalization

    /// Peak-normalize samples so the loudest peak reaches `targetPeak`.
    /// Leaves headroom to avoid clipping. No-op if the signal is already louder.
    static func normalize(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        guard !samples.isEmpty else { return [] }

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        guard peak > 0 else { return samples }

        let gain = targetPeak / peak
        if gain <= 1.0 {
            Log.debug("Peak \(String(format: "%.4f", peak)) already above target, skipping normalization")
            return samples
        }

        var result = [Float](repeating: 0, count: samples.count)
        var g = gain
        vDSP_vsmul(samples, 1, &g, &result, 1, vDSP_Length(samples.count))

        Log.debug("Normalized: peak \(String(format: "%.4f", peak)) → \(String(format: "%.4f", targetPeak)) (gain: \(String(format: "%.1f", gain))x)")
        return result
    }

    // MARK: - Silence Removal

    /// Remove silence segments based on RMS threshold.
    /// Uses a sliding window approach, keeping windows above the threshold with small padding.
    static func removeSilence(
        from samples: [Float],
        sampleRate: Double = 16000,
        windowSize: Int = 1600,
        threshold: Float = 0.01
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let totalWindows = (samples.count + windowSize - 1) / windowSize
        var keepWindow = [Bool](repeating: false, count: totalWindows)

        // Calculate RMS for each window and mark which to keep
        for i in 0..<totalWindows {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            let windowSamples = Array(samples[start..<end])
            let count = vDSP_Length(windowSamples.count)

            var sumSquares: Float = 0
            vDSP_svesq(windowSamples, 1, &sumSquares, count)
            let rms = sqrtf(sumSquares / Float(windowSamples.count))

            if rms >= threshold {
                keepWindow[i] = true
            }
        }

        // Add padding: keep 1 window before and after each voiced window
        let paddingWindows = 1
        var paddedKeep = keepWindow
        for i in 0..<totalWindows {
            if keepWindow[i] {
                for j in max(0, i - paddingWindows)...min(totalWindows - 1, i + paddingWindows) {
                    paddedKeep[j] = true
                }
            }
        }

        // Collect kept samples
        var result = [Float]()
        result.reserveCapacity(samples.count)
        for i in 0..<totalWindows {
            if paddedKeep[i] {
                let start = i * windowSize
                let end = min(start + windowSize, samples.count)
                result.append(contentsOf: samples[start..<end])
            }
        }

        let removedDuration = Double(samples.count - result.count) / sampleRate
        if removedDuration > 0.1 {
            Log.debug("Removed \(String(format: "%.1f", removedDuration))s of silence")
        }

        return result
    }

    // MARK: - WAV File I/O

    /// Write Float samples as 16kHz/mono/16-bit WAV file.
    static func writeWAV(samples: [Float], to path: String) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleRateInt = UInt32(sampleRate)
        let byteRate = sampleRateInt * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))       // chunk size
        data.append(littleEndian: UInt16(1))        // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: sampleRateInt)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        // Convert Float [-1,1] to Int16 samples
        var clampedSamples = samples
        var lowerBound: Float = -1.0
        var upperBound: Float = 1.0
        vDSP_vclip(clampedSamples, 1, &lowerBound, &upperBound, &clampedSamples, 1, vDSP_Length(samples.count))

        var scaled = [Float](repeating: 0, count: samples.count)
        var scale: Float = 32767.0
        vDSP_vsmul(clampedSamples, 1, &scale, &scaled, 1, vDSP_Length(samples.count))

        for sample in scaled {
            let int16Value = Int16(max(-32768, min(32767, Int32(sample))))
            data.append(littleEndian: int16Value)
        }

        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
        Log.debug("Wrote WAV: \(path) (\(samples.count) samples, \(String(format: "%.1f", Double(samples.count) / sampleRate))s)")
    }

    /// Read WAV file and return Float samples normalized to [-1, 1].
    static func readWAV(from path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)

        // Try reading with AVAudioFile first for broader format support
        if let samples = try? readWithAVAudioFile(from: url) {
            return samples
        }

        // Fall back to manual WAV parsing
        return try readRawWAV(from: url)
    }

    // MARK: - Private Helpers

    private static func readWithAVAudioFile(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioWriterError.failedToCreateBuffer
        }
        try audioFile.read(into: buffer)

        // If already mono float at 16kHz, return directly
        if format.sampleRate == sampleRate && format.channelCount == 1 {
            guard let channelData = buffer.floatChannelData else {
                throw AudioWriterError.noChannelData
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        // Otherwise, resample
        guard let channelData = buffer.floatChannelData else {
            throw AudioWriterError.noChannelData
        }

        // Mix to mono if multi-channel
        let count = Int(buffer.frameLength)
        var monoSamples: [Float]
        if format.channelCount > 1 {
            monoSamples = [Float](repeating: 0, count: count)
            for ch in 0..<Int(format.channelCount) {
                let channelSamples = Array(UnsafeBufferPointer(start: channelData[ch], count: count))
                vDSP_vadd(monoSamples, 1, channelSamples, 1, &monoSamples, 1, vDSP_Length(count))
            }
            var divisor = Float(format.channelCount)
            vDSP_vsdiv(monoSamples, 1, &divisor, &monoSamples, 1, vDSP_Length(count))
        } else {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        if format.sampleRate != sampleRate {
            guard let resampled = resample(monoSamples, fromRate: format.sampleRate, channels: 1) else {
                throw AudioWriterError.resamplingFailed
            }
            return resampled
        }

        return monoSamples
    }

    private static func readRawWAV(from url: URL) throws -> [Float] {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 44 else {
            throw AudioWriterError.invalidWAVHeader("File too small for WAV header")
        }

        // Validate RIFF header
        let riff = String(data: fileData[0..<4], encoding: .ascii)
        let wave = String(data: fileData[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else {
            throw AudioWriterError.invalidWAVHeader("Not a valid RIFF/WAVE file")
        }

        // Parse fmt chunk
        let fmtTag = String(data: fileData[12..<16], encoding: .ascii)
        guard fmtTag == "fmt " else {
            throw AudioWriterError.invalidWAVHeader("Missing fmt chunk")
        }

        let audioFormat: UInt16 = fileData.readLittleEndian(at: 20)
        let numChannels: UInt16 = fileData.readLittleEndian(at: 22)
        let fileSampleRate: UInt32 = fileData.readLittleEndian(at: 24)
        let bitsPerSample: UInt16 = fileData.readLittleEndian(at: 34)

        guard audioFormat == 1 else {
            throw AudioWriterError.invalidWAVHeader("Not PCM format (format tag: \(audioFormat))")
        }

        // Find data chunk (it may not be at offset 36 if there are extra chunks)
        var dataOffset = 12
        var dataSize: UInt32 = 0
        while dataOffset + 8 <= fileData.count {
            let chunkID = String(data: fileData[dataOffset..<dataOffset + 4], encoding: .ascii)
            let chunkSize: UInt32 = fileData.readLittleEndian(at: dataOffset + 4)
            if chunkID == "data" {
                dataSize = chunkSize
                dataOffset += 8
                break
            }
            dataOffset += 8 + Int(chunkSize)
        }

        guard dataSize > 0 else {
            throw AudioWriterError.invalidWAVHeader("No data chunk found")
        }

        let bytesPerSample = Int(bitsPerSample) / 8
        let sampleCount = Int(dataSize) / bytesPerSample

        var floats: [Float]
        if bitsPerSample == 16 {
            let int16Count = sampleCount
            floats = [Float](repeating: 0, count: int16Count)
            for i in 0..<int16Count {
                let offset = dataOffset + i * 2
                guard offset + 1 < fileData.count else { break }
                let value: Int16 = fileData.readLittleEndian(at: offset)
                floats[i] = Float(value) / 32768.0
            }
        } else {
            throw AudioWriterError.invalidWAVHeader("Unsupported bit depth: \(bitsPerSample)")
        }

        // Mix to mono if multi-channel
        if numChannels > 1 {
            let frameCount = floats.count / Int(numChannels)
            var mono = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<Int(numChannels) {
                    sum += floats[frame * Int(numChannels) + ch]
                }
                mono[frame] = sum / Float(numChannels)
            }
            floats = mono
        }

        // Resample if needed
        if Double(fileSampleRate) != sampleRate {
            guard let resampled = resample(floats, fromRate: Double(fileSampleRate), channels: 1) else {
                throw AudioWriterError.resamplingFailed
            }
            return resampled
        }

        return floats
    }
}

// MARK: - Audio Converter Helper

/// Thread-safe state wrapper for AVAudioConverterInputBlock.
private final class InputBlockState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: - Error Types

enum AudioWriterError: LocalizedError {
    case failedToCreateBuffer
    case noChannelData
    case resamplingFailed
    case invalidWAVHeader(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateBuffer:
            return "Failed to create audio buffer"
        case .noChannelData:
            return "No channel data in audio buffer"
        case .resamplingFailed:
            return "Audio resampling failed"
        case .invalidWAVHeader(let detail):
            return "Invalid WAV header: \(detail)"
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        withUnsafePointer(to: &le) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return self[offset..<offset + size].withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
}
