import Foundation
import Testing
@testable import scribe

/// End-to-end regression tests for the transcription pipeline.
///
/// Reads Japanese WAV fixtures (generated via `scripts/generate-fixtures.sh`),
/// runs them through `AudioWriter.readWAV` + `WhisperContext.transcribe`, and
/// verifies that each transcript contains an expected keyword.
///
/// Disabled when the configured whisper model is missing locally, so fresh
/// checkouts (e.g. CI) don't fail. Override the model with
/// `SCRIBE_TEST_MODEL=<name>`. Marked `.serialized` because `WhisperContext`
/// drives whisper.cpp + Metal state that isn't safe to use from multiple
/// tests in parallel. We deliberately load the model per-case rather than
/// sharing a `static` instance: a long-lived `WhisperContext` survives
/// until process exit, where whisper.cpp's Metal cleanup currently trips an
/// assertion (see whisper.cpp #17869). Building/tearing down per case sidesteps it.
@Suite("Transcription Integration", .enabled(if: TestEnv.modelExists()), .serialized)
struct TranscriptionIntegrationTests {

    @Test(
        "日本語サンプルが期待単語を含めて転写される",
        arguments: [
            ("sample_weather_ja", "天気"),
            ("sample_meeting_ja", "会議"),
            ("sample_thanks_ja", "ありがとう"),
        ]
    )
    func transcribeJapaneseFixture(fixture: String, keyword: String) throws {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "wav",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.notFound(fixture)
        }

        let samples = try AudioWriter.readWAV(from: url.path)
        #expect(samples.count > 0, "Fixture has no samples")

        let whisper = try WhisperContext(modelPath: TestEnv.resolvedModelPath())
        let text = try whisper.transcribe(samples: samples, language: "ja")
        #expect(
            text.contains(keyword),
            "Transcript should contain '\(keyword)'. Got: \(text)"
        )
    }
}

/// Lives outside the suite so `.enabled(if:)` doesn't trigger circular
/// macro resolution against a static member of the suite itself.
fileprivate enum TestEnv {
    static func resolvedModelPath() -> String {
        let name = ProcessInfo.processInfo.environment["SCRIBE_TEST_MODEL"]
            ?? ScribeConfig.defaultModel
        return ModelManager.resolveModelPath(name)
    }

    static func modelExists() -> Bool {
        FileManager.default.fileExists(atPath: resolvedModelPath())
    }
}

private enum FixtureError: Error {
    case notFound(String)
}
