import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool) async throws -> String
    func generate(transcript: String, title: String, diarized: Bool, participants: [String]?) async throws -> String
}

/// Shared protocol utilities: prompts, file operations, and error types.
enum ProtocolGenerator {
    static let protocolPrompt = """
    You are a professional meeting minute taker.
    Create a structured meeting protocol in {LANGUAGE} from the following transcript.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # Meeting Protocol - [Meeting Title]
    **Date:** [Date from context or today]

    ---

    ## Summary
    [3-5 sentence summary of the meeting]

    ## Participants
    - [Name 1]
    - [Name 2]

    ## Topics Discussed

    ### [Topic 1]
    [What was discussed]

    ### [Topic 2]
    [What was discussed]

    ## Decisions
    - [Decision 1]
    - [Decision 2]

    ## Tasks
    | Task | Responsible | Deadline | Priority |
    |------|-------------|----------|----------|
    | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

    ## Open Questions
    - [Question 1]
    - [Question 2]

    Do NOT include the full transcript in the output – it will be appended automatically.

    ---
    Transcript:
    """

    static let diarizationNote = """
    \nNote: The transcript contains speaker labels in brackets. \
    Possible label formats:
    - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
    - [Me], [Roman] etc. — the local microphone user
    - [Remote] — remote participant(s) without diarization
    - [Name] — a recognized or named speaker
    Use these labels to identify participants. \
    In the Participants section, list them by name where possible. \
    In the Topics Discussed section, attribute key statements to speakers.
    """

    /// Load the protocol prompt, preferring a custom file over the built-in default.
    ///
    /// Reads `AppPaths.customPromptFile` if it exists and is non-empty,
    /// otherwise falls back to the hardcoded `protocolPrompt`.
    static func applyLanguage(_ prompt: String, language: String) -> String {
        prompt.replacingOccurrences(of: "{LANGUAGE}", with: language)
    }

    /// Load the protocol generation prompt. Reads from `url` when present and non-empty;
    /// falls back to the built-in `protocolPrompt`. The `url` parameter exists so
    /// tests can use unique per-test paths instead of racing on the shared one.
    static func loadPrompt(from url: URL = AppPaths.customPromptFile) -> String {
        if let custom = try? String(contentsOf: url, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("Using custom protocol prompt from \(url.path)")
            return custom
        }
        return protocolPrompt
    }

    /// Build the localized system prompt: `loadPrompt` + `applyLanguage`
    /// + optional `diarizationNote`. Excludes the transcript itself —
    /// callers append or attach it as they see fit.
    static func buildSystemPrompt(diarized: Bool, language: String) -> String {
        buildSystemPrompt(diarized: diarized, language: language, participants: nil)
    }

    /// Build the localized system prompt with optional speaker list substitution.
    /// - Parameters:
    ///   - diarized: Whether diarization labels are present (adds the diarization note)
    ///   - language: Target language for `{LANGUAGE}` substitution
    ///   - participants: Optional list of participant names for `{SPEAKERS}` substitution
    ///   - promptFileURL: URL to read the prompt template from (default: built-in location)
    /// - Returns: The fully substituted system prompt
    static func buildSystemPrompt(
        diarized: Bool,
        language: String,
        participants: [String]?,
        promptFileURL: URL = AppPaths.customPromptFile,
    ) -> String {
        var prompt = applyLanguage(loadPrompt(from: promptFileURL), language: language)
        if let participants, !participants.isEmpty {
            let speakersList = participants.map { "- \($0)" }.joined(separator: "\n")
            prompt = prompt.replacingOccurrences(of: "{SPEAKERS}", with: speakersList)
        }
        if diarized { prompt += diarizationNote }
        return prompt
    }

    // MARK: - File Operations

    /// Save a transcript to a Markdown file.
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, title: String, dir: URL) throws -> URL {
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(title: title, ext: "md"))
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Transcripts contain verbatim meeting speech — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Transcript saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    /// Save a protocol to a Markdown file.
    ///
    /// - Returns: URL of the saved file
    static func saveProtocol(_ markdown: String, title: String, dir: URL) throws -> URL {
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(title: title, ext: "md"))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        // Protocol markdown summarises the meeting — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Protocol saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    private static let filenameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return fmt
    }()

    /// Characters kept verbatim in a slug; everything else becomes a separator.
    private static let slugAllowed = CharacterSet.alphanumerics

    /// Sanitize a title into a safe filename slug (path-traversal safe):
    /// lowercased, every run of non-alphanumeric characters collapsed to a
    /// single `-`, and leading/trailing dashes trimmed. Returns `""` when no
    /// usable characters remain — `filename` then omits the slug entirely
    /// rather than substituting a placeholder.
    static func sanitizeSlug(_ title: String) -> String {
        let normalized = stripExistingTimestampPrefix(title).lowercased()
        var slug = ""
        var pendingSeparator = false
        for scalar in normalized.unicodeScalars {
            if slugAllowed.contains(scalar) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return slug
    }

    /// Re-importing a previously-processed recording feeds its slug-based stem
    /// back as a title (e.g. `2026-05-16-1319-2026-05-03-1745`). `filename`
    /// would then prepend ANOTHER timestamp → compounding-prefix loop on every
    /// reprocess. Strip a leading timestamp so the slug stays idempotent. Three
    /// forms are recognised: the current note format `yyyy-MM-dd-HHmm-`, the
    /// recorder's native `yyyyMMdd_HHmmss_`, and the legacy note format
    /// `yyyyMMdd_HHmm_` (older on-disk files).
    static func stripExistingTimestampPrefix(_ title: String) -> String {
        let patterns = [
            #"^\d{4}-\d{2}-\d{2}-\d{4}-"#,
            #"^\d{8}_\d{6}_"#,
            #"^\d{8}_\d{4}_"#,
        ]
        var result = title
        // Apply repeatedly — input may already contain multiple compounded layers
        // from earlier buggy runs; one call should normalize the worst case.
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = result.range(of: pattern, options: .regularExpression) {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        return result.isEmpty ? title : result
    }

    /// Generate a filename: `{yyyy-MM-dd-HHmm}-{slug}.{ext}`, or
    /// `{yyyy-MM-dd-HHmm}.{ext}` when the title yields no slug.
    static func filename(title: String, ext: String) -> String {
        let date = filenameFormatter.string(from: Date())
        let slug = sanitizeSlug(title)
        let base = slug.isEmpty ? date : "\(date)-\(slug)"
        return "\(base).\(ext)"
    }

    /// Extract unique participant names from a diarized transcript.
    /// Returns a sorted list of names, filtering out generic labels like
    /// [Remote], [Me], and [SPEAKER_XX]. Returns nil if no meaningful
    /// names are found (e.g., transcript is not diarized).
    static func extractParticipants(from transcript: String) -> [String]? {
        let pattern = #"\[([\w\s]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let genericLabels = Set(["Remote", "Me", "Unknown"])
        var participants = Set<String>()
        let fullRange = NSRange(transcript.startIndex..., in: transcript)

        regex.enumerateMatches(in: transcript, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: transcript) else { return }
            let name = String(transcript[range]).trimmingCharacters(in: .whitespaces)
            // Filter out generic labels and numeric auto-speaker IDs
            guard !genericLabels.contains(name),
                  !name.hasPrefix("SPEAKER_") else { return }
            participants.insert(name)
        }

        return participants.isEmpty ? nil : participants.sorted()
    }
}

enum ProtocolError: LocalizedError {
    #if !APPSTORE
        case cliNotFound(String)
        case cliFailed(Int, String)
        case timeout
    #endif
    case emptyProtocol
    case httpError(Int, String)
    case connectionFailed(String)
    case generationTimedOut(Int)
    case protocolTruncated

    var errorDescription: String? {
        switch self {
        #if !APPSTORE
            case let .cliNotFound(bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"

            case let .cliFailed(code, stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"

            case .timeout: "Claude CLI took too long (>10 min)"
        #endif

        case .emptyProtocol: "Protocol is empty. Tip: Test manually: echo Hello | claude --print"

        case let .httpError(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"

        case let .connectionFailed(reason): "Connection failed: \(reason)"

        case let .generationTimedOut(seconds): "Protocol generation timed out after \(seconds)s. The LLM endpoint is stuck or too slow — try a smaller model or shorter context."

        case .protocolTruncated: "Protocol was cut off before finishing (model hit its output/context limit). Raise the limit or shorten the transcript."
        }
    }
}
