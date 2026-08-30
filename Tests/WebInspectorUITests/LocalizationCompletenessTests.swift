#if canImport(UIKit)
import Foundation
import Testing
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
    @Suite
    struct LocalizationCompletenessTests {
        private static let supportedLocales: Set<String> = [
            "ar",
            "de",
            "en",
            "en-GB",
            "en-IN",
            "es",
            "es-419",
            "fr",
            "fr-CA",
            "hi",
            "id",
            "it",
            "ja",
            "ko",
            "nl",
            "pt-BR",
            "pt-PT",
            "ro",
            "ru",
            "th",
            "tr",
            "zh-Hans",
            "zh-Hant",
        ]

        @Test
        func everySupportedLocalizationIsComplete() throws {
            let bundle = WebInspectorUILocalization.bundle
            let bundledLocales = Set(bundle.localizations).subtracting(["Base"])
            #expect(bundledLocales == Self.supportedLocales)

            let strings = try catalogStrings()
            let targetLocales = Self.supportedLocales.subtracting(["en"])
            for (key, entry) in strings {
                let localizations = try #require(entry["localizations"] as? [String: Any])
                #expect(
                    Set(localizations.keys) == Self.supportedLocales,
                    "Incomplete locales for \(key)"
                )

                let sourceLocalization = try #require(localizations["en"])
                let sourceFormatSets = Set(stringUnits(in: sourceLocalization).map {
                    formatSpecifiers(in: $0.value)
                })
                for locale in targetLocales {
                    let localization = try #require(
                        localizations[locale],
                        "Missing \(locale) translation for \(key)"
                    )
                    let units = stringUnits(in: localization)
                    #expect(units.isEmpty == false, "Missing \(locale) value for \(key)")
                    #expect(
                        units.allSatisfy { $0.state == "translated" },
                        "Unreviewed \(locale) translation for \(key)"
                    )
                    #expect(
                        units.allSatisfy {
                            sourceFormatSets.contains(formatSpecifiers(in: $0.value))
                        },
                        "Format specifier mismatch in \(locale) translation for \(key)"
                    )
                }
            }
        }

        private func catalogStrings() throws -> [String: [String: Any]] {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let catalogURL = repositoryRoot
                .appendingPathComponent("Sources/WebInspectorUIBase/Localizable.xcstrings")
            let data = try Data(contentsOf: catalogURL)
            let object = try JSONSerialization.jsonObject(with: data)
            let root = try #require(object as? [String: Any])
            return try #require(root["strings"] as? [String: [String: Any]])
        }

        private struct CatalogStringUnit {
            let state: String
            let value: String
        }

        private func stringUnits(in value: Any) -> [CatalogStringUnit] {
            if let dictionary = value as? [String: Any] {
                if let state = dictionary["state"] as? String,
                   let value = dictionary["value"] as? String {
                    return [CatalogStringUnit(state: state, value: value)]
                }
                return dictionary.values.flatMap(stringUnits(in:))
            }
            if let array = value as? [Any] {
                return array.flatMap(stringUnits(in:))
            }
            return []
        }

        private func formatSpecifiers(in value: String) -> [String] {
            value.matches(of: /%(?:[0-9]+\$)?(?:lld|@)/)
                .map { String($0.output) }
                .sorted()
        }
    }
}
#endif
