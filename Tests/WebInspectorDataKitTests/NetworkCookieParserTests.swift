import Foundation
import Testing
@testable import WebInspectorDataKit

@Suite
struct NetworkCookieParserTests {
    @Test
    func absentAndBlankHeadersRemainDistinct() throws {
        #expect(NetworkCookieParser.parseRequestHeaders([:]) == nil)
        #expect(NetworkCookieParser.parseResponseHeaders([:]) == nil)

        let requestReport = try #require(NetworkCookieParser.parseRequestHeaders([
            "cOoKiE": " \t "
        ]))
        #expect(requestReport.cookies.isEmpty)
        #expect(requestReport.rawHeaderValues == [" \t "])
        #expect(requestReport.diagnostics.isEmpty)
        #expect(requestReport.status == .complete)

        let responseReport = try #require(NetworkCookieParser.parseResponseHeaders([
            "sEt-CoOkIe": "\t"
        ]))
        #expect(responseReport.cookies.isEmpty)
        #expect(responseReport.rawHeaderValues == ["\t"])
        #expect(responseReport.diagnostics.isEmpty)
        #expect(responseReport.status == .complete)

        requireHashableSendable(requestReport)
        requireHashableSendable(responseReport)
    }

    @Test
    func caseVariantHeaderFieldsAreRejectedInDeterministicOrder() throws {
        let requestHeaders = [
            "cookie": "lower=1",
            "COOKIE": "upper=1",
            "Cookie": "title=1",
        ]
        let firstRequestReport = try #require(NetworkCookieParser.parseRequestHeaders(requestHeaders))
        let secondRequestReport = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "title=1",
            "cookie": "lower=1",
            "COOKIE": "upper=1",
        ]))

        #expect(firstRequestReport == secondRequestReport)
        #expect(firstRequestReport.rawHeaderValues == ["upper=1", "title=1", "lower=1"])
        #expect(firstRequestReport.cookies.isEmpty)
        #expect(firstRequestReport.diagnostics.map(\.kind) == [
            .multipleHeaderFields,
            .multipleHeaderFields,
            .multipleHeaderFields,
        ])
        #expect(firstRequestReport.diagnostics.map(\.rawFragment) == firstRequestReport.rawHeaderValues)
        #expect(firstRequestReport.status == .unparsed)

        let responseReport = try #require(NetworkCookieParser.parseResponseHeaders([
            "set-cookie": "lower=1",
            "SET-COOKIE": "upper=1",
        ]))
        #expect(responseReport.rawHeaderValues == ["upper=1", "lower=1"])
        #expect(responseReport.cookies.isEmpty)
        #expect(responseReport.diagnostics.map(\.rawFragment) == responseReport.rawHeaderValues)
        #expect(responseReport.status == .unparsed)
    }

    @Test
    func requestCookiesPreserveOrderDuplicatesAndUnnormalizedValues() throws {
        let rawHeader = "\tfirst = a=b== ; quoted=\"x,y\"; encoded=%2F%3D; first=again\t"
        let report = try #require(NetworkCookieParser.parseRequestHeaders(["COOKIE": rawHeader]))

        #expect(report.status == .complete)
        #expect(report.rawHeaderValues == [rawHeader])
        #expect(report.diagnostics.isEmpty)
        #expect(report.cookies == [
            NetworkRequestCookie(ordinal: 0, name: "first", value: "a=b==", raw: "\tfirst = a=b== "),
            NetworkRequestCookie(ordinal: 1, name: "quoted", value: "\"x,y\"", raw: " quoted=\"x,y\""),
            NetworkRequestCookie(ordinal: 2, name: "encoded", value: "%2F%3D", raw: " encoded=%2F%3D"),
            NetworkRequestCookie(ordinal: 3, name: "first", value: "again", raw: " first=again\t"),
        ])
    }

    @Test
    func requestCookieDiagnosticsPreserveInvalidFragments() throws {
        let partial = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "a=1; broken; =missing; b=2;"
        ]))
        #expect(partial.cookies.map(\.ordinal) == [0, 3])
        #expect(partial.cookies.map(\.name) == ["a", "b"])
        #expect(partial.diagnostics == [
            NetworkCookieParseDiagnostic(kind: .invalidCookieFragment, rawFragment: " broken"),
            NetworkCookieParseDiagnostic(kind: .invalidCookieFragment, rawFragment: " =missing"),
            NetworkCookieParseDiagnostic(kind: .invalidCookieFragment, rawFragment: ""),
        ])
        #expect(partial.status == .partial)

        let unparsed = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "broken; =missing"
        ]))
        #expect(unparsed.cookies.isEmpty)
        #expect(unparsed.diagnostics.map(\.rawFragment) == ["broken", " =missing"])
        #expect(unparsed.status == .unparsed)
    }

    @Test
    func requestCookieNamesMustBeHTTPTokens() throws {
        let report = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "valid=1; bad name=2; naïve=3; \u{1F}control=4; final=5"
        ]))

        #expect(report.cookies.map(\.ordinal) == [0, 4])
        #expect(report.cookies.map(\.name) == ["valid", "final"])
        #expect(report.diagnostics.map(\.kind) == [
            .invalidCookieFragment,
            .invalidCookieFragment,
            .prohibitedControlCharacter,
        ])
        #expect(report.diagnostics.map(\.rawFragment) == [
            " bad name=2",
            " naïve=3",
            " \u{1F}control=4",
        ])
        #expect(report.status == .partial)
    }

    @Test
    func requestControlCharactersRejectOnlyAffectedFragments() throws {
        let report = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "a=ok\u{1F}; tab=\tallowed\t; embedded=foo\tbar; b=2"
        ]))

        #expect(report.cookies == [
            NetworkRequestCookie(ordinal: 1, name: "tab", value: "allowed", raw: " tab=\tallowed\t"),
            NetworkRequestCookie(ordinal: 3, name: "b", value: "2", raw: " b=2"),
        ])
        #expect(report.diagnostics == [
            NetworkCookieParseDiagnostic(
                kind: .prohibitedControlCharacter,
                rawFragment: "a=ok\u{1F}"
            ),
            NetworkCookieParseDiagnostic(
                kind: .prohibitedControlCharacter,
                rawFragment: " embedded=foo\tbar"
            ),
        ])
        #expect(report.status == .partial)
    }

    @Test
    func responseCookiePreservesOWSValuesAttributesAndTypedProjections() throws {
        let rawHeader = "\tname \t= \"a,b\"==%2F \t; Domain=.Example.COM; Path=/a,b; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Max-Age=-42; Secure; HttpOnly; Partitioned; SameSite=Lax; Priority=High; Flag; X = one=two "
        let report = try #require(NetworkCookieParser.parseResponseHeaders(["SET-cookie": rawHeader]))
        let cookie = try #require(report.cookies.first)

        #expect(report.status == .complete)
        #expect(report.rawHeaderValues == [rawHeader])
        #expect(report.diagnostics.isEmpty)
        #expect(cookie.ordinal == 0)
        #expect(cookie.name == "name")
        #expect(cookie.value == "\"a,b\"==%2F")
        #expect(cookie.raw == rawHeader)
        #expect(cookie.domain == ".Example.COM")
        #expect(cookie.path == "/a,b")
        #expect(cookie.rawExpires == "Wed, 09 Jun 2021 10:18:14 GMT")
        #expect(cookie.expires == utcDate(year: 2021, month: 6, day: 9, hour: 10, minute: 18, second: 14))
        #expect(cookie.rawMaxAge == "-42")
        #expect(cookie.maxAgeSeconds == -42)
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.isPartitioned)
        #expect(cookie.sameSite == .lax)
        #expect(cookie.attributes.map(\.ordinal) == Array(0..<11))
        #expect(cookie.attributes.map(\.name) == [
            "Domain", "Path", "Expires", "Max-Age", "Secure", "HttpOnly",
            "Partitioned", "SameSite", "Priority", "Flag", "X",
        ])
        #expect(cookie.attributes.last?.value == "one=two")
        #expect(cookie.attributes.last?.raw == " X = one=two ")
        #expect(cookie.unknownAttributes.map(\.name) == ["Priority", "Flag", "X"])
        #expect(cookie.unknownAttributes.map(\.value) == ["High", nil, "one=two"])
    }

    @Test
    func expiresWeekdayCommaIsNotACombinedCookieCandidate() throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "a=b; Expires=Wed, 09 Jun 2021 10:18:14 GMT"
        ]))

        #expect(report.status == .complete)
        #expect(report.cookies.count == 1)
        #expect(report.cookies.first?.expires == utcDate(
            year: 2021,
            month: 6,
            day: 9,
            hour: 10,
            minute: 18,
            second: 14
        ))
    }

    @Test(arguments: [
        "a=b, c=d",
        "a=b,\t c \t= d",
        "a=b; Path=/c,d=e",
    ])
    func combinedCookieCandidatesRemainRawOnly(_ rawHeader: String) throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": rawHeader
        ]))

        #expect(report.cookies.isEmpty)
        #expect(report.rawHeaderValues == [rawHeader])
        #expect(report.diagnostics == [NetworkCookieParseDiagnostic(
            kind: .ambiguousCombinedHeader,
            rawFragment: rawHeader
        )])
        #expect(report.status == .ambiguousCombined)
    }

    @Test(arguments: [
        "a=b\u{0}",
        "a=b\u{1F}",
        "a=b\u{7F}",
        "a=foo\tbar",
        "na\tme=value",
        "a=b; Domain=foo\tbar",
        "\u{1F}name=value",
    ])
    func responseControlCharactersAreFatal(_ rawHeader: String) throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": rawHeader
        ]))

        #expect(report.cookies.isEmpty)
        #expect(report.rawHeaderValues == [rawHeader])
        #expect(report.diagnostics == [NetworkCookieParseDiagnostic(
            kind: .prohibitedControlCharacter,
            rawFragment: rawHeader
        )])
        #expect(report.status == .unparsed)
    }

    @Test
    func invalidResponseCookiePairRemainsRawOnly() throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "broken; Path=/"
        ]))

        #expect(report.cookies.isEmpty)
        #expect(report.rawHeaderValues == ["broken; Path=/"])
        #expect(report.diagnostics == [NetworkCookieParseDiagnostic(
            kind: .invalidCookieFragment,
            rawFragment: "broken"
        )])
        #expect(report.status == .unparsed)
    }

    @Test(arguments: [
        "bad name=value",
        "näme=value",
    ])
    func responseCookieNamesMustBeHTTPTokens(_ rawHeader: String) throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": rawHeader
        ]))

        #expect(report.cookies.isEmpty)
        #expect(report.diagnostics == [NetworkCookieParseDiagnostic(
            kind: .invalidCookieFragment,
            rawFragment: rawHeader
        )])
        #expect(report.status == .unparsed)
    }

    @Test
    func attributeNamesMustBeTokensAndPresenceValuesAreDiagnosed() throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "a=b; Good=1; Good=2; bad name=x; naïve=y; Secure=x; HttpOnly=0; Partitioned=value"
        ]))
        let cookie = try #require(report.cookies.first)

        #expect(cookie.attributes.map(\.ordinal) == Array(0..<7))
        #expect(cookie.attributes.map(\.name) == [
            "Good", "Good", "bad name", "naïve", "Secure", "HttpOnly", "Partitioned",
        ])
        #expect(cookie.unknownAttributes.map(\.name) == ["Good", "Good"])
        #expect(cookie.unknownAttributes.map(\.value) == ["1", "2"])
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.isPartitioned)
        #expect(report.diagnostics.map(\.kind) == [
            .invalidAttribute,
            .invalidAttribute,
            .invalidAttribute,
            .invalidAttribute,
            .invalidAttribute,
        ])
        #expect(report.diagnostics.map(\.rawFragment) == [
            " bad name=x",
            " naïve=y",
            " Secure=x",
            " HttpOnly=0",
            " Partitioned=value",
        ])
        #expect(report.status == .partial)
    }

    @Test
    func invalidKnownDuplicatesDoNotEraseSuccessfulProjections() throws {
        let validExpires = "Wed, 09 Jun 2021 10:18:14 GMT"
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "a=b; Domain=one.test; Domain=; Domain=two.test; Path=/one; Path; Path=/two; Expires=\(validExpires); Expires=invalid; Max-Age=10; Max-Age=+20; Secure=value; SameSite=None; SameSite; SameSite=Experimental"
        ]))
        let cookie = try #require(report.cookies.first)

        #expect(cookie.domain == "two.test")
        #expect(cookie.path == "/two")
        #expect(cookie.rawExpires == validExpires)
        #expect(cookie.expires == utcDate(year: 2021, month: 6, day: 9, hour: 10, minute: 18, second: 14))
        #expect(cookie.rawMaxAge == "10")
        #expect(cookie.maxAgeSeconds == 10)
        #expect(cookie.isSecure)
        #expect(cookie.sameSite == .other("Experimental"))
        #expect(cookie.attributes.map(\.ordinal) == Array(0..<14))
        #expect(cookie.attributes.map(\.name) == [
            "Domain", "Domain", "Domain", "Path", "Path", "Path", "Expires",
            "Expires", "Max-Age", "Max-Age", "Secure", "SameSite", "SameSite",
            "SameSite",
        ])
        #expect(cookie.unknownAttributes.isEmpty)
        #expect(report.diagnostics.map(\.kind) == [
            .invalidAttribute,
            .invalidAttribute,
            .invalidExpires,
            .invalidMaxAge,
            .invalidAttribute,
            .invalidAttribute,
        ])
        #expect(report.diagnostics.map(\.rawFragment) == [
            " Domain=",
            " Path",
            " Expires=invalid",
            " Max-Age=+20",
            " Secure=value",
            " SameSite",
        ])
        #expect(report.status == .partial)
    }

    @Test
    func maxAgeAcceptsZeroAndNegativeValues() throws {
        let zero = try responseCookie("a=b; Max-Age=0")
        #expect(zero.rawMaxAge == "0")
        #expect(zero.maxAgeSeconds == 0)

        let negative = try responseCookie("a=b; Max-Age=-9223372036854775808")
        #expect(negative.rawMaxAge == "-9223372036854775808")
        #expect(negative.maxAgeSeconds == Int64.min)
    }

    @Test(arguments: [
        "+1",
        "9223372036854775808",
        "-9223372036854775809",
        "1.0",
        "-",
    ])
    func invalidMaxAgeIsDiagnosedWithoutAProjection(_ rawValue: String) throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "a=b; Max-Age=\(rawValue)"
        ]))
        let cookie = try #require(report.cookies.first)

        #expect(cookie.rawMaxAge == nil)
        #expect(cookie.maxAgeSeconds == nil)
        #expect(report.diagnostics.map(\.kind) == [.invalidMaxAge])
        #expect(report.diagnostics.map(\.rawFragment) == [" Max-Age=\(rawValue)"])
        #expect(report.status == .partial)
    }

    @Test
    func sameSitePreservesAllSemanticStates() throws {
        #expect(try responseCookie("a=b").sameSite == .absent)
        #expect(try responseCookie("a=b; SameSite=None").sameSite == .none)
        #expect(try responseCookie("a=b; SameSite=lAx").sameSite == .lax)
        #expect(try responseCookie("a=b; SameSite=STRICT").sameSite == .strict)
        #expect(try responseCookie("a=b; SameSite=FutureMode").sameSite == .other("FutureMode"))
    }

    @Test(arguments: [
        ("Wed, 09 Jun 69 10:18:14 GMT", 2069),
        ("Wed, 09 Jun 70 10:18:14 GMT", 1970),
        ("Wed, 09 Jun 2021 10:18:14 GMT", 2021),
        ("Wed,\t09 Jun 2021 10:18:14 GMT", 2021),
        ("09th-Jun-2021 10:18:14GMT", 2021),
    ])
    func cookieDatesUseRFCDateTokens(_ rawValue: String, expectedYear: Int) throws {
        let cookie = try responseCookie("a=b; Expires=\(rawValue)")
        let date = try #require(cookie.expires)

        #expect(cookie.rawExpires == rawValue)
        #expect(utcCalendar.dateComponents([.year], from: date).year == expectedYear)
    }

    @Test(arguments: [
        "Wed, 32 Jun 2021 10:18:14 GMT",
        "Wed, 31 Feb 2021 10:18:14 GMT",
        "Wed, 09 Jun 1600 10:18:14 GMT",
        "Wed, 09 Jun 2021 24:18:14 GMT",
        "Wed, 09 Jun 2021 10:60:14 GMT",
        "Wed, 09 Jun 2021 10:18:60 GMT",
        "Wed, 09 Jun 2021 GMT",
    ])
    func invalidCookieDateBoundsAreDiagnosed(_ rawValue: String) throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "a=b; Expires=\(rawValue)"
        ]))
        let cookie = try #require(report.cookies.first)

        #expect(cookie.rawExpires == nil)
        #expect(cookie.expires == nil)
        #expect(report.diagnostics.map(\.kind) == [.invalidExpires])
        #expect(report.status == .partial)
    }
}

private extension NetworkCookieParserTests {
    func responseCookie(_ rawHeader: String) throws -> NetworkResponseCookie {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": rawHeader
        ]))
        #expect(report.status == .complete)
        #expect(report.diagnostics.isEmpty)
        return try #require(report.cookies.first)
    }

    var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date? {
        utcCalendar.date(from: DateComponents(
            timeZone: utcCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))
    }

    func requireHashableSendable<T: Hashable & Sendable>(_ value: T) {
        _ = value.hashValue
    }
}
