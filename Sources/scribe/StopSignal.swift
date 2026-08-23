import Foundation

/// Why a recording session ended.
enum StopReason {
    /// The user pressed Ctrl+C.
    case interrupted
    /// Capture could not be started; nothing was recorded.
    case failed(any Error)
}

/// One-shot handoff from whichever ends the recording first.
///
/// The signal can arrive from a signal-source handler or from the capture task,
/// possibly before anyone is waiting, so the reason is held until it is collected.
/// Later signals are dropped: the first one is what stopped the recording.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StopReason, Never>?
    private var pending: StopReason?
    private var isSignalled = false

    func signal(_ reason: StopReason) {
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true

        let waiting = continuation
        continuation = nil
        if waiting == nil {
            pending = reason
        }
        lock.unlock()

        waiting?.resume(returning: reason)
    }

    func wait() async -> StopReason {
        await withCheckedContinuation { (cont: CheckedContinuation<StopReason, Never>) in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                cont.resume(returning: pending)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}
