import Foundation

/// Uploads originals with a background URLSession: transfers keep going while the app is suspended, and iOS wakes
/// the app to report completions.
public final class BackgroundUploader: NSObject, OriginalUploader, URLSessionDataDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.shaunakkapur.bottomless.uploads"
    public var onFinished: (@Sendable (String, Int, String?) -> Void)?
    /// Set by the app delegate when iOS relaunches the app for session events.
    public var backgroundCompletion: (() -> Void)?
    private let identifier: String
    private let allowsCellular: Bool
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = allowsCellular
        c.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    public init(identifier: String = BackgroundUploader.defaultIdentifier, allowsCellular: Bool = false) {
        self.identifier = identifier
        self.allowsCellular = allowsCellular
        super.init()
    }

    /// Creating the session reconnects to transfers that ran while the app was not running.
    public func connect() { _ = session }

    public func start(file: URL, target: UploadTarget, tag: String) throws {
        var req = URLRequest(url: target.url)
        req.httpMethod = target.method
        for (k, v) in target.headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = tag
        task.resume()
    }

    public func activeTags() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        onFinished?(task.taskDescription ?? "", status, error?.localizedDescription)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }
}

/// Plain in-process uploads (tests, and a fallback when background sessions are not wanted).
public final class DirectUploader: OriginalUploader, @unchecked Sendable {
    public var onFinished: (@Sendable (String, Int, String?) -> Void)?
    private let session: URLSession
    private let lock = NSLock()
    private var active: Set<String> = []

    public init(session: URLSession = .shared) { self.session = session }

    public func start(file: URL, target: UploadTarget, tag: String) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileNoSuchFile) }
        var req = URLRequest(url: target.url)
        req.httpMethod = target.method
        for (k, v) in target.headers { req.setValue(v, forHTTPHeaderField: k) }
        lock.withLock { _ = active.insert(tag) }
        Task { [session, weak self] in
            var status = 0
            var err: String?
            do {
                let (_, resp) = try await session.upload(for: req, fromFile: file)
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            } catch { err = error.localizedDescription }
            self?.lock.withLock { _ = self?.active.remove(tag) }
            self?.onFinished?(tag, status, err)
        }
    }

    public func activeTags() async -> Set<String> {
        lock.withLock { active }
    }
}
