import Darwin
import Foundation
import MachO
import MachOKit
import Synchronization

struct RuntimeMatcher {
    let names: [(RuntimeSymbol.Name, [RuntimeSymbolName.RawNameNeedle], [UInt8]?)]
    init(_ symbol: RuntimeSymbol) {
        names = symbol.names.map { name in
            switch name {
            case .mangled: return (name, [], nil)
            case .cxx(let declaration):
                let prefix = String(declaration.prefix { $0 != "(" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^vtable\\s+for\\s+", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s*::\\s*", with: "::", options: .regularExpression)
                let filterName: String
                if let conversion = prefix.range(of: "::operator") {
                    filterName = String(prefix[..<conversion.lowerBound])
                } else {
                    filterName = prefix
                }
                // Only plain qualified identifiers are literal Itanium name fragments.
                // Anonymous namespaces, lambdas and template declarations need full demangling.
                let isPlainName = filterName.range(
                    of: "^(?:[A-Za-z_][A-Za-z0-9_]*::)*~?[A-Za-z_][A-Za-z0-9_]*$",
                    options: .regularExpression
                ) != nil
                let needles = isPlainName ? RuntimeSymbolName.rawNameNeedles(
                    for: filterName.replacingOccurrences(of: "~", with: "")
                ) : []
                return (name, needles, RuntimeSymbolName.cxxSignatureKey(declaration))
            }
        }
    }
    private static func linkerKey(_ name: String) -> String {
        name.hasPrefix("__Z") ? String(name.dropFirst()) : name
    }
    @unsafe func mayMatch(_ raw: UnsafePointer<CChar>) -> Bool {
        names.contains { name, needles, _ in
            switch name {
            case .mangled(let expected):
                return Self.linkerKey(unsafe String(cString: raw)) == Self.linkerKey(expected)
            case .cxx:
                return needles.allSatisfy { unsafe RuntimeSymbolName.cString(raw, containsRawNameNeedle: $0) }
            }
        }
    }
    func matches(_ raw: String) -> Bool {
        raw.withCString { pointer in
            guard unsafe mayMatch(pointer) else { return false }
            var decoded: RuntimeSymbolName.Decoded?
            return names.contains { name, _, key in
                switch name {
                case .mangled(let expected): return Self.linkerKey(raw) == Self.linkerKey(expected)
                case .cxx:
                    if decoded == nil { decoded = unsafe RuntimeSymbolName.decode(pointer) }
                    return decoded?.cxxFunctionSignature == key
                }
            }
        }
    }
}

struct RuntimeSection {
    let range: Range<UInt64>
    let code: Bool
    let vtable: Bool
}

struct RuntimeBucket {
    var address: UInt64?
    var ambiguous = false
    var invalid = false
    var source = "loaded-image"
    mutating func insert(_ candidate: UInt64, valid: Bool, source: String) {
        guard valid else { invalid = true; return }
        if let address, address != candidate { ambiguous = true }
        self.address = candidate
        self.source = source
    }
    var needsLookup: Bool { address == nil && !ambiguous }
}

enum RuntimeResolver {
    private static let cache = Mutex<[RuntimeSymbol: ResolvedRuntimeSymbol]>([:])

    static func resolveCached(_ symbols: [RuntimeSymbol]) -> [Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        cache.withLock { cache in
            let missing = Array(Set(symbols.filter { symbol in
                guard let cached = cache[symbol], isCurrent(cached) else {
                    cache[symbol] = nil
                    return true
                }
                return false
            }))
            let results = resolve(missing)
            for (symbol, result) in results {
                if case .success(let address) = result { cache[symbol] = address }
            }
            return symbols.map { symbol in
                if let value = cache[symbol] { return .success(value) }
                return results[symbol] ?? .failure(RuntimeLookupError(.symbolMissing))
            }
        }
    }

    private static func isCurrent(_ symbol: ResolvedRuntimeSymbol) -> Bool {
        guard let expectedUUID = symbol.imageUUID,
              let image = unsafe MachOKitSymbolLookup.image(containingAddress: symbol.address),
              unsafe UInt(bitPattern: image.ptr) == symbol.imageHeaderAddress else { return false }
        return image.loadCommands.contains { command in
            if case .uuid(let value) = command { return value.uuid == expectedUUID }
            return false
        }
    }

    static func resolve(_ symbols: [RuntimeSymbol], allowSharedCache: Bool = true) -> [RuntimeSymbol: Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        var results: [RuntimeSymbol: Result<ResolvedRuntimeSymbol, RuntimeLookupError>] = [:]
        let session = RuntimeLookupSession(allowSharedCache: allowSharedCache)
        // Process image alternatives in order for each requirement while batching requests for one image.
        let maximumImages = symbols.map { $0.images.count }.max() ?? 0
        for index in 0..<maximumImages {
            let pending = symbols.filter { symbol in
                guard index < symbol.images.count else { return false }
                guard let result = results[symbol] else { return true }
                if case .failure(let error) = result { return error.reason == .symbolMissing || error.reason == .imageUnavailable }
                return false
            }
            for image in Set(pending.map { $0.images[index] }) {
                let targets = pending.filter { $0.images[index] == image }
                results.merge(session.resolve(targets, in: image)) { _, next in next }
            }
        }
        return results
    }
}

final class RuntimeLookupSession {
    let allowSharedCache: Bool
    init(allowSharedCache: Bool) { self.allowSharedCache = allowSharedCache }
    private lazy var loadedCache = DyldCacheLoaded.current
    private lazy var fullCache = FullDyldCache.host
    private var symbolFiles: [UUID: [DyldCache]] = [:]

    func resolve(_ symbols: [RuntimeSymbol], in owner: RuntimeImage) -> [RuntimeSymbol: Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        guard let image = unsafe MachOKitSymbolLookup.loadedImage(matching: owner.pathSuffixes),
              image.is64Bit, let text = image.segments64.first(where: { $0.segmentName == "__TEXT" }) else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, .failure(RuntimeLookupError(.imageUnavailable))) })
        }
        let base = unsafe UInt64(UInt(bitPattern: image.ptr))
        guard base >= UInt64(text.virtualMemoryAddress) else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, .failure(RuntimeLookupError(.invalidAddress))) })
        }
        let slide = base - UInt64(text.virtualMemoryAddress)
        let sections = image.sections64.compactMap { section -> RuntimeSection? in
            guard section.address >= 0, section.size > 0 else { return nil }
            let start = UInt64(section.address) + slide
            return RuntimeSection(range: start..<(start + UInt64(section.size)),
                code: section.flags.attributes.contains(.pure_instructions) || section.flags.attributes.contains(.some_instructions),
                vtable: section.sectionName == "__const" && (section.segmentName.hasPrefix("__DATA") || section.segmentName.hasPrefix("__AUTH")))
        }
        let matchers = symbols.map(RuntimeMatcher.init)
        var buckets = Array(repeating: RuntimeBucket(), count: symbols.count)
        func record(_ name: String, address: UInt64, source: String, indices: [Int]) {
            for index in indices where !buckets[index].ambiguous && matchers[index].matches(name) {
                let section = sections.first { $0.range.contains(address) }
                let valid: Bool
                switch symbols[index].kind {
                case .function: valid = section?.code == true
                case .data: valid = section != nil && section?.code == false
                case .vtable: valid = section?.vtable == true && section!.range.upperBound - address >= 3 * MemoryLayout<UInt>.size
                }
                buckets[index].insert(address, valid: valid, source: source)
            }
        }
        for symbol in image.symbols where symbol.offset > 0 {
            guard matchers.contains(where: { unsafe $0.mayMatch(symbol.nameC) }) else { continue }
            record(symbol.name, address: base + UInt64(symbol.offset), source: "loaded-image", indices: Array(symbols.indices))
        }
        for symbol in image.exportedSymbols {
            guard let offset = symbol.offset, offset > 0 else { continue }
            record(symbol.name, address: base + UInt64(offset), source: "loaded-image", indices: Array(symbols.indices))
        }
        if allowSharedCache && image.header.flags.contains(.dylib_in_cache) && buckets.contains(where: \.needsLookup) {
            let unresolved = symbols.indices.filter { buckets[$0].needsLookup }
            func recordLocal(_ name: String, _ address: UInt64, _ source: String) {
                // Existing loaded-image identities do not depend on local-symbol availability.
                record(name, address: address, source: source, indices: unresolved)
            }
            if let cache = loadedCache, let cacheSlide = cache.slide, cacheSlide >= 0,
               UInt64(cacheSlide) == slide, UInt64(text.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart {
                let offset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
                if let info = cache.localSymbolsInfo, let locals = info.symbols64(in: cache),
                   let range = localRange(offset, entries: Array(info.entries(in: cache)), count: locals.count) {
                    for index in range {
                        let symbol = unsafe locals.symbols.advanced(by: index).pointee
                        let name = unsafe locals.stringBase.advanced(by: numericCast(symbol.n_un.n_strx))
                        guard matchers.contains(where: { unsafe $0.mayMatch(name) }) else { continue }
                        let value = locals.addressStart + numericCast(symbol.n_value)
                        if value >= 0 { recordLocal(unsafe String(cString: name), UInt64(value) + slide, "shared-cache") }
                    }
                }
                if buckets.contains(where: \.needsLookup) {
                    scanFiles(header: cache.mainCacheHeader, offset: offset, slide: slide, record: recordLocal)
                }
            }
            if buckets.contains(where: \.needsLookup), let cache = fullCache,
               let file = cache.machOFiles().first(where: { file in
                   let path = file.imagePath
                   return owner.pathSuffixes.contains { path.hasSuffix($0) }
               }), let fileText = file.segments64.first(where: { $0.segmentName == "__TEXT" }),
               let loadedUUID = image.loadCommands.compactMap({ command -> UUID? in if case .uuid(let value) = command { return value.uuid }; return nil }).first,
               file.loadCommands.contains(where: { if case .uuid(let value) = $0 { return value.uuid == loadedUUID }; return false }),
               UInt64(fileText.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart {
                let offset = UInt64(fileText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
                if let info = cache.localSymbolsInfo, let locals = info.symbols64(in: cache),
                   let range = localRange(offset, entries: Array(info.entries(in: cache)), count: locals.count) {
                    for index in range {
                        let symbol = locals[index]
                        if symbol.offset >= 0 { recordLocal(symbol.name, UInt64(symbol.offset) + slide, "full-cache") }
                    }
                }
                if buckets.contains(where: \.needsLookup) {
                    scanFiles(header: cache.mainCacheHeader, offset: offset, slide: slide, record: recordLocal)
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: symbols.indices.map { index in
            let bucket = buckets[index]
            let result: Result<ResolvedRuntimeSymbol, RuntimeLookupError>
            if bucket.ambiguous { result = .failure(RuntimeLookupError(.ambiguousSymbol)) }
            else if let address = bucket.address, let section = sections.first(where: { $0.range.contains(address) }),
                    unsafe MachOKitSymbolLookup.image(containingAddress: address).map({ unsafe UInt(bitPattern: $0.ptr) }) == UInt(base) {
                result = .success(ResolvedRuntimeSymbol(address: address, imageHeaderAddress: UInt(base), imageUUID: image.loadCommands.compactMap { command -> UUID? in
                    if case .uuid(let value) = command { return value.uuid }; return nil
                }.first, image: owner, sectionRange: section.range, source: bucket.source))
            } else { result = .failure(RuntimeLookupError(bucket.invalid ? .invalidAddress : .symbolMissing)) }
            return (symbols[index], result)
        })
    }

    private func scanFiles(header: DyldCacheHeader, offset: UInt64, slide: UInt64, record: (String, UInt64, String) -> Void) {
        if symbolFiles[header.uuid] == nil {
            symbolFiles[header.uuid] = Self.symbolFileURLs().compactMap { url in
                guard let file = try? DyldCache(subcacheUrl: url, mainCacheHeader: header),
                      file.header.uuid == header.symbolFileUUID else { return nil }
                return file
            }
        }
        for file in symbolFiles[header.uuid] ?? [] {
            guard let info = file.localSymbolsInfo, let symbols = info.symbols64(in: file),
                  let range = localRange(offset, entries: Array(info.entries(in: file)), count: symbols.count) else { continue }
            for index in range {
                let symbol = symbols[index]
                if symbol.offset >= 0 { record(symbol.name, UInt64(symbol.offset) + slide, "shared-cache-file") }
            }
        }
    }

    private func localRange(_ offset: UInt64, entries: [any DyldCacheLocalSymbolsEntryProtocol], count: Int) -> Range<Int>? {
        guard let entry = entries.first(where: { UInt64($0.dylibOffset) == offset }),
              entry.nlistStartIndex >= 0, entry.nlistCount >= 0,
              entry.nlistStartIndex <= count, entry.nlistCount <= count - entry.nlistStartIndex else { return nil }
        return entry.nlistStartIndex..<(entry.nlistStartIndex + entry.nlistCount)
    }

    static func symbolFileURLs(activePath: String? = unsafe MachOKitSymbolLookup.hostSharedCachePath) -> [URL] {
        var urls: [URL] = []
        if let activePath { urls.append(URL(fileURLWithPath: activePath.hasSuffix(".symbols") ? activePath : activePath + ".symbols")) }
        #if os(iOS)
        let directories = ["/System/Library/Caches/com.apple.dyld", "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld", "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"]
        #else
        let directories = ["/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", "/System/Library/dyld", "/System/Cryptexes/OS/System/Library/dyld"]
        #endif
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in files.filter({ $0.hasPrefix("dyld_shared_cache_") && $0.hasSuffix(".symbols") }).sorted() {
                urls.append(URL(fileURLWithPath: directory).appendingPathComponent(file))
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
