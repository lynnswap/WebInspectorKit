import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Suite
struct NetworkRequestHeadersContextTests {

    @Test
    func queryParametersPreserveRepeatsEmptyValuesBareNamesAndEmptyFragments() throws {
        let report = try #require(
            NetworkParameterParser.parseQuery(
                in: "https://example.test/path?repeat=1&empty=&bare&=value&&repeat=2&#ignored"
            ))

        #expect(report.rawValue == "repeat=1&empty=&bare&=value&&repeat=2&")
        #expect(report.parameters.map(\.ordinal) == Array(0...6))
        #expect(
            report.parameters.map(\.rawFragment) == [
                "repeat=1", "empty=", "bare", "=value", "", "repeat=2", "",
            ])
        #expect(report.parameters.map(\.hadEqualsSign) == [true, true, false, true, false, true, false])
        #expect(
            report.parameters.map { $0.name.decodedValue } == [
                "repeat", "empty", "bare", "", "", "repeat", "",
            ])
        #expect(
            report.parameters.map { $0.value.decodedValue } == [
                "1", "", "", "value", "", "2", "",
            ])
        #expect(report.status == .complete)
        #expect(report.diagnostics.isEmpty)
    }

    @Test
    func parameterDecoderHandlesPlusReservedBytesAndLiteralAndEncodedUTF8() throws {
        let report = try #require(
            NetworkParameterParser.parseQuery(
                in: "?space=a+b&plus=%2B&reserved=%26%3D&literal=東京&encoded=%E6%9D%B1%E4%BA%AC"
            ))

        #expect(
            report.parameters.map { $0.value.decodedValue } == [
                "a b", "+", "&=", "東京", "東京",
            ])
        #expect(report.status == .complete)
    }

    @Test
    func malformedParameterComponentsRemainLocalAndKeepValidSiblings() throws {
        let report = try #require(
            NetworkParameterParser.parseQuery(
                in: "?badPercent=%&badHex=%G0&invalid=%FF&incomplete=%E3%81&%FF=value&good=%E6%9D%B1&next=ok"
            ))

        #expect(report.parameters.count == 7)
        #expect(report.parameters[0].name.decodedValue == "badPercent")
        #expect(
            report.parameters[0].value
                == .malformed(
                    rawValue: "%",
                    reason: .malformedPercentEscape
                ))
        #expect(
            report.parameters[1].value
                == .malformed(
                    rawValue: "%G0",
                    reason: .malformedPercentEscape
                ))
        #expect(report.parameters[2].value == .malformed(rawValue: "%FF", reason: .invalidUTF8))
        #expect(report.parameters[3].value == .malformed(rawValue: "%E3%81", reason: .invalidUTF8))
        #expect(report.parameters[4].name == .malformed(rawValue: "%FF", reason: .invalidUTF8))
        #expect(report.parameters[4].value.decodedValue == "value")
        #expect(report.parameters[5].value.decodedValue == "東")
        #expect(report.parameters[6].value.decodedValue == "ok")
        #expect(report.status == .partial)
        #expect(report.diagnostics.map(\.ordinal) == [0, 1, 2, 3, 4])
        #expect(report.diagnostics.map(\.field) == [.value, .value, .value, .value, .name])

        let unparsed = NetworkParameterParser.parseForm("%=%")
        #expect(unparsed.status == .unparsed)
        #expect(unparsed.diagnostics.count == 2)
    }

    @Test
    func queryExtractionUsesRawQuestionMarkBeforeFragmentWithoutURLNormalization() throws {
        let malformedURLReport = try #require(
            NetworkParameterParser.parseQuery(
                in: "not a valid URL ?first=1#fragment?ignored=2"
            ))
        #expect(malformedURLReport.rawValue == "first=1")
        #expect(malformedURLReport.parameters.first?.value.decodedValue == "1")

        let empty = try #require(NetworkParameterParser.parseQuery(in: "https://example.test/path?"))
        #expect(empty.rawValue == "")
        #expect(empty.parameters.isEmpty)
        #expect(empty.status == .complete)

        #expect(NetworkParameterParser.parseQuery(in: "https://example.test/path") == nil)
        #expect(NetworkParameterParser.parseQuery(in: "https://example.test/path#fragment?ignored=1") == nil)
    }

    @Test
    func formAndQueryUseTheSameParameterParserContract() throws {
        let rawValue = "repeat=1&repeat=2&bare&empty=&bad=%ZZ"
        let query = try #require(NetworkParameterParser.parseQuery(in: "scheme:?\(rawValue)#fragment"))
        let form = NetworkParameterParser.parseForm(rawValue)

        #expect(form == query)
    }

    @Test
    func contentTypeParserNormalizesTokensAndPreservesQuotedAndDuplicateParameters() throws {
        let rawValue =
            #"  Application/X-WWW-Form-Urlencoded ; CHARSET = "utf-8" ; boundary="a;b=c\"d\\e"; X-Foo=bar ; charset=second ; encoding=gzip  "#
        let contentType = NetworkContentTypeParser.parse(rawValue)

        #expect(contentType.rawValue == rawValue)
        #expect(contentType.mediaType == "Application/X-WWW-Form-Urlencoded")
        #expect(contentType.normalizedMediaType == "application/x-www-form-urlencoded")
        #expect(contentType.parameters.count == 5)
        #expect(contentType.parameters.map(\.ordinal) == Array(0...4))
        #expect(
            contentType.parameters.map(\.normalizedName) == [
                "charset", "boundary", "x-foo", "charset", "encoding",
            ])
        #expect(
            contentType.parameters.map(\.value) == [
                "utf-8", #"a;b=c"d\e"#, "bar", "second", "gzip",
            ])
        #expect(contentType.boundary == [#"a;b=c"d\e"#])
        #expect(contentType.charset == ["utf-8", "second"])
        #expect(contentType.parameters[2].rawFragment.contains("X-Foo=bar"))
        #expect(contentType.parameters.allSatisfy { $0.issue == nil })
    }

    @Test
    func contentTypeParserRetainsMalformedParametersAndRejectsEscapedControls() {
        let malformed = NetworkContentTypeParser.parse(
            #"text/plain; missing; bad name=value; empty=; quote="unterminated; still=part"#
        )

        #expect(malformed.parameters.count == 4)
        #expect(
            malformed.parameters.map(\.issue) == [
                .missingEqualsSign,
                .invalidName,
                .invalidValue,
                .malformedQuotedValue,
            ])
        #expect(
            malformed.parameters.map(\.rawFragment) == [
                " missing", " bad name=value", " empty=", #" quote="unterminated; still=part"#,
            ])

        let escapedControl = NetworkContentTypeParser.parse(
            "multipart/form-data; boundary=\"a\\\nb\""
        )
        #expect(escapedControl.parameters.first?.issue == .malformedQuotedValue)

        let escapedQuoteAndSlash = NetworkContentTypeParser.parse(
            #"multipart/form-data; boundary="a\"b\\c""#
        )
        #expect(escapedQuoteAndSlash.parameters.first?.value == #"a"b\c"#)
        #expect(escapedQuoteAndSlash.parameters.first?.issue == nil)

        let nonASCIITokens = NetworkContentTypeParser.parse("téxt/plain; naïve=value")
        #expect(nonASCIITokens.mediaType == "téxt/plain")
        #expect(nonASCIITokens.normalizedMediaType == nil)
        #expect(nonASCIITokens.parameters.first?.issue == .invalidName)
    }

    @Test
    func contentTypeHeaderDistinguishesAbsentUniqueAndAmbiguousCaseVariantsDeterministically() throws {
        #expect(NetworkContentTypeParser.parseHeader(in: [:]) == .absent)

        let unique = NetworkContentTypeParser.parseHeader(in: [
            "cOnTeNt-TyPe": " Text/HTML ; Charset=UTF-8 "
        ])
        guard case let .value(contentType) = unique else {
            Issue.record("Expected one Content-Type field.")
            return
        }
        #expect(contentType.mediaType == "Text/HTML")
        #expect(contentType.normalizedMediaType == "text/html")
        #expect(contentType.charset == ["UTF-8"])

        let ambiguous = NetworkContentTypeParser.parseHeader(in: [
            "content-type": "lower",
            "Content-Type": "mixed",
            "CONTENT-TYPE": "upper",
        ])
        #expect(ambiguous == .ambiguous(rawValues: ["upper", "mixed", "lower"]))

        let repeatedValue = NetworkContentTypeParser.parseHeader(in: [
            "Content-Type": "same",
            "content-type": "same",
        ])
        #expect(repeatedValue == .ambiguous(rawValues: ["same", "same"]))
    }

    @MainActor
    @Test
    func headersContextDistinguishesCancellationFailureAndProjectsResourceAndInitiator() throws {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let nodeID = DOM.Node.ID("42")
        let canceled = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("canceled-context"),
                url: "https://example.test/canceled",
                method: "GET"
            ),
            initiator: Network.Initiator(
                kind: "script",
                url: "https://example.test/app.js",
                line: 17,
                column: 4,
                nodeID: nodeID
            ),
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        canceled.fail(errorText: "cancelled by client", canceled: true, timestamp: 2)

        #expect(canceled.headersContext.outcome == .canceled(reason: "cancelled by client"))
        #expect(canceled.headersContext.resourceType == Network.ResourceType.fetch.rawValue)
        #expect(
            canceled.headersContext.initiator
                == NetworkRequestHeadersContext.Initiator(
                    kind: "script",
                    url: "https://example.test/app.js",
                    line: 17,
                    nodeID: nodeID
                ))

        let failed = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("failed-context"),
                url: "https://example.test/failed",
                method: "GET"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        failed.fail(errorText: "DNS lookup failed", canceled: false, timestamp: 2)
        #expect(failed.headersContext.outcome == .failed(reason: "DNS lookup failed"))
    }

    @MainActor
    @Test
    func effectiveResponseMIMETypePrefersNonblankProtocolValueThenUniqueHeaderMediaType() {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let request = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("mime-context"),
                url: "https://example.test/resource",
                method: "GET"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )

        request.applyResponse(
            Network.Response(
                status: 200,
                mimeType: "  Application/JSON  ",
                headers: ["Content-Type": "text/html; charset=utf-8"]
            ),
            resourceType: .fetch,
            timestamp: 2
        )
        #expect(request.headersContext.effectiveMIMEType == "Application/JSON")

        request.applyResponse(
            Network.Response(
                status: 200,
                mimeType: "\t ",
                headers: ["content-TYPE": " Text/HTML ; charset=utf-8"]
            ),
            resourceType: .fetch,
            timestamp: 3
        )
        #expect(request.headersContext.effectiveMIMEType == "Text/HTML")

        request.applyResponse(
            Network.Response(
                status: 200,
                headers: [
                    "Content-Type": "text/plain",
                    "content-type": "application/json",
                ]
            ),
            resourceType: .fetch,
            timestamp: 4
        )
        #expect(request.headersContext.effectiveMIMEType == nil)
    }

    @MainActor
    @Test
    func redirectContextUsesFinalQueryAndBodyWhileKeepingInitialInitiator() throws {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let requestID = Network.Request.ID("redirect-context")
        let request = NetworkRequest(
            request: Network.Request(
                id: requestID,
                url: "https://example.test/start?initial=1",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                postData: "initial=body"
            ),
            initiator: Network.Initiator(
                kind: "script",
                url: "https://example.test/start.js",
                line: 9
            ),
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )

        request.applyRedirect(
            to: Network.Request(
                id: requestID,
                url: "https://example.test/final?repeat=1&repeat=2",
                method: "POST",
                headers: ["content-type": "application/x-www-form-urlencoded; charset=utf-8"],
                postData: "final=a+b&bare"
            ),
            redirectResponse: Network.Response(status: 302),
            timestamp: 2,
            resourceType: .fetch
        )

        let headersContext = request.headersContext
        #expect(headersContext.queryParameters?.parameters.map { $0.value.decodedValue } == ["1", "2"])
        #expect(headersContext.initiator?.url == "https://example.test/start.js")
        #expect(headersContext.initiator?.line == 9)
        guard case let .form(contentType, parameters) = headersContext.requestData else {
            Issue.record("Expected final URL-encoded request data.")
            return
        }
        #expect(contentType.contentType?.normalizedMediaType == "application/x-www-form-urlencoded")
        #expect(parameters.rawValue == "final=a+b&bare")
        #expect(parameters.parameters.map { $0.value.decodedValue } == ["a b", ""])
        #expect(parameters.parameters.map(\.hadEqualsSign) == [true, false])
    }

    @MainActor
    @Test
    func lifecycleReuseRecomputesHeadersContextFromTheNewRequest() {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let requestID = Network.Request.ID("reused-context")
        let request = NetworkRequest(
            request: Network.Request(
                id: requestID,
                url: "https://example.test/old?old=1",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                postData: "old=body"
            ),
            initiator: Network.Initiator(kind: "parser", line: 1),
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        request.fail(errorText: "old failure", canceled: false, timestamp: 2)

        request.applyRequestWillBeSent(
            request: Network.Request(
                id: requestID,
                url: "https://example.test/new?new=2",
                method: "GET"
            ),
            initiator: Network.Initiator(kind: "other", line: 20),
            navigationVisit: nil,
            resourceType: .document,
            timestamp: 3,
            chronologySequence: 2
        )

        #expect(request.lifecycleRevision == 1)
        #expect(request.headersContext.outcome == nil)
        #expect(request.headersContext.resourceType == Network.ResourceType.document.rawValue)
        #expect(request.headersContext.initiator?.kind == "other")
        #expect(request.headersContext.initiator?.line == 20)
        #expect(request.headersContext.queryParameters?.parameters.first?.name.decodedValue == "new")
        #expect(request.headersContext.requestData == nil)
    }

    @MainActor
    @Test
    func metricsRequestHeadersRefineFormContextWithoutReplacingBodyIdentity() throws {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let request = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("metrics-form-context"),
                url: "https://example.test/submit",
                method: "POST",
                postData: "name=Jane+Doe&bad=%ZZ&next=ok"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        let body = try #require(request.requestBody)
        #expect(request.headersContext.requestData == .body(contentType: .absent))

        request.finish(
            timestamp: 2,
            sourceMapURL: nil,
            metrics: Network.Metrics().reporting(requestHeaders: [
                "Content-Type": "application/x-www-form-urlencoded"
            ])
        )

        #expect(request.requestBody === body)
        #expect(body.kind == .form)
        #expect(body.textRepresentation == "name=Jane Doe\nbad=%ZZ\nnext=ok")
        guard case let .form(contentType, parameters) = request.headersContext.requestData else {
            Issue.record("Expected refined URL-encoded request data.")
            return
        }
        #expect(contentType.contentType?.normalizedMediaType == "application/x-www-form-urlencoded")
        #expect(parameters.parameters[0].value.decodedValue == "Jane Doe")
        #expect(
            parameters.parameters[1].value
                == .malformed(
                    rawValue: "%ZZ",
                    reason: .malformedPercentEscape
                ))
        #expect(parameters.parameters[2].value.decodedValue == "ok")
    }

    @MainActor
    @Test
    func requestDataDistinguishesUnavailableNilAndCapturedEmptyBodies() throws {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)

        let noPostData = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("nil-post-data"),
                url: "https://example.test/no-body",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"]
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        #expect(noPostData.requestBody == nil)
        #expect(noPostData.headersContext.requestData == nil)

        let emptyPostData = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("empty-post-data"),
                url: "https://example.test/empty-body",
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                postData: ""
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        guard case let .form(_, parameters) = emptyPostData.headersContext.requestData else {
            Issue.record("Expected captured empty form data.")
            return
        }
        #expect(parameters.rawValue == "")
        #expect(parameters.parameters.isEmpty)

        let unavailableBody = NetworkBody(
            role: .request,
            kind: .form,
            full: nil,
            phase: .available
        )
        #expect(
            NetworkRequestHeadersContext.makeRequestData(
                requestBody: unavailableBody,
                requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
            ) == nil)

        let capturedEmptyBody = NetworkBody(
            role: .request,
            kind: .form,
            full: "",
            phase: .loaded
        )
        guard
            case let .form(_, capturedEmptyParameters) = NetworkRequestHeadersContext.makeRequestData(
                requestBody: capturedEmptyBody,
                requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
            )
        else {
            Issue.record("Expected standalone captured empty form data.")
            return
        }
        #expect(capturedEmptyParameters.parameters.isEmpty)

        let multipart = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("multipart-post-data"),
                url: "https://example.test/multipart",
                method: "POST",
                headers: [
                    "Content-Type": "multipart/form-data; boundary=first; boundary=second; charset=utf-8"
                ],
                postData: "captured payload"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
        guard case let .body(contentTypeHeader) = multipart.headersContext.requestData,
            case let .value(contentType) = contentTypeHeader
        else {
            Issue.record("Expected non-URL-encoded request body metadata.")
            return
        }
        #expect(contentType.normalizedMediaType == "multipart/form-data")
        #expect(contentType.boundary == ["first", "second"])
        #expect(contentType.charset == ["utf-8"])
    }

    @MainActor
    @Test
    func memoryCacheWithoutCapturedPostDataDoesNotSynthesizeRequestData() {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        let request = NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID("cached-context"),
                url: "https://example.test/cached",
                method: "GET"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: nil,
            requestHeaderSource: .unavailable,
            modelContext: context
        )

        request.applyMemoryCache(
            response: Network.Response(
                url: "https://example.test/cached",
                status: 200,
                mimeType: "text/plain",
                requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"]
            ),
            initiator: Network.Initiator(kind: "memory-cache"),
            resourceType: .fetch,
            timestamp: 1
        )

        #expect(request.responseSource == "memory-cache")
        #expect(request.requestBody == nil)
        #expect(request.headersContext.requestData == nil)
    }

    @Test
    func formTextRepresentationUsesComponentLocalFallbackAndPreservesEqualsAndOrder() {
        let body = NetworkBody(
            role: .request,
            kind: .form,
            full: "good=ok&bad=%ZZ&next=a+b&bare&&tail=",
            phase: .loaded
        )

        #expect(body.textRepresentation == "good=ok\nbad=%ZZ\nnext=a b\nbare\n\ntail=")
        #expect(body.textRepresentationSyntaxKind == .plainText)
    }

}
