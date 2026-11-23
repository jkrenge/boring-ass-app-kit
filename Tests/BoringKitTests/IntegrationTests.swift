import Foundation
import KSCrashRecording
import Testing

@testable import BoringKit

/// Talks to a running Worker, so it only runs when BORINGKIT_API is set (see README "Testing").
@Test(.enabled(if: ProcessInfo.processInfo.environment["BORINGKIT_API"] != nil))
@MainActor
func sendsEverythingToTheWorker() async throws {
    struct SmokeError: Error {}
    let api = try #require(ProcessInfo.processInfo.environment["BORINGKIT_API"].flatMap(URL.init(string:)))

    BoringKit.start(api: api)
    // a non-fatal KSCrash report, so the crash upload path has something to send
    KSCrash.shared.reportUserException(
        "SmokeException", reason: "integration test", language: "swift", lineOfCode: nil,
        stackTrace: nil, logAllThreads: false, terminateProgram: false
    )

    #expect(await BoringKit.sendFeedback("integration test feedback", email: "test@example.com"))

    try await Task.sleep(for: .seconds(1))  // let start() finish initializing Aptabase and uploading
    Aptabase.shared.trackEvent("integration_test", with: ["ok": true])
    Aptabase.shared.trackError(SmokeError())
    await Aptabase.shared.flush()
    #expect(KSCrash.shared.reportStore?.reportCount == 0)
}
