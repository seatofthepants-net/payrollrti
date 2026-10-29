import Foundation

/// A file download with progress, shared by the Linux build installer and the PayrollRTI updater.
enum Download {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads `url` to `destination`, reporting the fraction complete (nil until the size is known).
    static func file(_ url: URL, to destination: URL, progress: @escaping (Double?) -> Void = { _ in }) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("PayrollRTI (+\(Links.repository.absoluteString))", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request) { temporary, response, error in
                // The temporary file is deleted when this handler returns, so claim it here.
                if let error {
                    continuation.resume(throwing: error)
                } else if let temporary, let response {
                    do {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume(returning: response)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
                progress(value.totalUnitCount > 0 ? value.fractionCompleted : nil)
            }
            task.resume()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(
                message: "\(url.host ?? "The server") didn't have \(url.lastPathComponent) (HTTP \(http.statusCode)).")
        }
    }
}
