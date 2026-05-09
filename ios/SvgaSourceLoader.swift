import Foundation

internal enum SvgaSourceLoader {

    private static let MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func loadEntity(_ source: String, completion: @escaping (Result<SvgaEntity, Error>) -> Void) {
        if let cached = SvgaMemoryCache.shared.get(source) {
            completion(.success(cached))
            return
        }
        loadData(source) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                do {
                    let parsed = try SvgaParser.parse(data)
                    SvgaMemoryCache.shared.put(source, parsed)
                    completion(.success(parsed))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    static func preloadRemote(_ url: String, completion: @escaping (Result<URL, Error>) -> Void) {
        if let cached = SvgaDiskCache.pathOrNil(url) {
            completion(.success(URL(fileURLWithPath: cached)))
            return
        }
        download(url) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                do {
                    let saved = try SvgaDiskCache.saveSvga(url, data: data)
                    completion(.success(saved))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    static func loadSoundFile(key: String, url: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let dest = SvgaDiskCache.soundURL(for: key)
        if FileManager.default.fileExists(atPath: dest.path) {
            completion(.success(dest))
            return
        }
        guard let resolved = UrlValidator.resolve(url) else {
            completion(.failure(SvgaError("invalid sound url: \(url)")))
            return
        }
        if resolved.kind == .localFile {
            completion(.success(URL(fileURLWithPath: resolved.value)))
            return
        }
        if resolved.kind == .bundledAsset {
            do {
                let data = try readBundleAsset(resolved.value)
                let saved = try SvgaDiskCache.saveSound(key, data: data)
                completion(.success(saved))
            } catch {
                completion(.failure(error))
            }
            return
        }
        download(resolved.value) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                do {
                    let saved = try SvgaDiskCache.saveSound(key, data: data)
                    completion(.success(saved))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func loadData(_ source: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let resolved = UrlValidator.resolve(source) else {
            completion(.failure(SvgaError("invalid source: \(source)")))
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
        if let cachedPath = SvgaDiskCache.pathOrNil(resolved.value) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: cachedPath), options: .mappedIfSafe)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
            return
        }
        download(resolved.value) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let data):
                _ = try? SvgaDiskCache.saveSvga(resolved.value, data: data)
                completion(.success(data))
            }
        }
    }

    private static func download(_ urlString: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(SvgaError("invalid url: \(urlString)")))
            return
        }
        let task = session.dataTask(with: url) { data, response, error in
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
            guard let data = data else {
                completion(.failure(SvgaError("empty body")))
                return
            }
            if data.count > MAX_DOWNLOAD_BYTES {
                completion(.failure(SvgaError("payload exceeds size limit")))
                return
            }
            completion(.success(data))
        }
        task.resume()
    }

    private static func readBundleAsset(_ name: String) throws -> Data {
        let bundle = Bundle.main
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        let baseName = parts.first.map(String.init) ?? name
        let ext = parts.count > 1 ? String(parts[1]) : nil
        guard let url = bundle.url(forResource: baseName, withExtension: ext) else {
            throw SvgaError("bundled asset not found: \(name)")
        }
        return try Data(contentsOf: url)
    }
}
