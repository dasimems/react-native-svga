import Foundation

internal enum SvgaSourceLoader {

    private static let MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024

    private static var inFlight: [String: InFlightLoad] = [:]
    private static var inFlightSounds: [String: URLSessionTask] = [:]
    private static let inFlightQueue = DispatchQueue(label: "svga.loader.inflight")
    private static var nextCallbackId: UInt64 = 0

    typealias LoadCallbackId = UInt64

    private final class InFlightLoad {
        var callbacks: [(id: LoadCallbackId, fn: (Result<SvgaEntity, Error>) -> Void)]
        var task: URLSessionTask?
        init(id: LoadCallbackId, callback: @escaping (Result<SvgaEntity, Error>) -> Void) {
            self.callbacks = [(id, callback)]
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Per-request idle timeout (max gap between received bytes). 15s was
        // too aggressive on flaky cellular — a brief stall mid-download tripped
        // NSURLErrorTimedOut (-1001) and failed the gift preload outright.
        config.timeoutIntervalForRequest = 30
        // Overall ceiling for one resource. A large SVGA on a slow link can
        // legitimately take longer than the old 60s.
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Total download attempts (initial + retries) for a transient network
    /// failure. Timeouts and dropped connections on mobile are usually
    /// momentary, so a couple of backed-off retries recover far more loads
    /// than a single longer timeout would.
    private static let MAX_DOWNLOAD_ATTEMPTS = 3
    /// Serial queue used only to schedule retry dispatches. Must NOT be
    /// `inFlightQueue` — `download` re-enters `inFlightQueue.sync` to
    /// re-register the retry task, which would deadlock on a re-entrant sync.
    private static let retryQueue = DispatchQueue(label: "svga.loader.retry")

    /// Transient, worth-retrying network errors. User cancellation and
    /// HTTP-status / payload errors are deliberately excluded.
    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff: 0.5s, 1s, 2s … capped at 4s.
    private static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        return min(0.5 * pow(2.0, Double(max(0, attempt - 1))), 4.0)
    }

    /// Heavy work (`SvgaParser.parse` runs zlib/zip inflate up to 64 MB and
    /// decodes every embedded image) is moved off the URLSession completion
    /// queue so it doesn't starve concurrent downloads on the same queue.
    private static let parseQueue = DispatchQueue(label: "svga.loader.parse", qos: .userInitiated, attributes: .concurrent)

    /// Returns an effective cache key for a source — falls back to the source
    /// itself when the caller didn't supply one. Keeps `loadEntity` and the
    /// memory/disk caches keyed identically to pre-cacheKey behaviour for
    /// string-only callers.
    private static func resolveKey(_ source: String, _ explicit: String?) -> String {
        if let key = explicit, !key.isEmpty { return key }
        return source
    }

    @discardableResult
    static func loadEntity(_ source: String, cacheKey: String? = nil, completion: @escaping (Result<SvgaEntity, Error>) -> Void) -> LoadCallbackId {
        let key = resolveKey(source, cacheKey)
        if let cached = SvgaMemoryCache.shared.get(key) {
            completion(.success(cached))
            return 0
        }

        var shouldStart = false
        var callbackId: LoadCallbackId = 0
        // Dedup by cacheKey, not source URL — two concurrent loads for the
        // same content (same key) coalesce into one fetch even if the user
        // passed slightly different signed URLs. Conversely, two different
        // cacheKeys never coalesce: rotating the key means "new identity",
        // which is the whole point of the API.
        inFlightQueue.sync {
            nextCallbackId += 1
            callbackId = nextCallbackId
            if let load = inFlight[key] {
                load.callbacks.append((callbackId, completion))
            } else {
                inFlight[key] = InFlightLoad(id: callbackId, callback: completion)
                shouldStart = true
            }
        }
        if !shouldStart { return callbackId }

        loadData(source, cacheKey: key, attachTaskFor: key) { result in
            switch result {
            case .failure(let err):
                fanOut(key: key, result: .failure(err))
            case .success(let data):
                // Hop off the URLSession callback queue before parsing —
                // a 64 MB inflate plus N image decodes here would block
                // every other download whose completion lands on the
                // same delegate queue.
                parseQueue.async {
                    do {
                        let parsed = try SvgaParser.parse(data)
                        SvgaMemoryCache.shared.put(key, parsed)
                        fanOut(key: key, result: .success(parsed))
                    } catch {
                        fanOut(key: key, result: .failure(error))
                    }
                }
            }
        }
        return callbackId
    }

    /// Cancel a single registered callback. The underlying network task is
    /// only cancelled when the last callback for that source is removed —
    /// other consumers waiting on the same URL receive the result normally.
    static func cancelLoad(_ source: String, cacheKey: String? = nil, callbackId: LoadCallbackId) {
        if callbackId == 0 { return }
        let key = resolveKey(source, cacheKey)
        var task: URLSessionTask?
        var callbacksToFire: [(Result<SvgaEntity, Error>) -> Void] = []
        inFlightQueue.sync {
            guard let load = inFlight[key] else { return }
            guard let idx = load.callbacks.firstIndex(where: { $0.id == callbackId }) else { return }
            callbacksToFire.append(load.callbacks[idx].fn)
            load.callbacks.remove(at: idx)
            if load.callbacks.isEmpty {
                task = load.task
                inFlight.removeValue(forKey: key)
            }
        }
        task?.cancel()
        let cancellation = SvgaError("load cancelled")
        for cb in callbacksToFire { cb(.failure(cancellation)) }
    }

    private static func fanOut(key: String, result: Result<SvgaEntity, Error>) {
        var callbacks: [(Result<SvgaEntity, Error>) -> Void] = []
        inFlightQueue.sync {
            callbacks = inFlight.removeValue(forKey: key)?.callbacks.map { $0.fn } ?? []
        }
        for cb in callbacks { cb(result) }
    }

    static func preloadRemote(_ url: String, cacheKey: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        let key = resolveKey(url, cacheKey)
        if let cached = SvgaDiskCache.cachedURL(key) {
            completion(.success(cached))
            return
        }
        download(url) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                do {
                    let saved = try SvgaDiskCache.saveSvga(key, data: data)
                    completion(.success(saved))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    static func loadSoundFile(key: String, url: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let resolved = UrlValidator.resolve(url) else {
            completion(.failure(SvgaError("invalid sound url")))
            return
        }
        if resolved.kind == .localFile {
            completion(.success(URL(fileURLWithPath: resolved.value)))
            return
        }
        // Disk-cache is keyed by URL (content-addressable). Keying by the
        // user play-handle would make the cache stale when the same handle
        // is reassigned to a different URL.
        let cacheKey = resolved.value
        if let cached = SvgaDiskCache.cachedSoundURL(for: cacheKey) {
            completion(.success(cached))
            return
        }
        if resolved.kind == .bundledAsset {
            do {
                let data = try readBundleAsset(resolved.value)
                let saved = try SvgaDiskCache.saveSound(cacheKey, data: data)
                completion(.success(saved))
            } catch {
                completion(.failure(error))
            }
            return
        }
        downloadSound(key: key, urlString: resolved.value) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                do {
                    let saved = try SvgaDiskCache.saveSound(cacheKey, data: data)
                    completion(.success(saved))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    static func cancelSoundLoad(key: String) {
        var task: URLSessionTask?
        inFlightQueue.sync {
            task = inFlightSounds.removeValue(forKey: key)
        }
        task?.cancel()
    }

    private static func downloadSound(key: String, urlString: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(SvgaError("invalid url")))
            return
        }
        let task = session.downloadTask(with: url) { tempURL, response, error in
            inFlightQueue.sync { _ = inFlightSounds.removeValue(forKey: key) }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(SvgaError("non-http response")))
                return
            }
            if !(200..<300).contains(http.statusCode) {
                completion(.failure(SvgaError("http \(http.statusCode)")))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(SvgaError("download missing temp file")))
                return
            }
            do {
                let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
                if data.count > MAX_DOWNLOAD_BYTES {
                    completion(.failure(SvgaError("payload exceeds size limit")))
                    return
                }
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
        }
        inFlightQueue.sync { inFlightSounds[key] = task }
        task.resume()
    }

    private static func loadData(_ source: String, cacheKey: String, attachTaskFor sourceForCancel: String? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let resolved = UrlValidator.resolve(source) else {
            completion(.failure(SvgaError("invalid source")))
            return
        }
        if resolved.kind == .localFile {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved.value), options: .mappedIfSafe)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
            return
        }
        if resolved.kind == .bundledAsset {
            do {
                let data = try readBundleAsset(resolved.value)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
            return
        }
        if let cachedURL = SvgaDiskCache.cachedURL(cacheKey) {
            do {
                let data = try Data(contentsOf: cachedURL, options: .mappedIfSafe)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
            return
        }
        download(resolved.value, attachTaskFor: sourceForCancel) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                // Async so we don't pin the URLSession completion queue on
                // a blocking write. Save under the explicit cacheKey so
                // subsequent reads via the same key hit.
                SvgaDiskCache.saveSvgaAsync(cacheKey, data: data)
                completion(.success(data))
            }
        }
    }

    private static func download(_ urlString: String, attachTaskFor sourceForCancel: String? = nil, attempt: Int = 1, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(SvgaError("invalid url")))
            return
        }
        let task = session.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                // Retry transient network failures (timeout, connection lost)
                // with backoff before giving up. Cancellation and HTTP/payload
                // errors fall through to the caller unchanged.
                let nsError = error as NSError
                if isRetryable(nsError) && attempt < MAX_DOWNLOAD_ATTEMPTS {
                    retryQueue.asyncAfter(deadline: .now() + backoffDelay(forAttempt: attempt)) {
                        download(urlString, attachTaskFor: sourceForCancel, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(SvgaError("non-http response")))
                return
            }
            if !(200..<300).contains(http.statusCode) {
                completion(.failure(SvgaError("http \(http.statusCode)")))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(SvgaError("download missing temp file")))
                return
            }
            do {
                // mappedIfSafe lets us pass the bytes around without
                // pinning the whole file in RAM. The mmap survives the
                // upcoming temp-file deletion because it holds the inode.
                let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
                if data.count > MAX_DOWNLOAD_BYTES {
                    completion(.failure(SvgaError("payload exceeds size limit")))
                    return
                }
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
        }
        if let key = sourceForCancel {
            var stillRegistered = false
            inFlightQueue.sync {
                if let load = inFlight[key] {
                    load.task = task
                    stillRegistered = true
                }
            }
            if !stillRegistered {
                // cancelLoad fired between callback registration and task creation;
                // don't bother starting the download.
                task.cancel()
                return
            }
        }
        task.resume()
    }

    private static func readBundleAsset(_ name: String) throws -> Data {
        guard let url = bundleURL(for: name) else {
            throw SvgaError("bundled asset not found: \(name)")
        }
        return try Data(contentsOf: url)
    }

    /// Resolves a name like `animations/cheer.svga` to a Bundle URL,
    /// honoring subdirectories and extensions.
    static func bundleURL(for name: String) -> URL? {
        let (subdirectory, base, ext) = splitBundleResource(name)
        return Bundle.main.url(forResource: base, withExtension: ext, subdirectory: subdirectory)
    }

    /// Splits "animations/foo.bar.svga" into ("animations", "foo.bar", "svga"),
    /// "cheer.svga" into (nil, "cheer", "svga"), "cheer" into (nil, "cheer", nil).
    static func splitBundleResource(_ name: String) -> (subdirectory: String?, base: String, ext: String?) {
        let subdirectory: String?
        let fileName: String
        if let lastSlash = name.lastIndex(of: "/") {
            subdirectory = String(name[..<lastSlash])
            fileName = String(name[name.index(after: lastSlash)...])
        } else {
            subdirectory = nil
            fileName = name
        }
        let (base, ext) = splitBundleName(fileName)
        return (subdirectory: subdirectory, base: base, ext: ext)
    }

    static func splitBundleName(_ name: String) -> (String, String?) {
        guard let lastDot = name.lastIndex(of: ".") else { return (name, nil) }
        let base = String(name[..<lastDot])
        let ext = String(name[name.index(after: lastDot)...])
        return (base, ext.isEmpty ? nil : ext)
    }
}
