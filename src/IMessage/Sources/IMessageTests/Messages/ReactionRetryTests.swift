import EmojiSPI
import IMessageCore
import Testing
@testable import IMessage

@Test func reactionSearchFailureDoesNotRetry() async {
    var attempts = 0
    var reports = 0
    do {
        let _: Void = try await retry(retries: 2) { _ in
            attempts += 1
            throw ReactionSearchError(emoji: "🎉", underlying: CharacterPickerSearch.Error.noSucceedingQuery)
        } shouldRetry: { !($0 is ReactionSearchError) } onError: { _, retriesLeft, _ in
            reports += 1
            #expect(retriesLeft == 0)
        }
        Issue.record("Expected search failure")
    } catch {
        #expect(error is ReactionSearchError)
    }
    #expect(attempts == 1)
    #expect(reports == 1)
}

@Test func transientReactionFailureStillRetries() async throws {
    var attempts = 0
    let result = try await retry(retries: 2) { _ in
        attempts += 1
        if attempts == 1 { throw ErrorMessage("Transient accessibility failure") }
        return true
    } shouldRetry: { !($0 is ReactionSearchError) }
    #expect(result)
    #expect(attempts == 2)
}
