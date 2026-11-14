import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Plays a file on the host Mac without pulling it: AVFoundation asks for byte ranges through a
/// resource loader on a private URL scheme, answered from `fileData` (or the render preview)
/// pieces, with a small block cache and one block read ahead.
final class RemoteStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// One piece of the file at `offset` (it may be shorter than asked) and the whole file's size.
    typealias Reader = @Sendable (_ offset: Int64, _ length: Int) async throws -> (data: Data, size: Int64)

    static let scheme = "pluckstream"
    static let block = 2 << 20

    let contentType: String
    private let cache: BlockCache
    private let queue = DispatchQueue(label: "be.wideopen.pluck.remote-stream")
    private let lock = NSLock()
    private var loading: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(contentType: String, read: @escaping Reader) {
        self.contentType = contentType
        cache = BlockCache(read: read)
    }

    /// A file in a share: its proxy (light), or the original when asked for.
    static func file(share: String, path: String, kind: OfficeRenderClient.FileKind) -> RemoteStream {
        let type = kind == .proxy ? UTType.quickTimeMovie : (UTType(filenameExtension: (path as NSString).pathExtension) ?? .movie)
        return RemoteStream(contentType: type.identifier) { offset, length in
            try await OfficeRenderClient.shared.fileData(share: share, path: path, kind: kind, offset: offset, length: length)
        }
    }

    /// A finished render's preview (the built-in `preview` action, base64 pieces of previewChunk).
    @MainActor
    static func preview(_ job: OfficeRenderClient.Job) -> RemoteStream {
        let id = job.id
        return RemoteStream(contentType: UTType.mpeg4Movie.identifier) { offset, _ in
            let answer = try await OfficeRenderClient.shared.ask("preview", ["id": id, "offset": offset])
            guard let text = answer["data"] as? String, let data = Data(base64Encoded: text),
                  let size = (answer["size"] as? NSNumber)?.int64Value else { throw OfficeLink.Failure.garbled }
            return (data, size)
        }
    }

    /// The bytes at `offset` (fewer at the end of the file), from the cache or the host.
    func bytes(_ offset: Int64, _ length: Int) async throws -> Data { try await cache.bytes(offset, length) }
    func size() async throws -> Int64 { try await cache.size() }

    /// An asset that reads through this stream (keep the stream alive as long as the asset: the
    /// resource loader holds its delegate weakly).
    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://host/\(UUID().uuidString)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: - AVAssetResourceLoaderDelegate

    private final class Box: @unchecked Sendable { let request: AVAssetResourceLoadingRequest; init(_ r: AVAssetResourceLoadingRequest) { request = r } }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let box = Box(loadingRequest), key = ObjectIdentifier(loadingRequest), type = contentType
        let task = Task { [weak self] in
            guard let self else { return }
            let request = box.request
            do {
                let size = try await self.cache.size()
                if let info = request.contentInformationRequest {
                    info.contentType = type
                    info.contentLength = size
                    info.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    var offset = data.currentOffset
                    let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
                    while offset < end {
                        try Task.checkCancellation()
                        let piece = try await self.cache.bytes(offset, Int(min(Int64(Self.block), end - offset)))
                        if piece.isEmpty { break }
                        data.respond(with: piece)
                        offset += Int64(piece.count)
                    }
                }
                if !Task.isCancelled { request.finishLoading() }
            } catch {
                if !Task.isCancelled { request.finishLoading(with: error) }
            }
            self.lock.withLock { _ = self.loading.removeValue(forKey: key) }
        }
        lock.withLock { loading[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { loading.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    /// Aligned blocks of the file, the last few kept, the next one fetched ahead.
    private actor BlockCache {
        static let kept = 8
        let read: Reader
        var total: Int64?
        var blocks: [Int64: Data] = [:]
        var used: [Int64] = []
        var fetching: [Int64: Task<(Data, Int64), Error>] = [:]

        init(read: @escaping Reader) { self.read = read }

        func size() async throws -> Int64 {
            if let total { return total }
            _ = try await block(0)
            return total ?? 0
        }

        func bytes(_ offset: Int64, _ length: Int) async throws -> Data {
            var result = Data()
            var at = offset
            let block = Int64(RemoteStream.block)
            while result.count < length {
                let index = at / block
                let data = try await self.block(index)
                let start = Int(at - index * block)
                guard start < data.count else { break }
                let piece = data[(data.startIndex + start)..<(data.startIndex + min(data.count, start + length - result.count))]
                result.append(piece)
                at += Int64(piece.count)
                if data.count < RemoteStream.block { break }  // the file's last block
            }
            // Read ahead: the block holding the next byte and the one after it.
            if let total { for next in [at / block, at / block + 1] where next * block < total { ahead(next) } }
            return result
        }

        private func ahead(_ index: Int64) {
            guard blocks[index] == nil, fetching[index] == nil else { return }
            Task { _ = try? await block(index) }
        }

        private func block(_ index: Int64) async throws -> Data {
            if let data = blocks[index] {
                used.removeAll { $0 == index }
                used.append(index)
                return data
            }
            if let task = fetching[index] { return try await task.value.0 }
            let read = read
            let task = Task<(Data, Int64), Error> {
                // A reader may answer in smaller pieces (the preview's 1.5 MB): fill the block.
                let start = index * Int64(RemoteStream.block)
                var data = Data()
                var size: Int64 = .max
                while data.count < RemoteStream.block, start + Int64(data.count) < size {
                    let piece = try await read(start + Int64(data.count), RemoteStream.block - data.count)
                    size = piece.size
                    if piece.data.isEmpty { break }
                    data.append(piece.data)
                }
                return (data.count > RemoteStream.block ? data.prefix(RemoteStream.block) : data, size)
            }
            fetching[index] = task
            defer { fetching[index] = nil }
            let (data, size) = try await task.value
            if size != .max { total = size }
            if blocks[index] == nil {
                blocks[index] = data
                used.append(index)
                while used.count > Self.kept { blocks[used.removeFirst()] = nil }
            }
            return data
        }
    }
}

/// The hook B2's browser uses: a player for a file on the host.
@MainActor
extension RemoteStream {
    static func install() {
        RemoteHooks.player = { share, path in AnyView(RemoteStreamPlayer(share: share, path: path)) }
    }
}

/// Plays a share's file from the host: its proxy, or the original when there's no proxy and this
/// Mac may fetch originals. Says so when the host is offline or there's nothing to play yet.
struct RemoteStreamPlayer: View {
    let share: String
    let path: String
    @State private var state = Loading.waiting
    @State private var attempt = 0

    enum Loading {
        case waiting
        case playing(AVPlayer, RemoteStream)
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color.black
            switch state {
            case .waiting:
                ProgressView().controlSize(.small)
            case .playing(let player, _):
                RemotePlayerSurface(player: player)
            case .failed(let problem):
                VStack(spacing: 10) {
                    Image(systemName: "play.slash").font(.system(size: 20)).foregroundStyle(Design.Studio.textQuiet)
                    Text(problem).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                    Button("Try again") { attempt += 1 }.buttonStyle(StudioFlatButtonStyle(height: 28))
                }
                .padding(16)
            }
        }
        .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .task(id: "\(share)/\(path)/\(attempt)") { await open() }
        .onDisappear { if case .playing(let player, _) = state { player.pause() } }
    }

    private func open() async {
        state = .waiting
        var problem: String?
        for kind in [OfficeRenderClient.FileKind.proxy, .original] {
            let stream = RemoteStream.file(share: share, path: path, kind: kind)
            do {
                _ = try await stream.size()
                guard !Task.isCancelled else { return }
                state = .playing(AVPlayer(playerItem: AVPlayerItem(asset: stream.asset())), stream)
                return
            } catch {
                problem = problem ?? error.localizedDescription  // the proxy's reason says most
            }
        }
        state = .failed(problem ?? String(localized: "This can’t be played from the host Mac."))
    }
}

/// AVKit's player view with its inline controls.
struct RemotePlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
