import Testing
@testable import scribe

/// How a recording is split across `whisper_full` calls; the ranges must cover it exactly once.
@Suite("Transcription Chunking")
struct TranscriptionChunkingTests {

    // MARK: - Helpers

    static func samples(seconds: Double) -> Int {
        Int(seconds * AudioWriter.sampleRate)
    }

    static func chunks(seconds: Double, chunkLength: Double = 600, overlap: Double = 2) -> [WhisperContext.Chunk] {
        WhisperContext.chunks(
            sampleCount: samples(seconds: seconds),
            options: TranscribeOptions(chunkLength: chunkLength, chunkOverlap: overlap)
        )
    }

    // MARK: - Single chunk

    @Test("チャンク長より短い音声は分割しない")
    func shortAudioStaysWhole() {
        let chunks = Self.chunks(seconds: 60)

        #expect(chunks.count == 1)
        #expect(chunks[0].fed == 0..<Self.samples(seconds: 60))
        #expect(chunks[0].owned == 0..<Self.samples(seconds: 60))
    }

    @Test("チャンク長 0 は分割を無効にする")
    func zeroChunkLengthDisablesSplitting() {
        let chunks = Self.chunks(seconds: 3960, chunkLength: 0)

        #expect(chunks.count == 1)
        #expect(chunks[0].fed == 0..<Self.samples(seconds: 3960))
    }

    // MARK: - Multiple chunks

    @Test("66 分の音声は 10 分ごとに 7 チャンクへ分割される")
    func longAudioSplitsByChunkLength() {
        let chunks = Self.chunks(seconds: 3960)

        #expect(chunks.count == 7)
    }

    @Test("担当区間は音声全体を隙間なく 1 回ずつ覆う")
    func ownedRangesTileTheAudio() {
        let total = Self.samples(seconds: 3960)
        let chunks = Self.chunks(seconds: 3960)

        #expect(chunks.first?.owned.lowerBound == 0)
        #expect(chunks.last?.owned.upperBound == total)
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.owned.upperBound == $1.owned.lowerBound })
    }

    @Test("2 チャンク目以降は担当区間の手前から助走を取る")
    func laterChunksBorrowLeadIn() {
        let leadIn = Self.samples(seconds: 2)
        let chunks = Self.chunks(seconds: 3960)

        #expect(chunks[0].fed.lowerBound == 0, "先頭チャンクに助走はない")
        for chunk in chunks.dropFirst() {
            #expect(chunk.fed.lowerBound == chunk.owned.lowerBound - leadIn)
            #expect(chunk.fed.upperBound == chunk.owned.upperBound)
        }
    }

    @Test("助走なしを指定すると担当区間だけを渡す")
    func zeroOverlapFeedsOwnedRangeOnly() {
        let chunks = Self.chunks(seconds: 3960, overlap: 0)

        #expect(chunks.allSatisfy { $0.fed == $0.owned })
    }

    @Test("末尾チャンクは音声の終端で切り上げる")
    func lastChunkStopsAtEndOfAudio() {
        let total = Self.samples(seconds: 1500)
        let chunks = Self.chunks(seconds: 1500)

        #expect(chunks.count == 3)
        #expect(chunks[2].owned == Self.samples(seconds: 1200)..<total)
    }
}
