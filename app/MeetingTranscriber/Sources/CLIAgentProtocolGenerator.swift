#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CLIAgentProtocolGenerator")

    /// Generic CLI-agent protocol generator.
    ///
    /// Runs an arbitrary command (e.g. `opencode run -`, `pi -p -`), pipes the
    /// system prompt + transcript to its stdin, and treats its stdout as the
    /// finished Markdown protocol. Unlike `ClaudeCLIProtocolGenerator` it does
    /// not parse stream-JSON — plain stdout is the contract, which works for any
    /// agent that prints its answer. The command must include whatever flag
    /// makes the CLI read the prompt from stdin.
    ///
    /// Homebrew build only — `Process()` is sandbox-forbidden in the App Store
    /// variant.
    struct CLIAgentProtocolGenerator: ProtocolGenerating {
        /// The command template, e.g. `"opencode run -"`. Tokenized on launch.
        let command: String
        let language: String
        let promptFileURL: URL

        static let timeoutSeconds: TimeInterval = 600

        init(command: String, language: String, promptFileURL: URL = AppPaths.customPromptFile) {
            self.command = command
            self.language = language
            self.promptFileURL = promptFileURL
        }

        /// Search paths for CLI-agent binaries. App bundles inherit a minimal
        /// PATH, so bare command names are resolved against these locations
        /// (absolute paths in the command bypass the search entirely).
        static let searchPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.bun/bin",
        ]

        // MARK: - ProtocolGenerating

        func generate(transcript: String, title _: String, diarized: Bool) async throws -> String {
            try await generate(transcript: transcript, title: "", diarized: diarized, participants: nil)
        }

        func generate(transcript: String, title _: String, diarized: Bool, participants: [String]?) async throws -> String {
            let prompt = ProtocolGenerator.buildSystemPrompt(diarized: diarized, language: language, participants: participants, promptFileURL: promptFileURL) + transcript

            let tokens = Self.tokenize(command)
            guard let bin = tokens.first else {
                logger.error("cli_agent_empty_command")
                throw ProtocolError.cliNotFound(command)
            }
            let resolvedBin = Self.resolveBinary(bin)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = Self.buildArgs(
                bin: bin, resolvedBin: resolvedBin, extraArgs: Array(tokens.dropFirst()),
            )
            process.environment = Self.buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                searchPaths: Self.searchPaths,
            )

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Set terminationHandler BEFORE process.run() to avoid a race where
            // the process exits before the handler is installed. AsyncStream
            // buffers the yield, so an early exit is never lost.
            let exitStream = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield()
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                logger.error(
                    "cli_agent_not_found bin=\(bin, privacy: .public) resolvedPath=\(resolvedBin, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(bin)
            }

            // Write stdin in a detached task to avoid deadlock on large
            // transcripts: the pipe buffer is finite (~64 KB) and a synchronous
            // write would block until we start reading. Use the throwing
            // `write(contentsOf:)` — the deprecated `write(_:)` raises an
            // uncatchable NSException on EPIPE (e.g. when the timeout path
            // terminates the child), aborting the whole app.
            let promptData = Data(prompt.utf8)
            logger.info("cli_agent_subprocess_start prompt_bytes=\(promptData.count, privacy: .public)")
            let stdinWriteTask = Task.detached {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
                } catch {
                    logger.debug(
                        "cli_agent_stdin_write_failed error=\(error.localizedDescription, privacy: .public)",
                    )
                }
                try? stdinPipe.fileHandleForWriting.close()
            }

            // Read stdout concurrently with the stdin write.
            let text = try await Self.readAllText(from: stdoutPipe, process: process)

            _ = await stdinWriteTask.value

            // Read stderr in the background to prevent pipe-buffer stalls.
            async let stderrRead = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }.value

            for await _ in exitStream {
                break
            }

            if process.terminationStatus != 0 {
                let stderrData = await stderrRead
                let stderrText = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logger.error(
                    "cli_agent_failed exit=\(process.terminationStatus, privacy: .public) stderr=\(stderrText, privacy: .public)",
                )
                throw Self.makeFailureError(exitCode: process.terminationStatus, stderrText: stderrText)
            }

            return try Self.validateGeneratedText(text)
        }

        // MARK: - stdout read

        /// Accumulate the child's stdout to EOF and decode it as UTF-8.
        /// Enforces `timeoutSeconds` between reads; terminates the process and
        /// throws `.timeout` if the agent runs too long.
        private static func readAllText(from pipe: Pipe, process: Process) async throws -> String {
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            let startTime = ProcessInfo.processInfo.systemUptime

            while true {
                if ProcessInfo.processInfo.systemUptime - startTime > timeoutSeconds {
                    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                    let elapsedStr = String(format: "%.1f", elapsed)
                    logger.error(
                        "cli_agent_timeout elapsed=\(elapsedStr, privacy: .public)s bytes_received=\(buffer.count, privacy: .public)",
                    )
                    process.terminate()
                    throw ProtocolError.timeout
                }

                // Wrap blocking availableData in Task.detached so it doesn't
                // starve Swift's cooperative thread pool.
                let chunk = await Task.detached { handle.availableData }.value
                if chunk.isEmpty { break } // EOF
                buffer.append(chunk)
            }

            return String(data: buffer, encoding: .utf8) ?? ""
        }

        // MARK: - Pure helpers

        /// Split a command template into an argument vector, honouring single
        /// and double quotes (so `--flag "a b"` stays one token). Quotes only
        /// govern whether whitespace is literal — they don't introduce token
        /// boundaries, so adjacent quoted/bare segments join. No escape
        /// handling (YAGNI for meeting-summary CLIs).
        static func tokenize(_ command: String) -> [String] {
            var tokens: [String] = []
            var current = ""
            var inToken = false
            var quote: Character?

            for ch in command {
                if let q = quote {
                    if ch == q { quote = nil } else { current.append(ch) }
                    continue
                }
                if ch == "\"" || ch == "'" {
                    quote = ch
                    inToken = true
                    continue
                }
                if ch.isWhitespace {
                    if inToken {
                        tokens.append(current)
                        current = ""
                        inToken = false
                    }
                    continue
                }
                current.append(ch)
                inToken = true
            }
            if inToken { tokens.append(current) }
            return tokens
        }

        /// Resolve a command's leading token to an executable path. Absolute
        /// paths pass through untouched; bare names are looked up in
        /// `searchPaths`; unresolved names fall back to the `/usr/bin/env` shim
        /// so the launch can still be attempted via PATH.
        static func resolveBinary(_ bin: String) -> String {
            if bin.hasPrefix("/") { return bin }
            for path in searchPaths.map({ "\($0)/\(bin)" })
                where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            return "/usr/bin/env"
        }

        /// Build the argument vector. When `resolvedBin` is the `/usr/bin/env`
        /// fallback, prepend the bare `bin` so env can resolve it from PATH.
        static func buildArgs(bin: String, resolvedBin: String, extraArgs: [String]) -> [String] {
            var args = extraArgs
            if resolvedBin == "/usr/bin/env" {
                args.insert(bin, at: 0)
            }
            return args
        }

        /// Prepend `searchPaths` to `PATH` (app bundles inherit a minimal PATH).
        /// Unlike the Claude generator, the generic path makes no CLI-specific
        /// assumptions — it does not strip `CLAUDECODE` or any other key.
        static func buildEnvironment(
            baseEnvironment: [String: String],
            searchPaths: [String],
        ) -> [String: String] {
            var env = baseEnvironment
            let basePath = env["PATH"] ?? "/usr/bin:/bin"
            if searchPaths.isEmpty {
                env["PATH"] = basePath
            } else {
                env["PATH"] = "\(searchPaths.joined(separator: ":")):\(basePath)"
            }
            return env
        }

        /// Trim whitespace from CLI output. Throws `.emptyProtocol` when the
        /// subprocess exited successfully but produced no usable text.
        static func validateGeneratedText(_ text: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProtocolError.emptyProtocol }
            return trimmed
        }

        /// Pair an already-decoded stderr string with `exitCode` as a
        /// `ProtocolError.cliFailed`.
        static func makeFailureError(exitCode: Int32, stderrText: String) -> ProtocolError {
            .cliFailed(Int(exitCode), stderrText)
        }
    }

#endif
