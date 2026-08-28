import Foundation
import XCTest
@testable import AgentGitCore

final class GitCommandRunnerTests: XCTestCase {
    func testStandardInputLargerThanPipeBufferRoundTrips() async throws {
        let input = Data(repeating: 0x41, count: 512 * 1_024)
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))

        let output = try await runner.run(
            arguments: [],
            workingDirectory: repositoryRoot,
            standardInput: input
        )

        XCTAssertEqual(output, input)
    }

    func testOutputLimitDrainsProcessAndReportsActualByteCount() async throws {
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/dd"))

        do {
            _ = try await runner.run(
                arguments: ["if=/dev/zero", "bs=1024", "count=256"],
                workingDirectory: repositoryRoot,
                maximumOutputBytes: 64 * 1_024
            )
            XCTFail("Expected output limit error")
        } catch let error as GitCommandOutputLimitError {
            XCTAssertEqual(error.limit, 64 * 1_024)
            XCTAssertEqual(error.actualByteCount, 256 * 1_024)
        }
    }

    func testCommandFailurePreservesStandardError() async throws {
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

        do {
            _ = try await runner.run(
                arguments: ["-c", "printf 'runner failure' >&2; exit 7"],
                workingDirectory: repositoryRoot
            )
            XCTFail("Expected command failure")
        } catch let error as GitCommandFailure {
            XCTAssertEqual(error.exitCode, 7)
            XCTAssertEqual(error.stderr, "runner failure")
        }
    }

    func testCommandFailureBoundsStoredStandardErrorAndReportsTruncation() async throws {
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

        do {
            _ = try await runner.run(
                arguments: [
                    "-c",
                    "/bin/dd if=/dev/zero bs=1024 count=256 >&2; exit 9"
                ],
                workingDirectory: repositoryRoot,
                maximumErrorBytes: 64 * 1_024
            )
            XCTFail("Expected command failure")
        } catch let error as GitCommandFailure {
            XCTAssertEqual(error.exitCode, 9)
            XCTAssertLessThan(error.stderr.utf8.count, 66 * 1_024)
            XCTAssertTrue(
                error.stderr.contains("Git error output truncated after 65536")
            )
        }
    }

    func testTimeoutTerminatesCommandAndReportsTimeout() async throws {
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(
                arguments: ["5"],
                workingDirectory: repositoryRoot,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout error")
        } catch is GitCommandTimeoutError {
            XCTAssertLessThan(startedAt.duration(to: .now), .seconds(2))
        }
    }

    func testTimeoutForceTerminatesCommandAndChildThatIgnoreTermination() async throws {
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(
                arguments: ["-c", "trap '' TERM; /bin/sleep 10"],
                workingDirectory: repositoryRoot,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout error")
        } catch is GitCommandTimeoutError {
            XCTAssertLessThan(startedAt.duration(to: .now), .seconds(2))
        }
    }

    private var repositoryRoot: URL {
        URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    }
}
