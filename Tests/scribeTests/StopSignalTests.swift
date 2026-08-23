import Foundation
import Testing
@testable import scribe

/// Tests for the handoff that ends a recording, so a capture that never starts
/// stops the session instead of leaving it waiting for a Ctrl+C that means nothing.
@Suite("Stop Signal")
struct StopSignalTests {

    private struct CaptureFailure: Error {}

    @Test("待機中に届いた通知で wait が返る")
    func deliversToWaiter() async {
        let signal = StopSignal()

        Task {
            signal.signal(.interrupted)
        }

        guard case .interrupted = await signal.wait() else {
            Issue.record("Expected .interrupted")
            return
        }
    }

    @Test("待機前に届いた通知も取りこぼさない")
    func holdsReasonUntilCollected() async {
        let signal = StopSignal()
        signal.signal(.failed(CaptureFailure()))

        guard case .failed(let error) = await signal.wait() else {
            Issue.record("Expected .failed")
            return
        }
        #expect(error is CaptureFailure)
    }

    @Test("最初の通知だけが採用される")
    func firstSignalWins() async {
        let signal = StopSignal()
        signal.signal(.failed(CaptureFailure()))
        signal.signal(.interrupted)

        guard case .failed = await signal.wait() else {
            Issue.record("Expected the first reason to win")
            return
        }
    }

    @Test("複数スレッドから同時に通知しても 1 つに決まる")
    func concurrentSignalsResolveToOne() async {
        let signal = StopSignal()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            signal.signal(index.isMultiple(of: 2) ? .interrupted : .failed(CaptureFailure()))
        }

        // Any reason is fine; the point is that wait() returns exactly once without crashing.
        _ = await signal.wait()
    }
}
