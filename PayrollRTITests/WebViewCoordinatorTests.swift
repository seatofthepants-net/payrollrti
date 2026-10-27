import XCTest

@testable import PayrollRTI

@MainActor
final class WebViewCoordinatorTests: XCTestCase {
    private func request(_ method: String, _ path: String) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8000\(path)")))
        request.httpMethod = method
        return request
    }

    func testRecognisesRestoreFormPost() throws {
        XCTAssertTrue(WebViewCoordinator.isRestoreSubmission(try request("POST", "/bptrti/restore/")))
        XCTAssertTrue(WebViewCoordinator.isRestoreSubmission(try request("post", "/bptrti/restore")))
    }

    func testIgnoresOtherRequests() throws {
        // Opening the restore page, and the redirect home once it's done, must not count.
        XCTAssertFalse(WebViewCoordinator.isRestoreSubmission(try request("GET", "/bptrti/restore/")))
        XCTAssertFalse(WebViewCoordinator.isRestoreSubmission(try request("GET", "/pages/home/")))
        XCTAssertFalse(WebViewCoordinator.isRestoreSubmission(try request("POST", "/bptrti/backup/")))
    }
}
