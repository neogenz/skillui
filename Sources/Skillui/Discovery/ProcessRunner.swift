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
                let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                watchdog.cancel()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: data, stderr: Data()))
            }
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
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: output, stderr: Data()))
            }
        }
    }
}
