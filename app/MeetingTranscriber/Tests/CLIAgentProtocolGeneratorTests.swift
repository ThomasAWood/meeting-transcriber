#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class CLIAgentProtocolGeneratorTests: XCTestCase {
        // MARK: - tokenize

        func testTokenizeEmptyStringReturnsNothing() {
            XCTAssertEqual(CLIAgentProtocolGenerator.tokenize(""), [])
        }

        func testTokenizeWhitespaceOnlyReturnsNothing() {
            XCTAssertEqual(CLIAgentProtocolGenerator.tokenize("   \t "), [])
        }

        func testTokenizeSimpleCommandSplitsOnWhitespace() {
            XCTAssertEqual(
                CLIAgentProtocolGenerator.tokenize("opencode run -"),
                ["opencode", "run", "-"],
            )
        }

        func testTokenizeCollapsesRepeatedAndSurroundingWhitespace() {
            XCTAssertEqual(
                CLIAgentProtocolGenerator.tokenize("  pi   -p  -  "),
                ["pi", "-p", "-"],
            )
        }

        func testTokenizeHonorsDoubleQuotedArgumentWithSpaces() {
            XCTAssertEqual(
                CLIAgentProtocolGenerator.tokenize(#"mycli --flag "a b""#),
                ["mycli", "--flag", "a b"],
            )
        }

        func testTokenizeHonorsSingleQuotedArgumentWithSpaces() {
            XCTAssertEqual(
                CLIAgentProtocolGenerator.tokenize("mycli --flag 'a b'"),
                ["mycli", "--flag", "a b"],
            )
        }

        func testTokenizeConcatenatesAdjacentQuotedAndBareSegments() {
            // Shell-like: quotes only govern whether whitespace is literal, they
            // don't introduce token boundaries. Adjacent segments join.
            XCTAssertEqual(
                CLIAgentProtocolGenerator.tokenize(#""a"b"#),
                ["ab"],
            )
        }

        // MARK: - resolveBinary

        func testResolveBinaryAbsolutePathReturnsAsIs() {
            // Absolute paths are trusted verbatim — even if the file doesn't
            // exist, that's the caller's problem; the resolver doesn't probe.
            XCTAssertEqual(
                CLIAgentProtocolGenerator.resolveBinary("/totally/fake/opencode"),
                "/totally/fake/opencode",
            )
        }

        func testResolveBinaryFallsBackToEnvForUnknownBareName() {
            // A bare name not present in any search path falls through to the
            // /usr/bin/env shim so the launch can still be attempted via PATH.
            let unique = "opencode-does-not-exist-\(UUID().uuidString)"
            XCTAssertEqual(
                CLIAgentProtocolGenerator.resolveBinary(unique),
                "/usr/bin/env",
            )
        }

        // MARK: - buildArgs

        func testBuildArgsForResolvedAbsolutePathDoesNotPrependBinary() {
            let args = CLIAgentProtocolGenerator.buildArgs(
                bin: "opencode",
                resolvedBin: "/opt/homebrew/bin/opencode",
                extraArgs: ["run", "-"],
            )
            XCTAssertEqual(args, ["run", "-"])
        }

        func testBuildArgsForEnvFallbackPrependsBinaryName() {
            // /usr/bin/env fallback: the bare name is prepended so env can
            // resolve it via PATH (set in buildEnvironment).
            let args = CLIAgentProtocolGenerator.buildArgs(
                bin: "opencode",
                resolvedBin: "/usr/bin/env",
                extraArgs: ["run", "-"],
            )
            XCTAssertEqual(args, ["opencode", "run", "-"])
        }

        // MARK: - searchPaths

        func testSearchPathsContainExpectedDirectories() {
            // Lock in the search-path list; changing it (e.g. adding a new
            // location) is intentional and should be reviewed alongside the
            // test update.
            let paths = CLIAgentProtocolGenerator.searchPaths
            XCTAssertTrue(paths.contains("/usr/local/bin"))
            XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
            XCTAssertTrue(paths.contains("\(NSHomeDirectory())/.local/bin"))
        }

        // MARK: - buildEnvironment

        func testBuildEnvironmentPrependsSearchPathsToPATH() {
            let env = CLIAgentProtocolGenerator.buildEnvironment(
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                searchPaths: ["/opt/homebrew/bin", "/Users/x/.local/bin"],
            )
            XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/Users/x/.local/bin:/usr/bin:/bin")
        }

        func testBuildEnvironmentFallsBackToSystemPathWhenNoPATHInBase() {
            let env = CLIAgentProtocolGenerator.buildEnvironment(
                baseEnvironment: [:],
                searchPaths: ["/opt/homebrew/bin"],
            )
            XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        }

        func testBuildEnvironmentPreservesOtherKeysIncludingClaudeCode() {
            // Unlike the Claude generator, the generic path does NOT strip
            // CLAUDECODE — it makes no assumptions about which CLI it runs.
            let env = CLIAgentProtocolGenerator.buildEnvironment(
                baseEnvironment: ["HOME": "/Users/x", "CLAUDECODE": "1", "PATH": "/usr/bin"],
                searchPaths: [],
            )
            XCTAssertEqual(env["HOME"], "/Users/x")
            XCTAssertEqual(env["CLAUDECODE"], "1")
        }

        // MARK: - validateGeneratedText

        func testValidateGeneratedTextReturnsTrimmed() throws {
            let result = try CLIAgentProtocolGenerator.validateGeneratedText("  Hello world  \n")
            XCTAssertEqual(result, "Hello world")
        }

        func testValidateGeneratedTextWhitespaceOnlyThrowsEmptyProtocol() {
            XCTAssertThrowsError(try CLIAgentProtocolGenerator.validateGeneratedText("   \n\t  ")) { error in
                guard case ProtocolError.emptyProtocol = error else {
                    XCTFail("Expected .emptyProtocol, got \(error)")
                    return
                }
            }
        }

        // MARK: - makeFailureError

        func testMakeFailureErrorWrapsExitCodeAndStderr() {
            let err = CLIAgentProtocolGenerator.makeFailureError(
                exitCode: 2,
                stderrText: "command not found",
            )
            guard case let .cliFailed(code, stderr) = err else {
                XCTFail("Expected .cliFailed, got \(err)")
                return
            }
            XCTAssertEqual(code, 2)
            XCTAssertEqual(stderr, "command not found")
        }

        // MARK: - generate (subprocess integration)

        /// Drives the full `generate()` path against a fake CLI that reads the
        /// piped prompt and confirms a marker embedded in the transcript
        /// arrived on stdin — proving the detached stdin write reaches the
        /// child — then prints its plain-text protocol on stdout.
        func testGenerateFeedsPromptToStdinAndReturnsPlainStdout() async throws {
            let script = try Self.makeFakeAgentScript(
                body: """
                if grep -q 'MARKER-4711'; then printf 'Protocol body'; else printf 'no marker'; fi
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = CLIAgentProtocolGenerator(command: script, language: "German")
            let result = try await generator.generate(
                transcript: "Speaker 1: hello MARKER-4711", title: "Sync", diarized: false,
            )
            XCTAssertEqual(result, "Protocol body")
        }

        /// The extra tokens in the command template must be forwarded to the
        /// child as argv (here echoed back via `$1`).
        func testGeneratePassesExtraArgsFromCommandTemplate() async throws {
            let script = try Self.makeFakeAgentScript(
                body: """
                cat > /dev/null
                printf '%s' "$1"
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = CLIAgentProtocolGenerator(command: "\(script) FromArgs", language: "German")
            let result = try await generator.generate(
                transcript: "irrelevant", title: "Sync", diarized: false,
            )
            XCTAssertEqual(result, "FromArgs")
        }

        /// A non-zero exit surfaces as `.cliFailed` carrying the code + stderr.
        func testGenerateNonZeroExitThrowsCliFailed() async throws {
            let script = try Self.makeFakeAgentScript(
                body: """
                cat > /dev/null
                printf 'boom' >&2
                exit 3
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = CLIAgentProtocolGenerator(command: script, language: "German")
            do {
                _ = try await generator.generate(transcript: "x", title: "Sync", diarized: false)
                XCTFail("Expected .cliFailed to be thrown")
            } catch let ProtocolError.cliFailed(code, stderr) {
                XCTAssertEqual(code, 3)
                XCTAssertEqual(stderr, "boom")
            }
        }

        /// A clean exit with no stdout is an empty protocol, not a success.
        func testGenerateEmptyStdoutThrowsEmptyProtocol() async throws {
            let script = try Self.makeFakeAgentScript(
                body: """
                cat > /dev/null
                exit 0
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = CLIAgentProtocolGenerator(command: script, language: "German")
            do {
                _ = try await generator.generate(transcript: "x", title: "Sync", diarized: false)
                XCTFail("Expected .emptyProtocol to be thrown")
            } catch ProtocolError.emptyProtocol {
                // expected
            }
        }

        /// Writes a temporary executable `#!/bin/sh` script wrapping `body` and
        /// returns its absolute path. Caller deletes it.
        private static func makeFakeAgentScript(body: String) throws -> String {
            let path = NSTemporaryDirectory() + "cli-agent-\(UUID().uuidString).sh"
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path,
            )
            return path
        }
    }
#endif
