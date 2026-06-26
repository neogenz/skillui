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
                    dropStderr: Bool = false) async -> ProcessResult {
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
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: data, stderr: Data()))
            }
        }
    }
}
