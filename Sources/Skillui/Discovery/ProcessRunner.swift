import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    var combinedString: String {
        [stdoutString, stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Thread-safe coordinator so a cancelled awaiting Task can SIGKILL the child it spawned.
/// `withCheckedContinuation` does not observe `Task.isCancelled`, so without this a cancelled
/// scan/refresh (e.g. `refreshTask?.cancel()` on a settings change) would leave `npx`/`skills`
/// running until it exits naturally or the watchdog fires (≤120s). The `finished` flag stops us
/// from signalling a reaped — possibly recycled — pid.
private final class ProcessKillBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var finished = false

    /// Record the launched child's pid. Returns true if the Task was ALREADY cancelled before the
    /// child launched (the caller should kill it immediately).
    func registerLaunched(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid
        return cancelled && !finished
    }

    /// The process exited and was reaped — stop tracking so cancel() never signals a recycled pid.
    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    /// Task cancelled: SIGKILL the still-running child, if one is tracked.
    func cancel() {
        lock.lock()
        let target = finished ? nil : pid
        cancelled = true
        lock.unlock()
        if let target { kill(target, SIGKILL) }
    }
}

enum ProcessRunner {
    /// Run a process off the main thread.
    ///
    /// Uses a single pipe drained on the worker thread *as output is produced*, which
    /// sidesteps the classic 64KB pipe-buffer deadlock. When `dropStderr` is true,
    /// stderr is discarded (use for `--json` where CLI progress spinners would pollute
    /// the stream); otherwise stderr is merged into stdout for a combined transcript.
    static func run(launchPath: String,
                    args: [String],
                    cwd: String? = nil,
                    extraEnv: [String: String] = [:],
                    dropStderr: Bool = false,
                    timeoutSeconds: Double = 120) async -> ProcessResult {
        let killBox = ProcessKillBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: launchPath)
                    p.arguments = args
                    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                    var env = ProcessInfo.processInfo.environment
                    for (k, v) in extraEnv { env[k] = v }
                    p.environment = env

                    let outPipe = Pipe()
                    p.standardOutput = outPipe
                    p.standardInput = FileHandle.nullDevice
                    p.standardError = dropStderr ? FileHandle.nullDevice : outPipe

                    do {
                        try p.run()
                    } catch {
                        let msg = "Failed to launch \(launchPath): \(error.localizedDescription)"
                        cont.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: Data(msg.utf8)))
                        return
                    }
                    // Watchdog: kill a hung process (e.g. `npx` stuck on network) so the awaiting
                    // Task can never suspend forever. Captures only the pid (Sendable), not Process.
                    let pid = p.processIdentifier
                    if killBox.registerLaunched(pid: pid) { kill(pid, SIGKILL) }
                    let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    watchdog.cancel()
                    killBox.finish()
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: data, stderr: Data()))
                }
            }
        } onCancel: {
            killBox.cancel()
        }
    }

    /// Same execution model as `run`, but reports combined stdout/stderr chunks as soon as the
    /// process writes them. Used for user-visible update/install transcripts.
    static func runStreaming(launchPath: String,
                             args: [String],
                             cwd: String? = nil,
                             extraEnv: [String: String] = [:],
                             timeoutSeconds: Double = 120,
                             onOutput: @escaping @Sendable (String) -> Void) async -> ProcessResult {
        let killBox = ProcessKillBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: launchPath)
                    p.arguments = args
                    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                    var env = ProcessInfo.processInfo.environment
                    for (k, v) in extraEnv { env[k] = v }
                    p.environment = env

                    let outPipe = Pipe()
                    p.standardOutput = outPipe
                    p.standardError = outPipe
                    p.standardInput = FileHandle.nullDevice

                    do {
                        try p.run()
                    } catch {
                        let msg = "Failed to launch \(launchPath): \(error.localizedDescription)"
                        onOutput(msg)
                        cont.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: Data(msg.utf8)))
                        return
                    }

                    let pid = p.processIdentifier
                    if killBox.registerLaunched(pid: pid) { kill(pid, SIGKILL) }
                    let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                    var output = Data()
                    while true {
                        let chunk = outPipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        output.append(chunk)
                        onOutput(String(decoding: chunk, as: UTF8.self))
                    }
                    p.waitUntilExit()
                    watchdog.cancel()
                    killBox.finish()
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: output, stderr: Data()))
                }
            }
        } onCancel: {
            killBox.cancel()
        }
    }
}
