import Testing
@testable import WebInspectorKit

@MainActor
struct WINetworkBodyFetchTests {
    @Test
    func fetchBodyIfNeeded_fetchesBodyAndAppliesFullResponse() async {
        let entry = makeEntry(requestID: 1)
        let body = makeBody(role: .response, preview: "{", reference: "body-ref", isTruncated: true)
        entry.responseBody = body

        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { entry, role in
            callCount += 1
            body.applyFullBody(
                "full-response",
                isBase64Encoded: false,
                isTruncated: false,
                size: nil
            )
            if role == .response, let size = body.size {
                entry.decodedBodyLength = size
            }
            return nil
        })

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)

        #expect(callCount == 1)
        #expect(body.fetchState == .full)
        #expect(body.full == "full-response")
        #expect(entry.decodedBodyLength == "full-response".count)
    }

    @Test
    func fetchBodyIfNeeded_retriesAfterFailure() async {
        let entry = makeEntry(requestID: 2)
        let body = makeBody(role: .request, preview: "partial", reference: "body-ref", isTruncated: true)
        entry.requestBody = body

        var responses: [WINetworkBody.FetchError?] = [.unavailable, nil]
        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { entry, role in
            callCount += 1
            let response = responses.removeFirst()
            if response == nil {
                body.applyFullBody(
                    "retry-body",
                    isBase64Encoded: false,
                    isTruncated: false,
                    size: nil
                )
                if role == .request, let size = body.size {
                    entry.requestBodyBytesSent = size
                }
            }
            return response
        })

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)
        #expect(body.fetchState == .failed(.unavailable))

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)
        #expect(body.fetchState == .full)
        #expect(body.full == "retry-body")
        #expect(callCount == 2)
    }

    @Test
    func fetchBodyIfNeeded_keepsFailingWhenFetchFailsRepeatedly() async {
        let entry = makeEntry(requestID: 3)
        let body = makeBody(role: .response, preview: "partial", reference: "body-ref", isTruncated: true)
        entry.responseBody = body

        var responses: [WINetworkBody.FetchError?] = [
            .decodeFailed,
            .decodeFailed,
            .decodeFailed
        ]
        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { _, _ in
            callCount += 1
            return responses.removeFirst()
        })

        for _ in 0..<3 {
            await viewModel.fetchBodyIfNeeded(for: entry, body: body)
        }

        #expect(callCount == 3)
        #expect(body.fetchState == .failed(.decodeFailed))
        #expect(body.full == nil)
    }

    @Test
    func fetchBodyIfNeeded_skipsWhenReferenceMissing() async {
        let entry = makeEntry(requestID: 4)
        let body = makeBody(role: .request, preview: "partial", reference: "", isTruncated: true)
        entry.requestBody = body

        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { _, _ in
            callCount += 1
            return nil
        })

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)

        #expect(callCount == 0)
        #expect(body.fetchState == .inline)
    }

    @Test
    func fetchBodyIfNeeded_allowsForcedFetchWhenAlreadyFull() async {
        let entry = makeEntry(requestID: 5)
        let body = makeBody(
            role: .response,
            preview: "cached",
            full: "cached",
            reference: "body-ref",
            isTruncated: false
        )
        entry.responseBody = body

        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { _, _ in
            callCount += 1
            body.applyFullBody(
                "forced-refresh",
                isBase64Encoded: false,
                isTruncated: false,
                size: nil
            )
            return nil
        })

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)
        #expect(callCount == 0)
        #expect(body.full == "cached")

        await viewModel.fetchBodyIfNeeded(for: entry, body: body, force: true)
        #expect(callCount == 1)
        #expect(body.full == "forced-refresh")
    }

    @Test
    func fetchBodyIfNeeded_skipsWhenAlreadyFetching() async {
        let entry = makeEntry(requestID: 6)
        let body = makeBody(
            role: .response,
            preview: "partial",
            reference: "body-ref",
            isTruncated: true,
            fetchState: .fetching
        )
        entry.responseBody = body

        var callCount = 0
        let viewModel = WINetworkViewModel(session: WINetworkSession(), bodyFetchHandler: { _, _ in
            callCount += 1
            return nil
        })

        await viewModel.fetchBodyIfNeeded(for: entry, body: body)

        #expect(callCount == 0)
        #expect(body.fetchState == .fetching)
    }

    private func makeEntry(requestID: Int) -> WINetworkEntry {
        WINetworkEntry(
            sessionID: "",
            requestID: requestID,
            url: "https://example.com",
            method: "GET",
            requestHeaders: WINetworkHeaders(),
            startTimestamp: 0,
            wallTime: nil
        )
    }

    private func makeBody(
        role: WINetworkBody.Role,
        preview: String?,
        full: String? = nil,
        reference: String?,
        isTruncated: Bool,
        fetchState: WINetworkBody.FetchState? = nil
    ) -> WINetworkBody {
        let body = WINetworkBody(
            kind: .text,
            preview: preview,
            full: full,
            size: nil,
            isBase64Encoded: false,
            isTruncated: isTruncated,
            summary: nil,
            reference: reference,
            formEntries: [],
            fetchState: fetchState,
            role: role
        )
        body.role = role
        return body
    }
}
