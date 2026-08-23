import Foundation

/// Keeps one capture source pinned to the host clock while it streams to disk.
///
/// Buffers carry the host-clock instant of their first frame — AVAudioEngine through
/// `AVAudioTime.hostTime`, ScreenCaptureKit through the sample buffer's presentation timestamp.
/// Writing them back to back would close whatever gap the capture dropped, pulling everything
/// after it earlier and leaving the two sources offset against each other in the mix.
struct CaptureTimeline {
    /// How far a buffer may land from where it was expected before the gap is filled with silence.
    ///
    /// Loose enough to ride out timestamp jitter, tight enough that a dropped buffer is restored.
    static let defaultTolerance: Double = 0.05

    /// Host-clock instant of the first sample written, once a buffer has carried a timestamp.
    private(set) var startSeconds: Double?

    private let tolerance: Int

    init(tolerance: Double = CaptureTimeline.defaultTolerance) {
        self.tolerance = Int((tolerance * AudioWriter.sampleRate).rounded())
    }

    /// Silence to write before a buffer stamped `hostSeconds`, given how much is already written.
    ///
    /// An untimed buffer goes wherever it lands: without a stamp there is nothing to place it against.
    mutating func silenceNeeded(before hostSeconds: Double?, written: Int) -> Int {
        guard let hostSeconds else { return 0 }

        guard let startSeconds else {
            // Whatever is already written came before the first stamp, so the origin sits that far back.
            self.startSeconds = hostSeconds - Double(written) / AudioWriter.sampleRate
            return 0
        }

        let expected = Int(((hostSeconds - startSeconds) * AudioWriter.sampleRate).rounded())
        let missing = expected - written
        // A buffer stamped early is written where it lands: one source cannot overlap itself.
        return missing > tolerance ? missing : 0
    }
}
