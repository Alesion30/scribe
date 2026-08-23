import Foundation
import Testing
@testable import scribe

/// Tests for how a finished recording is named and reported.
@Suite("Recording Naming")
struct RecordingNamingTests {

    // MARK: - Helpers

    /// Build a Date from local wall-clock components, matching how DateFormatter renders it.
    static func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    // MARK: - Filename

    @Test("The WAV is named for the moment recording started")
    func namedAfterStartTime() {
        let started = Self.localDate(2026, 8, 16, 10, 1, 33)

        #expect(
            defaultWavPath(startedAt: started, in: "/tmp/recordings")
                == "/tmp/recordings/2026-08-16_10-01-33.wav"
        )
    }

    @Test("Midnight and single-digit components stay zero-padded")
    func zeroPadsComponents() {
        let started = Self.localDate(2026, 1, 5, 0, 0, 7)

        #expect(
            defaultWavPath(startedAt: started, in: "/tmp/recordings")
                == "/tmp/recordings/2026-01-05_00-00-07.wav"
        )
    }

    // MARK: - Duration

    @Test("Sub-minute durations show seconds only")
    func secondsOnly() {
        #expect(formatDuration(0) == "0s")
        #expect(formatDuration(1) == "1s")
        #expect(formatDuration(59) == "59s")
    }

    @Test("Sub-hour durations show minutes and seconds")
    func minutesAndSeconds() {
        #expect(formatDuration(60) == "1m 0s")
        #expect(formatDuration(90) == "1m 30s")
        #expect(formatDuration(3599) == "59m 59s")
    }

    @Test("Hour-long durations show hours, minutes, and seconds")
    func hoursMinutesAndSeconds() {
        #expect(formatDuration(3600) == "1h 0m 0s")
        #expect(formatDuration(7668) == "2h 7m 48s")
        #expect(formatDuration(36000) == "10h 0m 0s")
    }
}
