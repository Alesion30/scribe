@preconcurrency import AVFoundation

/// Resamples a live capture stream to 16 kHz mono, one chunk at a time.
///
/// The converter is kept alive across calls so its filter state carries over
/// chunk boundaries. AudioWriter.resample builds a fresh converter per call and
/// can only be used on a complete recording.
final class StreamingResampler {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let channels: Int
    private let ratio: Double

    /// - Returns: nil when the source format cannot be represented or converted.
    init?(sampleRate: Double, channels: Int) {
        guard sampleRate > 0, channels > 0 else { return nil }

        self.channels = channels
        self.ratio = AudioWriter.sampleRate / sampleRate

        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: channels > 1
        ) else {
            Log.warning("Failed to create input audio format (\(sampleRate) Hz, \(channels)ch)")
            return nil
        }

        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioWriter.sampleRate,
            channels: AudioWriter.channels,
            interleaved: false
        ) else {
            Log.warning("Failed to create output audio format")
            return nil
        }

        self.inputFormat = input
        self.outputFormat = output

        if sampleRate == AudioWriter.sampleRate && channels == 1 {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                Log.warning("Failed to create audio converter (\(sampleRate) Hz, \(channels)ch -> 16 kHz mono)")
                return nil
            }
            self.converter = converter
        }
    }

    /// Convert one interleaved chunk to 16 kHz mono. Returns nil if conversion fails.
    func resample(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }

        let frameCount = AVAudioFrameCount(samples.count / channels)
        guard frameCount > 0 else { return [] }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            Log.warning("Failed to create input PCM buffer")
            return nil
        }
        inputBuffer.frameLength = frameCount

        guard let inputChannelData = inputBuffer.floatChannelData else {
            Log.warning("No channel data in input PCM buffer")
            return nil
        }

        if channels > 1 && !inputFormat.isInterleaved {
            for channel in 0..<channels {
                for frame in 0..<Int(frameCount) {
                    inputChannelData[channel][frame] = samples[frame * channels + channel]
                }
            }
        } else {
            memcpy(inputChannelData[0], samples, Int(frameCount) * channels * MemoryLayout<Float>.size)
        }

        // Leave slack for the converter's own latency on top of the rate ratio.
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            Log.warning("Failed to create output PCM buffer")
            return nil
        }

        let inputState = InputBlockState(buffer: inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputState.consumed {
                // Not endOfStream: the converter must stay open for the next chunk.
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.consumed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        var converted: [Float] = []
        while true {
            outputBuffer.frameLength = 0

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let error {
                Log.warning("Audio conversion failed: \(error.localizedDescription)")
                return nil
            }
            if status == .error {
                Log.warning("Audio conversion returned error status")
                return nil
            }

            let produced = Int(outputBuffer.frameLength)
            if produced > 0, let channelData = outputBuffer.floatChannelData {
                converted.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: produced))
            }

            // haveData means the output buffer filled up before the input was drained.
            if status != .haveData || produced == 0 { break }
        }

        return converted
    }
}
