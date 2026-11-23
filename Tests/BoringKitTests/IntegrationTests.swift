import Foundation
import KSCrashRecording
import Testing

@testable import BoringKit

/// Talks to a running Worker, so it only runs when BORINGKIT_API is set. Run it with
/// scripts/integration-test.sh, which then checks that every row tagged with BORINGKIT_RUN reached D1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BORINGKIT_API"] != nil))
@MainActor
func sendsEverythingToTheWorker() async throws {
    struct SmokeError: LocalizedError {
        let run: String
        var errorDescription: String? { run }
    }
    let env = ProcessInfo.processInfo.environment
    let api = try #require(env["BORINGKIT_API"].flatMap(URL.init(string:)))
    let run = env["BORINGKIT_RUN"] ?? UUID().uuidString

    BoringKit.start(api: api)
    // a non-fatal KSCrash report, so the crash upload path has something to send
    KSCrash.shared.reportUserException(
        "SmokeException", reason: run, language: "swift", lineOfCode: nil,
        stackTrace: nil, logAllThreads: false, terminateProgram: false
    )

    #expect(await BoringKit.sendFeedback("integration test \(run)", email: "test@example.com"))

    try await Task.sleep(for: .seconds(1))  // let start() finish registering and uploading
    Aptabase.shared.trackEvent("integration_test", with: ["run": run])
    Aptabase.shared.trackError(SmokeError(run: run))
    try await Task.sleep(for: .milliseconds(300))  // trackEvent/trackError enqueue from a background Task
    await Aptabase.shared.flush()
    #expect(KSCrash.shared.reportStore?.reportCount == 0)
}
