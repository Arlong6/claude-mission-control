import Foundation

/// Wraps `claude` CLI as a one-shot subprocess per user prompt.
/// stdout is streamed back via the `onChunk` callback (called on a background queue).
final class ClaudeBackend {
    static let shared = ClaudeBackend()

    private(set) var current: Process?

    private static let claudePath: String = {
        // Try common locations; fall back to /usr/bin/env
        let candidates = ["/Users/arlong/.local/bin/claude",
                          "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "claude"
    }()

    // Default to `acceptEdits`: auto-approves file edits but still gates Bash and
    // other risky tools. Set MISSION_CONTROL_BYPASS_PERMISSIONS=1 to restore the
    // old "approve everything" behavior for power use.
    private static let permissionMode: String = {
        if ProcessInfo.processInfo.environment["MISSION_CONTROL_BYPASS_PERMISSIONS"] == "1" {
            return "bypassPermissions"
        }
        return "acceptEdits"
    }()

    func send(prompt: String,
              cwd: String,
              sessionId: String?,
              attachments: [URL] = [],
              onChunk: @escaping (String) -> Void,
              onError: @escaping (String) -> Void,
              onFinish: @escaping (String, String, Int32) -> Void) {
        cancel()
        // Accumulate buffers inside the backend so onFinish always has complete text,
        // regardless of MainActor hop timing.
        let stdoutBuf = NSMutableString()
        let stderrBuf = NSMutableString()
        let bufLock = NSLock()

        let p = Process()
        // Use /usr/bin/env so PATH lookup works if absolute path missing
        if FileManager.default.isExecutableFile(atPath: Self.claudePath) {
            p.executableURL = URL(fileURLWithPath: Self.claudePath)
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        }

        var args: [String] = []
        if p.executableURL?.path == "/usr/bin/env" { args.append("claude") }
        args.append(contentsOf: [
            "--print",
            "--permission-mode", Self.permissionMode,
            "--output-format", "text"
        ])
        // Grant Claude read access to each attachment's parent dir (deduplicated)
        // so its Read tool can pick up pasted images sitting outside cwd.
        var seenDirs = Set<String>()
        for url in attachments {
            let dir = url.deletingLastPathComponent().path
            if seenDirs.insert(dir).inserted {
                args.append(contentsOf: ["--add-dir", dir])
            }
        }
        if let sid = sessionId, !sid.isEmpty {
            args.append(contentsOf: ["--resume", sid])
        }
        // Reference attachments inline in the prompt so Claude knows to Read them.
        let finalPrompt: String
        if attachments.isEmpty {
            finalPrompt = prompt
        } else {
            let lines = attachments.map { "[attached image: \($0.path)]" }.joined(separator: "\n")
            finalPrompt = lines + "\n\n" + prompt
        }
        args.append(finalPrompt)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        // make sure PATH covers common locations
        let extra = "/Users/arlong/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\(extra):\($0)" }) ?? extra
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                bufLock.lock(); stdoutBuf.append(s); bufLock.unlock()
                onChunk(s)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                bufLock.lock(); stderrBuf.append(s); bufLock.unlock()
                onError(s)
            }
        }

        p.terminationHandler = { proc in
            // Drain any remaining buffered data before completing.
            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingOut.isEmpty, let s = String(data: remainingOut, encoding: .utf8) {
                bufLock.lock(); stdoutBuf.append(s); bufLock.unlock()
            }
            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingErr.isEmpty, let s = String(data: remainingErr, encoding: .utf8) {
                bufLock.lock(); stderrBuf.append(s); bufLock.unlock()
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            bufLock.lock()
            let outStr = stdoutBuf as String
            let errStr = stderrBuf as String
            bufLock.unlock()
            onFinish(outStr, errStr, proc.terminationStatus)
        }

        do {
            try p.run()
            current = p
        } catch {
            onError("failed to launch claude: \(error.localizedDescription)")
            onFinish("", "failed to launch claude: \(error.localizedDescription)", -1)
        }
    }

    func cancel() {
        if let p = current, p.isRunning {
            p.terminate()
        }
        current = nil
    }
}
