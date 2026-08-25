@preconcurrency import AVFoundation
import CoreMedia
import Accelerate

/// Handles WAV file writing, audio format conversion, mixing, and noise reduction.
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

    // MARK: - Noise Reduction

    /// Floor gain of the noise gate; digital silence makes whisper hallucinate speech.
    private static let gateFloorGain: Float = 0.05

    /// How far under the speaking level the noise floor is allowed to sit, at most.
    private static let noiseFloorCeilingRatio: Float = 0.25

    /// Reduce background noise using a time-domain noise gate.
    /// Estimates the noise floor from the quietest windows, then smoothly
    /// attenuates windows that are at or below the noise floor.
    static func reduceNoise(from samples: [Float]) -> [Float] {
        var result = samples
        reduceNoise(inPlace: &result)
        return result
    }

    /// In-place noise gate, for recordings too large to keep a second copy of.
    static func reduceNoise(inPlace samples: inout [Float]) {
        // Shared with LevelMeter so the active level below is read off the same window size.
        let windowSize = LevelMeter.windowSamples
        guard samples.count > windowSize else { return }

        let sampleCount = samples.count
        let numWindows = (sampleCount + windowSize - 1) / windowSize

        // Compute RMS per window
        var windowRMS = [Float](repeating: 0, count: numWindows)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<numWindows {
                let start = i * windowSize
                let count = min(windowSize, sampleCount - start)
                var sumSq: Float = 0
                vDSP_svesq(base + start, 1, &sumSq, vDSP_Length(count))
                windowRMS[i] = sqrtf(sumSq / Float(count))
            }
        }

        // Estimate noise floor from the quietest 20% of windows
        let sorted = windowRMS.sorted()
        let percentileIdx = max(0, min(numWindows - 1, numWindows * 20 / 100))
        let baseline = sorted[percentileIdx] * 1.5  // margin above baseline

        // With speech packed back to back even the quietest fifth is speech, and a floor estimated
        // from it climbs into the voice. Hold it below the level the recording actually speaks at.
        let activeLevel = sorted[max(0, numWindows - LevelMeter.activeRank(windowCount: numWindows))]
        let noiseFloor = min(baseline, activeLevel * noiseFloorCeilingRatio)

        guard noiseFloor > 0 else { return }

        // Compute per-window gain, ramping from the floor up to unity across the noise floor
        var gains = [Float](repeating: 1.0, count: numWindows)
        for i in 0..<numWindows {
            let rms = windowRMS[i]
            if rms < noiseFloor * 0.5 {
                gains[i] = Self.gateFloorGain
            } else if rms < noiseFloor {
                let ramp = (rms - noiseFloor * 0.5) / (noiseFloor * 0.5)
                gains[i] = Self.gateFloorGain + (1.0 - Self.gateFloorGain) * ramp
            }
        }

        // Smooth gains to avoid clicks (simple 3-tap moving average)
        var smoothed = gains
        for i in 1..<(numWindows - 1) {
            smoothed[i] = (gains[i - 1] + gains[i] + gains[i + 1]) / 3.0
        }

        // Apply gains with per-sample linear interpolation between windows
        samples.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<numWindows {
                let start = i * windowSize
                let end = min(start + windowSize, sampleCount)
                let currentGain = smoothed[i]
                let nextGain = (i + 1 < numWindows) ? smoothed[i + 1] : currentGain

                for j in start..<end {
                    let t = Float(j - start) / Float(windowSize)
                    let gain = currentGain + (nextGain - currentGain) * t
                    buffer[j] *= gain
                }
            }
        }

        let gatedCount = smoothed.filter { $0 < 0.5 }.count
        Log.debug("Noise gate: \(numWindows) windows, noise floor RMS=\(String(format: "%.5f", noiseFloor)), gated \(gatedCount) windows")
    }

    // MARK: - Normalization

    /// Peak-normalize samples so the loudest peak matches `targetPeak`.
    /// Amplifies quiet signals and attenuates loud signals to hit the target.
    static func normalize(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        var result = samples
        normalize(inPlace: &result, targetPeak: targetPeak)
        return result
    }

    /// In-place peak normalization, for recordings too large to keep a second copy of.
    static func normalize(inPlace samples: inout [Float], targetPeak: Float = 0.9) {
        guard !samples.isEmpty else { return }

        let peak = self.peak(of: samples)
        guard peak > 0 else { return }

        let gain = targetPeak / peak

        // Skip if already within 5% of target
        if abs(gain - 1.0) < 0.05 {
            Log.debug("Peak \(String(format: "%.4f", peak)) already near target \(String(format: "%.4f", targetPeak)), skipping")
            return
        }

        applyGain(gain, to: &samples)

        Log.debug("Normalized: peak \(String(format: "%.4f", peak)) → \(String(format: "%.4f", targetPeak)) (gain: \(String(format: "%.1f", gain))x)")
    }

    /// Largest absolute sample value.
    static func peak(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    static func applyGain(_ gain: Float, to samples: inout [Float]) {
        var g = gain
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(buffer.count))
        }
    }

    // MARK: - Slicing

    /// Extract a time range from 16kHz mono samples.
    /// A range running past the end is clamped to the last sample, mirroring `ffmpeg -t`.
    static func slice(_ samples: [Float], startSeconds: Double, durationSeconds: Double? = nil) -> [Float] {
        guard !samples.isEmpty else { return [] }

        // Clamp in seconds first: converting an out-of-range Double to Int traps.
        let totalSamples = Double(samples.count)
        let start = Int(min(max(0, startSeconds * sampleRate), totalSamples))

        let end: Int
        if let durationSeconds {
            end = Int(min(Double(start) + max(0, durationSeconds) * sampleRate, totalSamples))
        } else {
            end = samples.count
        }

        return Array(samples[start..<end])
    }

    // MARK: - WAV File I/O

    /// Samples converted per write when streaming a whole buffer to disk.
    static let writeChunkSize = 1 << 16

    /// Write Float samples as 16kHz/mono/16-bit WAV file.
    static func writeWAV(samples: [Float], to path: String) throws {
        // Chunked so a long recording doesn't need a second full copy as Int16.
        let writer = try StreamingWAVWriter(path: path, refreshInterval: Int.max)

        var offset = 0
        while offset < samples.count {
            let end = min(offset + writeChunkSize, samples.count)
            try writer.append(samples[offset..<end])
            offset = end
        }
        try writer.finalize()

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

    static func readRawWAV(from url: URL) throws -> [Float] {
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

        // Checked before bitsPerSample becomes a divisor, so a malformed zero depth cannot trap
        guard bitsPerSample == 16 else {
            throw AudioWriterError.invalidWAVHeader("Unsupported bit depth: \(bitsPerSample)")
        }

        let bytesPerSample = Int(bitsPerSample) / 8
        let sampleCount = Int(dataSize) / bytesPerSample

        // A truncated file can declare more samples than it stores; the missing tail stays silent
        let readCount = min(sampleCount, (fileData.count - dataOffset) / bytesPerSample)
        var pcm = [Int16](repeating: 0, count: sampleCount)
        _ = pcm.withUnsafeMutableBytes {
            fileData.copyBytes(to: $0, from: dataOffset..<(dataOffset + readCount * bytesPerSample))
        }

        var floats = [Float](repeating: 0, count: sampleCount)
        vDSP_vflt16(pcm, 1, &floats, 1, vDSP_Length(sampleCount))
        var divisor: Float = 32768.0
        vDSP_vsdiv(floats, 1, &divisor, &floats, 1, vDSP_Length(sampleCount))

        // Mix to mono if multi-channel
        let channels = Int(numChannels)
        if channels > 1 {
            let frameCount = floats.count / channels
            var mono = [Float](repeating: 0, count: frameCount)
            floats.withUnsafeBufferPointer { src in
                mono.withUnsafeMutableBufferPointer { dst in
                    guard let input = src.baseAddress, let output = dst.baseAddress else { return }
                    // Each channel is a strided view into the interleaved buffer
                    for ch in 0..<channels {
                        vDSP_vadd(output, 1, input + ch, vDSP_Stride(channels), output, 1, vDSP_Length(frameCount))
                    }
                }
            }
            var divisor = Float(channels)
            vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))
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
final class InputBlockState: @unchecked Sendable {
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
    case fileCreationFailed(String)

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
        case .fileCreationFailed(let path):
            return "Failed to create file: \(path)"
        }
    }
}

// MARK: - Data Helpers

extension Data {
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
