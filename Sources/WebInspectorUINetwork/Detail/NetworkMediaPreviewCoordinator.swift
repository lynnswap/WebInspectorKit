#if canImport(UIKit)
import WebInspectorUIBase
import Foundation
import UIKit
import WebInspectorDataKit

package struct NetworkMediaPreviewMetadata: Equatable, Sendable {
    package var mimeType: String?
    package var url: String?

    package init(mimeType: String?, url: String?) {
        self.mimeType = mimeType
        self.url = url
    }
}

package enum NetworkMediaPreviewPreparationAction {
    case unavailable
    case failed
    case active
    case remoteMovie(URL)
    case cachedMovie(URL)
    case startedLoading
}

package enum NetworkMediaPreviewResultAction {
    case ignore
    case fallback
    case showImage(UIImage)
    case showMovie(URL)
}

@MainActor
package final class NetworkMediaPreviewCoordinator {
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pendingInput: NetworkMediaPreviewInput?
    private var displayedIdentity: NetworkMediaPreviewIdentity?
    private var failedInput: NetworkMediaPreviewInput?
    private var temporaryFile: NetworkMediaTemporaryFile?

    package init() {}

    package func preparePreview(
        for body: NetworkBody,
        metadata: NetworkMediaPreviewMetadata?,
        completion: @escaping @MainActor (NetworkMediaPreviewResultAction) -> Void
    ) -> NetworkMediaPreviewPreparationAction {
        guard let source = mediaPreviewSource(for: body, metadata: metadata) else {
            return .unavailable
        }

        switch source {
        case .remoteMovie(let url):
            prepareRemoteMovie(url)
            return .remoteMovie(url)
        case .body(let input):
            return prepareBodyPreview(for: input, completion: completion)
        }
    }

    package func prepareSyntaxPreview() {
        cancelPending()
        displayedIdentity = nil
    }

    package func hideMediaPreview() {
        cancelPending()
        displayedIdentity = nil
        removeCachedTemporaryFile()
    }

    package func cancel() {
        cancelPending()
        displayedIdentity = nil
        removeCachedTemporaryFile()
    }

    package func suspendPreparation() {
        cancelPending()
    }

#if DEBUG
    package func waitUntilPreparationFinishedForTesting() async {
        while let task {
            await task.value
        }
    }
#endif

    private func mediaPreviewSource(
        for body: NetworkBody,
        metadata: NetworkMediaPreviewMetadata?
    ) -> NetworkMediaPreviewSource? {
        guard let previewKind = NetworkDisplay.MediaPreviewSupport.previewKind(
            mimeType: metadata?.mimeType,
            url: metadata?.url
        ) else {
            return nil
        }

        if previewKind == .hlsPlaylist {
            if body.role == .response,
               let remoteURL = playableRemoteMediaURL(metadata?.url) {
                return .remoteMovie(remoteURL)
            }
            if body.role == .request {
                return nil
            }
        }

        guard let rawBody = body.full else {
            return nil
        }
        return .body(
            NetworkMediaPreviewInput(
                previewKind: previewKind,
                bodyID: ObjectIdentifier(body),
                role: body.role,
                rawBody: rawBody,
                isBase64Encoded: body.isBase64Encoded,
                mimeType: metadata?.mimeType,
                url: metadata?.url
            )
        )
    }

    private func prepareBodyPreview(
        for input: NetworkMediaPreviewInput,
        completion: @escaping @MainActor (NetworkMediaPreviewResultAction) -> Void
    ) -> NetworkMediaPreviewPreparationAction {
        guard failedInput != input else {
            return .failed
        }
        if displayedIdentity == .body(input) || pendingInput == input {
            return .active
        }
        if let fileURL = cachedTemporaryFileURL(for: input) {
            cancelPending()
            failedInput = nil
            displayedIdentity = .body(input)
            return .cachedMovie(fileURL)
        }

        startPreparation(for: input, completion: completion)
        return .startedLoading
    }

    private func prepareRemoteMovie(_ url: URL) {
        cancelPending()
        failedInput = nil
        displayedIdentity = .remoteMovie(url)
        removeCachedTemporaryFile()
    }

    private func consume(
        result: NetworkMediaPayload?,
        input: NetworkMediaPreviewInput,
        generation: Int
    ) -> NetworkMediaPreviewResultAction {
        guard generation == self.generation,
              pendingInput == input else {
            result?.removeTemporaryFile()
            return .ignore
        }
        task = nil
        pendingInput = nil

        guard let result else {
            failedInput = input
            displayedIdentity = nil
            return .fallback
        }

        failedInput = nil
        displayedIdentity = .body(input)
        switch result {
        case .image(let image):
            removeCachedTemporaryFile()
            return .showImage(image)
        case .movie(let temporaryFile):
            replaceCachedTemporaryFile(with: temporaryFile)
            return .showMovie(temporaryFile.fileURL)
        }
    }

    private func startPreparation(
        for input: NetworkMediaPreviewInput,
        completion: @escaping @MainActor (NetworkMediaPreviewResultAction) -> Void
    ) {
        cancelPending()
        failedInput = nil
        displayedIdentity = nil
        pendingInput = input
        generation += 1
        let generation = generation

        let worker = Task.detached(priority: .utility) {
            await Self.makeMediaPayload(from: input)
        }
        task = Task { @MainActor [worker, completion] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard Task.isCancelled == false else {
                result?.removeTemporaryFile()
                return
            }
            completion(consume(result: result, input: input, generation: generation))
        }
    }

    private func cancelPending() {
        generation += 1
        task?.cancel()
        task = nil
        pendingInput = nil
    }

    private func cachedTemporaryFileURL(for input: NetworkMediaPreviewInput) -> URL? {
        guard input.previewKind == .movie || input.previewKind == .hlsPlaylist,
              let temporaryFile,
              temporaryFile.matches(input: input),
              FileManager.default.fileExists(atPath: temporaryFile.fileURL.path) else {
            return nil
        }
        return temporaryFile.fileURL
    }

    private func replaceCachedTemporaryFile(with newTemporaryFile: NetworkMediaTemporaryFile) {
        if temporaryFile?.fileURL == newTemporaryFile.fileURL {
            temporaryFile = newTemporaryFile
            return
        }
        removeCachedTemporaryFile()
        temporaryFile = newTemporaryFile
    }

    private func removeCachedTemporaryFile() {
        removeTemporaryMediaFile(at: temporaryFile?.fileURL)
        temporaryFile = nil
    }

    nonisolated private static func makeMediaPayload(
        from input: NetworkMediaPreviewInput
    ) async -> NetworkMediaPayload? {
        guard let data = input.data(), data.isEmpty == false else {
            return nil
        }

        switch input.previewKind {
        case .image:
            guard let image = await makeImagePayload(data: data) else {
                return nil
            }
            return .image(image)
        case .movie, .hlsPlaylist:
            return makeTemporaryMediaPayload(from: input, data: data)
        }
    }

    nonisolated private static func makeImagePayload(data: Data) async -> UIImage? {
        var configuration = UIImageReader.Configuration()
        configuration.preparesImagesForDisplay = true
        let reader = UIImageReader(configuration: configuration)
        return await reader.image(data: data)
    }

    nonisolated private static func makeTemporaryMediaPayload(
        from input: NetworkMediaPreviewInput,
        data: Data
    ) -> NetworkMediaPayload? {
        let fileExtension = mediaFileExtension(mimeType: input.mimeType, url: input.url)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: fileURL, options: [.atomic])
            return .movie(
                NetworkMediaTemporaryFile(
                    input: input,
                    fileURL: fileURL
                )
            )
        } catch {
            return nil
        }
    }
}

private enum NetworkMediaPreviewSource {
    case remoteMovie(URL)
    case body(NetworkMediaPreviewInput)
}

private enum NetworkMediaPreviewIdentity: Equatable {
    case remoteMovie(URL)
    case body(NetworkMediaPreviewInput)
}

private struct NetworkMediaPreviewInput: Equatable, Sendable {
    var previewKind: NetworkDisplay.MediaPreviewKind
    var bodyID: ObjectIdentifier
    var role: NetworkBody.Role
    var rawBody: String
    var isBase64Encoded: Bool
    var mimeType: String?
    var url: String?

    func data() -> Data? {
        if isBase64Encoded {
            return Data(base64Encoded: rawBody)
        }
        return rawBody.data(using: .utf8)
    }
}

private enum NetworkMediaPayload {
    case image(UIImage)
    case movie(NetworkMediaTemporaryFile)

    func removeTemporaryFile() {
        if case .movie(let file) = self {
            removeTemporaryMediaFile(at: file.fileURL)
        }
    }
}

private struct NetworkMediaTemporaryFile {
    var input: NetworkMediaPreviewInput
    var fileURL: URL

    func matches(input: NetworkMediaPreviewInput) -> Bool {
        self.input == input
    }
}

private func playableRemoteMediaURL(_ url: String?) -> URL? {
    guard let url = url.flatMap(URL.init(string:)) else {
        return nil
    }
    switch url.scheme?.lowercased() {
    case "http", "https":
        return url
    default:
        return nil
    }
}

private func mediaFileExtension(mimeType: String?, url: String?) -> String {
    NetworkDisplay.MediaPreviewSupport.temporaryFileExtension(mimeType: mimeType, url: url)
}

private func removeTemporaryMediaFile(at url: URL?) {
    guard let url else {
        return
    }
    try? FileManager.default.removeItem(at: url)
}
#endif
