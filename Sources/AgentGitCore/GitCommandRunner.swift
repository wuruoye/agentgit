import Foundation

public struct GitCommandFailure: Error, CustomStringConvertible, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public init(arguments: [String], exitCode: Int32, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "git exited with status \(exitCode)"
            : detail
    }
}

/// `Process` 不是 Sendable，取消回调又必须是 @Sendable，用它把进程句柄和取消状态收在锁后面。
private final class GitProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// 只在进程已启动后调用。返回 false 表示任务在启动期间已被取消，调用方需要立刻终止它。
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else {
            return false
        }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        let running = process
        isCancelled = true
        lock.unlock()
        running?.terminate()
    }
}

public struct GitCommandRunner: Sendable {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    public func run(
        arguments: [String],
        workingDirectory: URL,
        standardInput: Data? = nil
    ) async throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let stdinHandle: FileHandle?
        if let standardInput {
            let stdinURL = temporaryDirectory.appendingPathComponent("stdin")
            try standardInput.write(to: stdinURL)
            stdinHandle = try FileHandle(forReadingFrom: stdinURL)
        } else {
            stdinHandle = nil
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? stdinHandle?.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = stdinHandle

        let handle = GitProcessHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                    if !handle.adopt(process) {
                        process.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.cancel()
        }
        // 被终止的 git 退出码非 0，先报取消，避免上层把它当成 git 失败弹错误。
        try Task.checkCancellation()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()

        let stdout = try Data(contentsOf: stdoutURL)
        guard process.terminationStatus == 0 else {
            let stderrData = try Data(contentsOf: stderrURL)
            throw GitCommandFailure(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }

        return stdout
    }
}
