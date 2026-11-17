import Foundation
import Testing
@testable import NozzleCast

/// What a failed request is allowed to conclude about the server.
struct ErrorHandlingTests {
    @Test func aClientErrorIsAnAnswer() {
        #expect(BambuddyAPIClient.serverAnswered(BambuddyAPIError.http(400, "not enabled")))
        #expect(BambuddyAPIClient.serverAnswered(BambuddyAPIError.http(404, "")))
    }

    @Test func anUnreadableBodyIsAnAnswer() {
        struct Shape: Error {}
        #expect(BambuddyAPIClient.serverAnswered(BambuddyAPIError.decoding(Shape())))
    }

    /// A blip must not switch a Spoolman user's inventory to the built-in one.
    @Test func outagesAreNotAnswers() {
        #expect(!BambuddyAPIClient.serverAnswered(BambuddyAPIError.http(502, "Bad Gateway")))
        #expect(!BambuddyAPIClient.serverAnswered(BambuddyAPIError.http(503, "")))
        #expect(!BambuddyAPIClient.serverAnswered(URLError(.timedOut)))
        #expect(!BambuddyAPIClient.serverAnswered(URLError(.notConnectedToInternet)))
        #expect(!BambuddyAPIClient.serverAnswered(CancellationError()))
    }

    @Test func tagLinkErrorSaysTheSpoolWasAdded() {
        let error = AppStore.TagLinkError(underlying: BambuddyAPIError.http(409, "tag in use"))
        #expect(error.errorDescription?.contains("The spool was added") == true)
    }
}
