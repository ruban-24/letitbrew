import Darwin
import Foundation

private enum BoundedHTTPSResourceError: LocalizedError {
    case destinationExists
    case couldNotCreateDestination(Int32)
    case nonHTTPSRedirect
    case invalidResponse
    case httpStatus(Int)
    case insecureFinalURL
    case declaredSize(Int64)
    case exceededLimit(Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists:
            "The download destination already exists."
        case .couldNotCreateDestination(let code):
            "The download destination could not be created (errno \(code))."
        case .nonHTTPSRedirect:
            "The server tried to redirect the update to a non-HTTPS URL."
        case .invalidResponse:
            "The update server returned a response Let It Brew could not validate."
        case .httpStatus(let status):
            "The update server returned HTTP \(status)."
        case .insecureFinalURL:
            "The update response did not finish on HTTPS."
        case .declaredSize(let size):
            "The update server declared an invalid size of \(size) bytes."
        case .exceededLimit(let limit):
            "The update download exceeded its \(limit)-byte limit."
        case .sizeMismatch(let expected, let actual):
            "The update download was \(actual) bytes; GitHub declared \(expected)."
        case .writeFailed(let detail):
            "The update download could not be saved: \(detail)"
        }
    }
}

/// One transfer per instance. URLSession invokes this delegate on the serial
/// queue created in `load`, so mutable transfer state is never concurrently
/// accessed. The unchecked annotation documents that confinement explicitly.
private final class BoundedHTTPSResourceDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    let maximumBytes: Int64
    let expectedBytes: Int64?
    let destination: URL?

    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private let cancellationLock = NSLock()
    private var dataTask: URLSessionDataTask?
    private var cancellationRequested = false
    private var fileHandle: FileHandle?
    private var buffer = Data()
    private var receivedBytes: Int64 = 0
    private var recordedError: Error?
    private var finished = false

    init(maximumBytes: Int64, expectedBytes: Int64?, destination: URL?) {
        self.maximumBytes = maximumBytes
        self.expectedBytes = expectedBytes
        self.destination = destination
    }

    func load(request: URLRequest) async throws -> Data {
        if let destination {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw BoundedHTTPSResourceError.destinationExists
            }
            let descriptor = destination.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw BoundedHTTPSResourceError.couldNotCreateDestination(errno)
            }
            fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 180
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.urlCache = nil
                    let delegateQueue = OperationQueue()
                    delegateQueue.name = "Let It Brew bounded update download"
                    delegateQueue.maxConcurrentOperationCount = 1
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: delegateQueue
                    )
                    self.session = session
                    let task = session.dataTask(with: request)
                    cancellationLock.lock()
                    dataTask = task
                    let shouldCancel = cancellationRequested
                    cancellationLock.unlock()
                    task.resume()
                    if shouldCancel { task.cancel() }
                }
            },
            onCancel: {
                self.cancellationLock.lock()
                self.cancellationRequested = true
                let task = self.dataTask
                self.cancellationLock.unlock()
                task?.cancel()
            }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            recordedError = BoundedHTTPSResourceError.nonHTTPSRedirect
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard recordedError == nil,
              let response = response as? HTTPURLResponse
        else {
            recordedError = recordedError ?? BoundedHTTPSResourceError.invalidResponse
            completionHandler(.cancel)
            return
        }
        guard response.statusCode == 200 else {
            recordedError = BoundedHTTPSResourceError.httpStatus(response.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            recordedError = BoundedHTTPSResourceError.insecureFinalURL
            completionHandler(.cancel)
            return
        }
        let declared = response.expectedContentLength
        if declared != NSURLSessionTransferSizeUnknown {
            guard declared >= 0, declared <= maximumBytes else {
                recordedError = BoundedHTTPSResourceError.declaredSize(declared)
                completionHandler(.cancel)
                return
            }
            if let expectedBytes, declared != expectedBytes {
                recordedError = BoundedHTTPSResourceError.sizeMismatch(
                    expected: expectedBytes,
                    actual: declared
                )
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard recordedError == nil else { return }
        let nextCount = receivedBytes + Int64(data.count)
        guard nextCount <= maximumBytes,
              expectedBytes.map({ nextCount <= $0 }) ?? true
        else {
            recordedError = BoundedHTTPSResourceError.exceededLimit(
                min(maximumBytes, expectedBytes ?? maximumBytes)
            )
            dataTask.cancel()
            return
        }
        do {
            if let fileHandle {
                try fileHandle.write(contentsOf: data)
            } else {
                buffer.append(data)
            }
            receivedBytes = nextCount
        } catch {
            recordedError = BoundedHTTPSResourceError.writeFailed(error.localizedDescription)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if recordedError == nil, let error {
            recordedError = error
        }
        if recordedError == nil, let expectedBytes, receivedBytes != expectedBytes {
            recordedError = BoundedHTTPSResourceError.sizeMismatch(
                expected: expectedBytes,
                actual: receivedBytes
            )
        }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
        } catch {
            recordedError = recordedError ?? BoundedHTTPSResourceError.writeFailed(
                error.localizedDescription
            )
        }
        fileHandle = nil

        if let recordedError {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            continuation?.resume(throwing: recordedError)
        } else {
            continuation?.resume(returning: buffer)
        }
        continuation = nil
        cancellationLock.lock()
        dataTask = nil
        cancellationLock.unlock()
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

enum BoundedHTTPSResource {
    static func load(
        request: URLRequest,
        maximumBytes: Int64,
        expectedBytes: Int64?,
        destination: URL?
    ) async throws -> Data {
        guard request.url?.scheme?.lowercased() == "https",
              maximumBytes > 0,
              expectedBytes.map({ $0 > 0 && $0 <= maximumBytes }) ?? true
        else {
            throw BoundedHTTPSResourceError.invalidResponse
        }
        return try await BoundedHTTPSResourceDelegate(
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes,
            destination: destination
        ).load(request: request)
    }
}
