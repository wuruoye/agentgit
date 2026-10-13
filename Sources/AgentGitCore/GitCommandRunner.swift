import Darwin
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

public struct GitCommandOutputLimitError: Error, CustomStringConvertible, Sendable {
    public let limit: Int
    public let actualByteCount: Int

    public init(limit: Int, actualByteCount: Int) {
        self.limit = limit
        self.actualByteCount = actualByteCount
    }

    public var description: String {
        "Command output contains \(actualByteCount) bytes; limit is \(limit) bytes."
    }
}

public struct GitCommandTimeoutError: Error, CustomStringConvertible, Sendable {
    public let arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }

    public var description: String {
        "Command timed out before completing."
    }
}

private enum GitProcessTerminationReason: Equatable {
    case cancelled
    case timedOut
}

private enum GitProcessTree {
    private static let initialChildCapacity = 16

    static func descendants(of rootPID: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []
        var pending = [rootPID]
        var visited: Set<pid_t> = [rootPID]
        while let parentPID = pending.popLast() {
            for childPID in directChildren(of: parentPID)
                where childPID > 1 && visited.insert(childPID).inserted {
                descendants.append(childPID)
                pending.append(childPID)
            }
        }
        return descendants
    }

    static func send(_ signal: Int32, to processIDs: [pid_t]) {
        for processID in processIDs.reversed() where processID > 1 {
            _ = Darwin.kill(processID, signal)
        }
    }

    private static func directChildren(of parentPID: pid_t) -> [pid_t] {
        var capacity = initialChildCapacity
        while true {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                proc_listchildpids(
                    parentPID,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard count > 0 else {
                return []
            }
            if count < capacity {
                return Array(processIDs.prefix(Int(count)))
            }
            capacity *= 2
        }
    }
}

/// `Process` 缺少 Sendable；取消回调要求 @Sendable，因此把进程句柄和取消状态收在锁后面。
private final class GitProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminationReason: GitProcessTerminationReason?

    /// 只在进程已启动后调用；启动期间已经取消时会在这里终止新进程。
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        guard terminationReason == nil else {
            lock.unlock()
            Self.terminateProcess(process)
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func cancel() {
        terminate(reason: .cancelled)
    }

    func timeOut() {
        terminate(reason: .timedOut)
    }

    func finish() -> GitProcessTerminationReason? {
        lock.lock()
        process = nil
        let reason = terminationReason
        lock.unlock()
        return reason
    }

    private func terminate(reason: GitProcessTerminationReason) {
        lock.lock()
        guard terminationReason == nil else {
            lock.unlock()
            return
        }
        let running = process
        if let running, !running.isRunning {
            lock.unlock()
            return
        }
        terminationReason = reason
        lock.unlock()
        if let running {
            Self.terminateProcess(running)
        }
    }

    private static func terminateProcess(_ process: Process) {
        let rootPID = process.processIdentifier
        let initialDescendants = GitProcessTree.descendants(of: rootPID)
        GitProcessTree.send(SIGTERM, to: initialDescendants)
        process.terminate()
        Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            let laterDescendants = GitProcessTree.descendants(of: rootPID)
            let processIDs = Array(Set(initialDescendants + laterDescendants + [rootPID]))
            GitProcessTree.send(SIGKILL, to: processIDs)
        }
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let waiters = waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func value() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

private struct CapturedProcessOutput: Sendable {
    let data: Data
    let byteCount: Int
}

/// `FileHandle.readabilityHandler` 持续排空 pipe，避免并发 Git 大输出填满内核缓冲区。
/// 超过上限后继续读取并统计字节数，但不再扩张内存。
private final class ProcessPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let maximumStoredByteCount: Int?
    private let lock = NSLock()
    private var data = Data()
    private var byteCount = 0
    private var completedOutput: CapturedProcessOutput?
    private var waiters: [CheckedContinuation<CapturedProcessOutput, Never>] = []

    init(maximumStoredByteCount: Int?) {
        self.maximumStoredByteCount = maximumStoredByteCount
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
    }

    func finish() {
        receive(Data())
    }

    func value() async -> CapturedProcessOutput {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completedOutput {
                lock.unlock()
                continuation.resume(returning: completedOutput)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else {
            complete()
            return
        }
        lock.lock()
        guard completedOutput == nil else {
            lock.unlock()
            return
        }
        byteCount += chunk.count
        if let maximumStoredByteCount {
            let remaining = max(0, maximumStoredByteCount - data.count)
            if remaining > 0 {
                data.append(contentsOf: chunk.prefix(remaining))
            }
        } else {
            data.append(chunk)
        }
        lock.unlock()
    }

    private func complete() {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        guard completedOutput == nil else {
            lock.unlock()
            return
        }
        let output = CapturedProcessOutput(data: data, byteCount: byteCount)
        completedOutput = output
        let waiters = waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: output)
        }
    }
}

public struct GitCommandRunner: Sendable {
    /// 从 Dock/Finder 启动时 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，git hook 和 LFS 过滤器找不到 Homebrew 装的 git-lfs。
    // ponytail: 只补 Homebrew 默认目录；工具装在其他位置时再改为读取 login shell 的 PATH。
    static let baseEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        var paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(directory) {
            paths.append(directory)
        }
        environment["PATH"] = paths.joined(separator: ":")
        for name in ["GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] {
            environment[name] = nil
        }
        // AgentGit 自己执行的 git 不代表任何 agent 会话。从 agent 终端启动或在 agent 会话里跑测试时
        // 会继承这些变量，全局 worktree 创建者 hook 会把 AgentGit 的操作记到那个会话名下。
        for name in ["CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID", "CODEX_THREAD_ID"] {
            environment[name] = nil
        }
        return environment
    }()

    /// macOS 的 /usr/bin/git 会经 xcrun 转到开发工具里的 Git，整个进程只解析一次。
    private static let defaultExecutableURL: URL = {
        let environment = baseEnvironment
        let fileManager = FileManager.default
        var developerDirectory: URL?
        if let configured = environment["DEVELOPER_DIR"] {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            developerDirectory = url.pathExtension == "app"
                ? url.appendingPathComponent("Contents/Developer", isDirectory: true)
                : url
        } else {
            let selected = URL(fileURLWithPath: "/var/db/xcode_select_link")
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: selected.path) {
                developerDirectory = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target, isDirectory: true)
                    : selected.deletingLastPathComponent().appendingPathComponent(target, isDirectory: true)
            }
        }
        if let git = developerDirectory?.appendingPathComponent("usr/bin/git"),
           fileManager.isExecutableFile(atPath: git.path) {
            return git.standardizedFileURL
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            output.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, path.hasPrefix("/"),
               fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    let executableURL: URL
    let diagnostics: AgentGitDiagnostics

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        diagnostics: AgentGitDiagnostics = .shared
    ) {
        self.executableURL = executableURL.path == "/usr/bin/git"
            ? Self.defaultExecutableURL
            : executableURL
        self.diagnostics = diagnostics
    }

    public func run(
        arguments: [String],
        workingDirectory: URL,
        standardInput: Data? = nil,
        maximumOutputBytes: Int? = nil,
        maximumErrorBytes: Int? = nil,
        environment: [String: String] = [:],
        timeout: Duration? = nil,
        standardOutputFile: URL? = nil
    ) async throws -> Data {
        let trace = GitCommandDiagnosticTrace(
            diagnostics: diagnostics, executable: executableURL, arguments: arguments,
            workingDirectory: workingDirectory, timeout: timeout,
            maximumOutputBytes: maximumOutputBytes, maximumErrorBytes: maximumErrorBytes,
            writesOutputFile: standardOutputFile != nil
        )
        defer { trace.finish() }
        do {
            return try await execute(
                arguments: arguments, workingDirectory: workingDirectory, standardInput: standardInput,
                maximumOutputBytes: maximumOutputBytes, maximumErrorBytes: maximumErrorBytes,
                environment: environment, timeout: timeout, standardOutputFile: standardOutputFile,
                trace: trace
            )
        } catch {
            trace.fail(error)
            throw error
        }
    }

    private func execute(
        arguments: [String], workingDirectory: URL, standardInput: Data?,
        maximumOutputBytes: Int?, maximumErrorBytes: Int?, environment: [String: String],
        timeout: Duration?, standardOutputFile: URL?, trace: GitCommandDiagnosticTrace
    ) async throws -> Data {
        if let timeout, timeout <= .zero {
            throw GitCommandTimeoutError(arguments: arguments)
        }
        // 大型清单直接写入调用方的临时文件；该模式成功时返回空 Data。
        let outputFileHandle: FileHandle?
        if let standardOutputFile {
            guard FileManager.default.createFile(
                atPath: standardOutputFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            outputFileHandle = try FileHandle(forWritingTo: standardOutputFile)
        } else {
            outputFileHandle = nil
        }
        defer { try? outputFileHandle?.close() }
        let stdoutCapture = ProcessPipeCapture(
            maximumStoredByteCount: maximumOutputBytes
        )
        let stderrCapture = ProcessPipeCapture(
            maximumStoredByteCount: maximumErrorBytes
        )
        if outputFileHandle == nil {
            stdoutCapture.start()
        } else {
            stdoutCapture.finish()
        }
        stderrCapture.start()
        let stdinPipe = standardInput.map { _ in Pipe() }
        let nullInputHandle = standardInput == nil
            ? try FileHandle(
                forReadingFrom: URL(fileURLWithPath: "/dev/null", isDirectory: false)
            )
            : nil
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let outputFileHandle {
            process.standardOutput = outputFileHandle
        } else {
            process.standardOutput = stdoutCapture.pipe
        }
        process.standardError = stderrCapture.pipe
        process.standardInput = stdinPipe ?? nullInputHandle
        var processEnvironment = Self.baseEnvironment
        processEnvironment.merge(environment) { _, configured in configured }
        // 配置只影响本次 Git 及其子进程，不改仓库或全局配置。Git 2.54 的 geometric
        // 自动维护不受 gc.auto=0 限制，且 detach 后不能靠父进程取消来结束维护。
        let inheritedParameters = processEnvironment["GIT_CONFIG_PARAMETERS"] ?? ""
        processEnvironment["GIT_CONFIG_PARAMETERS"] =
            (inheritedParameters.isEmpty ? "" : inheritedParameters + " ")
            + "'maintenance.auto=false' 'gc.auto=0'"
        // `--` 后是实际文件名。worktree 接受目录路径；stash 和 check-ignore 不使用此模式。
        if let separator = arguments.firstIndex(of: "--"),
           !arguments[..<separator].contains("worktree") {
            processEnvironment["GIT_LITERAL_PATHSPECS"] = "1"
        }
        process.environment = processEnvironment

        let handle = GitProcessHandle()
        let terminationWaiter = ProcessTerminationWaiter()
        process.terminationHandler = { _ in
            terminationWaiter.finish()
        }
        let inputTask: Task<Void, any Error>?
        do {
            try process.run()
            trace.fields["gitProcessID"] = String(process.processIdentifier)
            stdoutCapture.pipe.fileHandleForWriting.closeFile()
            stderrCapture.pipe.fileHandleForWriting.closeFile()
            stdinPipe?.fileHandleForReading.closeFile()
            nullInputHandle?.closeFile()
            _ = handle.adopt(process)
            if let standardInput, let stdinPipe {
                inputTask = Task.detached(priority: .userInitiated) {
                    defer {
                        stdinPipe.fileHandleForWriting.closeFile()
                    }
                    try stdinPipe.fileHandleForWriting.write(contentsOf: standardInput)
                }
            } else {
                inputTask = nil
            }
        } catch {
            stdoutCapture.pipe.fileHandleForWriting.closeFile()
            stderrCapture.pipe.fileHandleForWriting.closeFile()
            stdinPipe?.fileHandleForReading.closeFile()
            stdinPipe?.fileHandleForWriting.closeFile()
            nullInputHandle?.closeFile()
            process.terminationHandler = nil
            stdoutCapture.finish()
            stderrCapture.finish()
            throw error
        }

        let timeoutTask = timeout.map { timeout in
            Task.detached {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                handle.timeOut()
            }
        }

        await withTaskCancellationHandler {
            await terminationWaiter.value()
        } onCancel: {
            handle.cancel()
        }
        timeoutTask?.cancel()
        let terminationReason = handle.finish()
        let stdout: CapturedProcessOutput
        if let outputFileHandle {
            stdout = CapturedProcessOutput(
                data: Data(), byteCount: Int(clamping: try outputFileHandle.seekToEnd())
            )
        } else {
            stdout = await stdoutCapture.value()
        }
        let stderr = await stderrCapture.value()
        let inputResult = await inputTask?.result
        trace.fields["exitCode"] = String(process.terminationStatus)
        trace.fields["stdoutBytes"] = String(stdout.byteCount)
        trace.fields["stderrBytes"] = String(stderr.byteCount)
        trace.fields["stderrTruncated"] = String(stderr.byteCount > stderr.data.count)
        if !stderr.data.isEmpty {
            trace.fields["stderr"] = String(decoding: stderr.data, as: UTF8.self)
        }

        // 被终止的 git 退出码非 0，先报取消，避免上层把它当成 git 失败弹错误。
        try Task.checkCancellation()
        if terminationReason == .timedOut {
            throw GitCommandTimeoutError(arguments: arguments)
        }
        guard process.terminationStatus == 0 else {
            var errorText = String(decoding: stderr.data, as: UTF8.self)
            if let maximumErrorBytes,
               stderr.byteCount > maximumErrorBytes {
                errorText += "\n[Git error output truncated after "
                    + "\(maximumErrorBytes) of \(stderr.byteCount) bytes.]"
            }
            throw GitCommandFailure(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: errorText
            )
        }
        if case let .failure(error) = inputResult {
            throw error
        }
        if let maximumOutputBytes,
           stdout.byteCount > maximumOutputBytes {
            throw GitCommandOutputLimitError(
                limit: maximumOutputBytes,
                actualByteCount: stdout.byteCount
            )
        }
        trace.fields["status"] = "success"
        return stdout.data
    }
}
