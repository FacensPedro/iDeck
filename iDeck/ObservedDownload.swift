import Foundation

/// A download with real progress. The async `URLSession.download(from:delegate:)`
/// does not report `didWriteData` to a per-task delegate, so progress stayed at 0%
/// until a large file had finished. This runs the task on its own delegate session,
/// which always gets progress, and supports resume data and cancellation.
final class ObservedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: Error { let error: Error; let resumeData: Data? }

    private let expected: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var kept: URL?
    private let lock = NSLock()

    private init(expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    /// Downloads `request` (or resumes from `resumeData`) into a temporary file the
    /// caller owns. `progress` gets the bytes written and the expected total.
    static func run(_ request: URLRequest, resumeData: Data? = nil, expected: Int64 = 0,
                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let download = ObservedDownload(expected: expected, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.lock()
                download.continuation = continuation
                download.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is removed when this returns: keep it.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil {
            lock.lock(); kept = target; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let file = kept
        lock.unlock()
        guard let continuation else { return }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation.resume(throwing: Failure(error: error, resumeData: resume))
        } else if let file, let response = task.response as? HTTPURLResponse {
            continuation.resume(returning: (file, response))
        } else {
            continuation.resume(throwing: Failure(error: URLError(.cannotCreateFile), resumeData: nil))
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
