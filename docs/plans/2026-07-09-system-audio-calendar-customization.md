# System-Audio + Calendar Customization Plan

> Personal customization plan for re-targeting Meeting Transcriber to a
> calendar-driven, system-audio-capturing workflow (Google Meet, Slack
> huddles, any app). Lives in `.local/` — not committed reference material.
> Promote to `docs/plans/` if it becomes shared.

## Goal

Repurpose the existing Meeting Transcriber app to fit this workflow:

1. **Google Meet support** — Meet runs in a browser; the app must capture it.
2. **Calendar-driven auto-start** — recordings start automatically from a
   calendar event (Google Calendar via Apple Calendar sync, or local Apple
   calendars). **User must be able to choose which local calendars do/don't
   trigger recordings.**
3. **Markdown transcripts to a chosen folder** — already supported (see below).
4. **Custom CLI agents for summaries** — Pi, Claude, OpenCode in addition to
   the built-in Claude CLI path.
5. **No Screen Recording permission.** Triggers are calendar (B) + power
   assertions (E/PowerAssertionDetector) — neither needs SR, and audio capture
   (CATapDescription) never did. Drop the SR permission and every code path
   that touches it (window-title lookup, health check, settings row, plist
   string). See feature **F**.

Stretch / future: auto-transcribe **Slack huddles** that aren't on the calendar.

## Key Architectural Insight (the unifying idea)

The recorder is already **dual-track**, and the two tracks are captured
*independently*:

- **App track** → `CATapDescription` (currently scoped to a specific PID/process
  tree).
- **Mic track** → `AVAudioEngine` (`MicCaptureHandler`), always separate.

**Diarization depends on this *split*, not on knowing the specific app.**
The pipeline prefixes `R_` (remote/app audio) vs `M_` (mic/local). If the "app
track" captures *all system output* instead of one process, diarization keeps
working unchanged: system audio = everyone-but-you, mic = you.

➡️ **Therefore:** switch the app track to **system-wide output capture**. This:

- Eliminates the PID problem entirely (the calendar detector doesn't need to
  know *which* process to capture).
- Makes every app work for free (Meet, Slack huddles, Zoom, Teams, Discord,
  any WebRTC in any browser) — no per-app detection logic.
- Lets us delete/supersede much of the per-app machinery
  (`MeetingDetector` window-title regexes, `PowerAssertionDetector` patterns,
  `ProcessTreeEnumerator`, PID translation) if we go calendar-first.

**The detection *trigger* remains the open question.** System-wide capture
answers "what to capture"; we still need "when to start" (calendar event,
manual, or a fallback detector).

## Current State (what already works — no work needed)

- **Markdown to a folder:** `ProtocolGenerator.saveProtocol()` writes `.md`;
  output folder configurable in Settings → Output (`AppSettings.effectiveOutputDir`).
  Transcript-only mode = set protocol provider to `.none`.
- **Claude CLI summaries:** `ClaudeCLIProtocolGenerator` spawns `claude`,
  pipes transcript to stdin, reads stream-JSON from stdout. (Homebrew build only
  — `Process()` is sandbox-forbidden in the App Store variant.)
- **Manual recording of any app:** `AppPickerView` + `startManualRecording()`
  already records Chrome/any PID. Works for Google Meet *today*.
- **Dual-track diarization** (`assignSpeakersDualTrack`, `R_`/`M_` prefixes).
- **Electron process-tree support** in AudioTapLib (`ProcessTreeEnumerator`)
  — explicitly mentioned for Teams/Slack/Discord.

## Relevant Files (where the changes go)

| Concern | File(s) |
|---|---|
| CATap creation (process-specific today) | `tools/audiotap/Sources/AppAudioCapture.swift` (`CATapDescription(stereoMixdownOfProcesses:)`) |
| Capture session orchestrator | `tools/audiotap/Sources/AudioCaptureSession.swift` |
| Recorder entrypoint (takes `appPID`) | `app/.../DualSourceRecorder.swift` `start(appPID:)` + `resolveTapPIDs(rootPID:)` |
| Detection protocol | `app/.../MeetingDetecting.swift` (`checkOnce()`/`isMeetingActive()`/`reset()`) |
| Existing detectors | `app/.../MeetingDetector.swift`, `app/.../PowerAssertionDetector.swift` |
| Window-title patterns | `app/.../MeetingPatterns.swift` |
| Watch loop (drives detection→record) | `app/.../WatchLoop.swift` (`defaultDetector()` returns `PowerAssertionDetector()`) |
| Protocol providers | `app/.../AppSettings.swift` (`ProtocolProvider` enum), `ClaudeCLIProtocolGenerator.swift`, `OpenAIProtocolGenerator.swift`, `ProtocolGenerator.swift` (protocol + shared utils) |
| Pipeline provider wiring | `app/.../PipelineQueue.swift` (`protocolGeneratorFactory`), `PipelineQueue+Stages.swift` |
| Settings UI | `app/.../Settings/OutputSettingsView.swift`, `TranscriptionSettingsView.swift` |
| App composition root | `app/.../AppState.swift` (wires controllers) |

## Feature Breakdown

### A. System-wide output capture — LINCHPIN
**Difficulty: Medium (contained). The first thing to build.**

- Add a process-agnostic `CATapDescription` path in AudioTapLib (capture the
  whole default-output-device mix, not a process list). CoreAudio (macOS 14.2+)
  supports this; it's the same `CATap` mechanism, different tap description.
- Make `AudioCaptureSession` / `AppAudioCapture` accept either `pids: [pid_t]`
  (existing) or a "system-wide" mode.
- Make `DualSourceRecorder.start(appPID: pid_t?)` — nil = system-wide.
- **Mic track untouched.** Diarization untouched.
- Keep `CurrentLevel`/`LevelPublisher` so silence detection still works (a
  system-wide recording with no audio should still be flagged as silent).

### B. Calendar detector + per-calendar selection — the big project
**Difficulty: Medium-Hard.**

New `MeetingDetecting` implementation driven by EventKit:

- Enumerate events across calendars; at an event's start time, return a
  `DetectedMeeting` (title from the event). Start a **system-wide** recording
  (no PID needed — that's why A comes first).
- Stop at event end (+ grace) OR on manual stop.
- **EventKit covers Google Calendar indirectly** — sync the Google account via
  System Settings → Internet Accounts (CalDAV). No OAuth code needed.
  (A native Google Calendar API client would need OAuth2 + token refresh +
  callback server + secrets management — explicitly out of scope unless
  Internet-Accounts sync proves insufficient.)

**Per-calendar selection (NEW REQUIREMENT):**

- EventKit exposes `eventStore.calendars(for: .event)` → `[EKCalendar]`, each
  with `title`, `calendarIdentifier`, `source` (account). Enumerate these for a
  toggle list in Settings.
- Store an **allowlist** of `calendarIdentifier`s in `AppSettings` (e.g.
  `enabledCalendarIDs: Set<String>`). Default: all on (or empty = all on, to
  avoid surprising first-run silence).
- Calendar detector only considers events whose calendar is in the allowlist.
- Settings UI: a section listing each calendar with its source/account label
  and a toggle. Re-scan on app activation (calendars can be added/removed).

**Open design question — the trigger seam is now solved by A:** because
recording is system-wide, the calendar detector does *not* need a PID. It just
needs event start/stop times. (For Meet events with a join URL, optionally
`NSWorkspace.open` the URL at start — nice-to-have, not required for capture.)

### C. Custom CLI agents (Pi, Claude, OpenCode) — medium, mechanical
**Difficulty: Medium. Self-contained, high value.**

- Add a **generic "CLI agent" generator** (`ProtocolGenerating`) parameterized
  by a command template (e.g. `pi --print`, `opencode run -`). Pipes transcript
  to stdin, captures stdout (plain text, not stream-JSON — simpler than
  `ClaudeCLIProtocolGenerator` and works for any agent).
- New `ProtocolProvider` cases (`.claudeCLI` exists; add `.cliAgent` or per-agent
  cases). New enum cases are `#if !APPSTORE`-gated like Claude CLI (sandbox
  forbids `Process()`).
- Settings UI: command template field + provider picker.
- Copy `ClaudeCLIProtocolGenerator` as the structural template (PATH resolution,
  detached stdin write to avoid pipe deadlock, `terminationHandler` before run).

### D. Google Meet detection pattern — MOOT (window-title detection dropped)
- Calendar-driven (B): **no detection code needed** — Meet is just whatever is
  making system audio during the scheduled window.
- Window-title detection as a fallback is **rejected**: it needs Screen
  Recording (`CGWindowListCopyWindowInfo`), which we are removing (F). Meet in a
  browser holds a display-sleep assertion during a call, so PowerAssertionDetector
  (E) already covers unscheduled Meet calls without a title regex.

### E. Slack huddles (stretch) — fallback detector
- Slack is Electron; process-tree support already exists.
- Detect via either a Slack huddle **window-title pattern** in
  `MeetingPatterns.swift`, or a `PreventUserIdleDisplaySleep` **power
  assertion** pattern in `PowerAssertionDetector` (Slack likely holds one during
  a huddle — same mechanism that already catches Zoom/Teams).
- With system-wide capture (A), no PID needed — just the trigger.

### F. Remove Screen Recording permission — cleanup, self-contained
**Difficulty: Low-Medium. Wide but mechanical (touches many files).**

SR is only used today for window-title *meeting detection* and the optional
window-title *enrichment* of a detected meeting. Audio capture (CATapDescription)
never needed it, and `PowerAssertionDetector` is already the default detector
(`WatchLoop.defaultDetector()`) — so the app already detects meetings without
SR. This phase deletes the residual SR surface so macOS never prompts for it and
the app never appears in the Screen Recording pane.

**Kill the hot-path SR call:**
- `PowerAssertionDetector.lookupWindowTitle()` (the only `CGWindowListCopyWindowInfo`
  call on the detection path) → **remove**. Its call site (`checkOnce()`) already
  falls back to `match.assertName`, so the detected title becomes the assertion
  name (e.g. the app/process name) instead of the live window title. Also drop the
  `windowListProvider` closure it depends on.

**Retire the detector we're superseding:**
- Delete (or shelve) `MeetingDetector.swift` + `MeetingDetectorTests.swift` — it is
  already unwired in production. After removal, the `meetingPatterns` (window-title
  regex) field on `AppMeetingPattern` in `MeetingPatterns.swift` is dead (only
  `ownerNames`/assertion fields remain in use); prune it too.

**Remove the permission surface:**
- `Info.plist`: delete `NSScreenCaptureUsageDescription`.
- `Permissions.swift`: delete `checkScreenRecording()`.
- `PermissionHealthCheck.swift`: delete `checkScreenRecording(systemAllowed:)`,
  `checkScreenRecordingLive()`, `hasForeignWindowWithTitle()`; drop the
  `screenRecording` field from `HealthCheckResult` (+ `overallHealth`/`runLive`);
  remove the `.screenRecordingDenied/.screenRecordingBroken` `PermissionProblem`
  cases. Mic + Accessibility health checks stay.
- `Settings/AdvancedSettingsView.swift`: remove the "Screen Recording"
  `PermissionRow` and the `screenCapture` `PrivacyPane`. (Note: the current
  `screenRecordingDetail` copy wrongly says SR is "Required for app audio
  capture" — it isn't; the row goes away entirely.)
- RPC surface: drop the `screenRecording` field from `RPCStateSnapshot` +
  `AppState+RPC`; scrub the SR comment in `DebugRPCServer`.

**Tests + docs to update:** `PermissionHealthCheckTests`, `PermissionsTests`,
`PermissionsControllerTests`, `RPCPermissionHealthTests`, `TestHelpers`,
`AppStateTests`, `SettingsViewTests`, and the WatchLoop test suites all
reference `screenRecording` and need pruning. Update `CLAUDE.md` (the
"Screen Recording required for meeting detection" critical note + the
`MeetingDetector` architecture bullet) and the self-hosted-runner setup steps in
`CLAUDE.md`/`scripts/setup-self-hosted-runner.sh`/`e2e-app.sh` that toggle SR.

**Independence / ordering:** F does not strictly depend on B — PowerAssertion is
already wired, so F can land any time. But B makes the trigger robust for apps
that never take a display-sleep assertion (the one gap power assertions can't
catch), so landing B first is the safer sequence before fully committing.

**Risk:** losing window-title enrichment means auto-detected meetings are titled
by app/assertion name rather than the specific window title (e.g. "Google Chrome"
instead of "Standup — Google Meet"). Calendar-driven meetings (B) get their title
from the event, so this only affects assertion-triggered (E) unscheduled calls.
Acceptable; the transcript/protocol filename stays meaningful.

**Note naming already handles the no-title case (done 2026-07-09, commit
`5d1e0fd`):** notes are named `yyyy-MM-dd-HHmm-{slug}`, and when a meeting has
no usable title the name degrades to just `yyyy-MM-dd-HHmm.{ext}` (no
placeholder). So a fully title-less meeting still produces a sensible,
collision-safe-enough filename after SR/window-title lookup is removed.

### G. Output routing & summary customization — self-contained, high personal value
**Difficulty: Medium. Plumbing + prompt wiring, no ML.**

Baseline today: one `effectiveOutputDir` (custom security-scoped bookmark, or
`~/Downloads/MeetingTranscriber/`) with two hardcoded subfolders —
`protocols/` (holds BOTH the `.txt` transcript and the `.md` summary) and
`recordings/` (audio + `_segments.json`). The `.md` summary also has the full
transcript appended **in code** (`PipelineQueue+Stages.generateProtocol()`:
`fullMD = protocolMD + "## Full Transcript" + transcript`) — NOT by the prompt
(the prompt only says "do not include the transcript, it will be appended
automatically"). Generation is a single LLM call over one prompt
(`ProtocolGenerator.buildSystemPrompt` = custom-or-default prompt + `{LANGUAGE}`
+ optional diarization note, then + transcript).

**G1 — Three independently-configurable output folders.** Replace the single
`effectiveOutputDir` + hardcoded subfolders with three separately-pickable
directories: **transcripts**, **summaries**, **recordings**. Each stored as its
own security-scoped bookmark in `AppSettings` (sandbox-safe) with a
"Choose…/Reset" row in Settings → Output. Defaults preserve today's layout
(transcripts+summaries → `…/protocols`, recordings → `…/recordings`) so existing
users see no change until they repoint.
- Files: `AppSettings` (three bookmarks + effective-dir accessors),
  `PipelineQueue+Stages` (`render` stage routing), `WatchLoop` (record-only
  destination), `OutputSettingsView` (three folder rows).

**G2 — Transcripts as `.md`.** `ProtocolGenerator.saveTranscript` writes `.md`
(was `.txt`); the new naming already yields `yyyy-MM-dd-HHmm-{slug}.md`.

**G3 — Custom prompt from any file (live, arbitrary path).** Add a "Choose
prompt file…" picker storing a path/security-scoped bookmark, read live at
generation time. `loadPrompt()` precedence: chosen file → copied
`protocol_prompt.md` → built-in default. **No suppress-diarization-note option**
(decided: the note stays).
- Files: `AppSettings` (prompt-file bookmark), `ProtocolGenerator.loadPrompt`,
  `OutputSettingsView` (prompt controls).

**G4 — Speaker data passed to the prompt + split summary/transcript into two
files.**
- **Participants → prompt:** substitute a `{SPEAKERS}` placeholder (mirroring
  `{LANGUAGE}`) with the meeting's resolved participant names, so the USER's
  prompt template decides representation. E.g. one user writes YAML
  `people:` with `[[wikilinks]]`, another `## People` numbered — entirely in
  their own prompt. Names come from the transcript's `[Name]` labels / resolved
  speaker mapping; generic labels (`Speaker 1`, `[Remote]`) filtered out.
  Consideration: the LLM renders the names per the prompt, so exact
  wikilink/name fidelity rides on prompt clarity — acceptable since the user
  owns the prompt. (Exact token name + whether the list is newline- vs
  comma-separated are implementation details.)
- **Split into two files:** stop appending the transcript to the summary. The
  summary `.md` (summaries folder) holds only the LLM output; the transcript
  `.md` (transcripts folder) is standalone. Remove the code-side append in
  `generateProtocol()` and drop the stale "will be appended automatically"
  clause from the default prompt.
- Files: `ProtocolGenerator` (`{SPEAKERS}` substitution + `buildSystemPrompt`
  gains a participants param; built-in prompt string), `PipelineQueue+Stages`
  (`generateProtocol` drops the append + passes participants + saves summary to
  summaries dir; `render` saves transcript `.md` to transcripts dir).

**Sequencing:** G is self-contained (no dependency on A/B/E/F) and
high-immediate-value, so it goes **first** among the remaining phases.

## Implementation Phases (ordered by dependency / value)

1. **A — System-wide capture mode** (linchpin). Recorder becomes PID-optional.
   Once this exists, B/D/E all get easier. **Prototype this first.** ✅ DONE
2. **C — Generic CLI agent generator.** Self-contained, proves the provider
   wiring, immediate value for summaries. ✅ DONE (2026-07-09)
   - `CLIAgentProtocolGenerator` (`#if !APPSTORE`): pipes system-prompt +
     transcript to an arbitrary command's stdin, reads plain stdout as the
     protocol. New `ProtocolProvider.cliAgent` case + `AppSettings.cliAgentCommand`
     (single editable command template; empty → transcript-only). Wired in
     `PipelineController.makeProtocolGenerator()`; command field + stdin-contract
     caption in `OutputSettingsView`. Quote-aware tokeniser; binary resolved
     against bundle search paths → `/usr/bin/env` fallback.
3. **G — Output routing & summary customization.** ✅ DONE (2026-07-10)
   **G1 — Three independently-configurable output folders.** ✅ DONE
   - `AppSettings`: Added `transcriptsDirBookmark`, `summariesDirBookmark`,
     `recordingsDirBookmark`, and `customPromptFileBookmark`. Added effective
     accessors (`effectiveTranscriptsDir`, `effectiveSummariesDir`,
     `effectiveRecordingsDir`, `effectiveCustomPromptFile`). Legacy
     `effectiveOutputDir` returns `effectiveTranscriptsDir` for compatibility.
   - `PipelineQueue`: Updated to accept three separate directories in init
     (defaults preserve old `outputDir/protocols` + `outputDir/recordings` layout).
   - `PipelineQueue+Stages`: Updated `generateAndSaveProtocol` to accept
     transcripts/summaries/recordings directories separately. `generateProtocol`
     now writes summaries to `summariesDir` instead of appending transcript.
   - `PipelineController`: Wired three separate directories from settings.
   - UI: Three folder rows (Transcripts, Summaries, Recordings) in
     `OutputSettingsView`, each with Choose/Reset buttons.
   - `WatchLoop`: Added `RecordOnlyDestination.recordingsDir(_:)` factory;
     `WatchingController` wired to `settings.effectiveRecordingsDir`.

   **G2 — Transcripts as `.md`.** ✅ DONE — `ProtocolGenerator.saveTranscript`
   already uses `.md` extension.

   **G3 — Custom prompt from any file (live, arbitrary path).** ✅ DONE
   - `AppSettings`: Added `customPromptFileBookmark` and `effectiveCustomPromptFile`.
   - `ProtocolGenerator.buildSystemPrompt`: Accepts `promptFileURL` parameter;
     `loadPrompt(from:)` reads the chosen file live.
   - All generators: Accept `promptFileURL` in init, thread to `buildSystemPrompt`.
   - UI: 'Choose Prompt File…' button in `OutputSettingsView` storing a
     security-scoped bookmark. `PipelineController` wires
     `settings.effectiveCustomPromptFile` into every generator.

   **G4 — Speaker data passed to the prompt + split summary/transcript files.** ✅ DONE
   - `ProtocolGenerator`: Added `extractParticipants(from:)` helper to extract
     unique speaker names from diarized transcripts. Added `buildSystemPrompt`
     overload accepting `participants: [String]?` with `{SPEAKERS}` substitution.
   - Protocol generators: All implementations now support the new `participants`
     parameter via the protocol conformance overload.
   - `PipelineQueue+Stages`: `generateProtocol` now extracts participants and
     passes them to the generator. Summaries are saved separately without
     appending the transcript.
   - `SpeakerNamingSession`: Updated generateProtocol calls to use summariesDir
     and extract participants.
   - **Tests:** Updated test mocks + SettingsViewTests + RPCSettingsStateTests.
4. **B — EventKit calendar detector + per-calendar allowlist UI.** ✅ DONE (2026-07-10)
   - CalendarDetector.swift (MeetingDetecting conformer) with EventKit provider,
     permission helper, and pure logic (CalendarEventInfo, CalendarDetectorLogic).
     System-wide capture (windowPID=0) routed to `appPID:nil` in WatchLoop.
     CalendarDetectionSection.swift UI (General → Calendar) with allowlist toggles
     (empty set = all calendars), permission grant flow, and authorization status.
   - CompositeMeetingDetector.swift layers calendar over PowerAssertionDetector.
   - AppSettings additions (`calendarDetectionEnabled`, `enabledCalendarIDs`).
   - AppStore.entitlements calendar permission, Info.plist usage description.
5. **E — Slack/Teams/etc. via PowerAssertionDetector.** ✅ Already wired
   as the fallback (remains secondary to calendar when B enabled). D
   window-title detection is rejected — see F.
6. **F — Remove Screen Recording permission.** ✅ DONE (2026-07-11)
   Removed the SR permission surface (Info.plist, permission health checks, Settings UI,
   RPC snapshot, all SR methods and test coverage). MeetingDetector deleted (window-title
   detection path removed). PowerAssertionDetector now uses assertion name directly as
   meeting title (no window lookup). Power-assertion detection and calendar detection
   together cover the use case without SR. DebugRPCServer screenshot endpoint remains
   the sole SR touchpoint (opt-in, used by e2e tests).

## Trade-offs & Risks

- **System-wide capture = all system audio** during the recording window
  (notifications, music, other tabs/apps). Acceptable for focused meetings; need
  easy manual start/stop so non-meeting audio isn't recorded. The purple CATap
  dot is the only indicator (no per-app attribution).
- **Concurrent audio mixes** if two things make sound — blends. Rare.
- **CLI agents = Homebrew build only** (`Process()` sandbox-forbidden). User is
  already on the Claude CLI / Homebrew path, so fine.
- **Google Calendar via Apple Calendar sync** depends on the user adding the
  Google account to Internet Accounts. If they want native Google API, that's a
  much bigger OAuth subproject (out of scope unless sync insufficient).
- **EventKit permission** (`NSCalendarsUsageDescription`) — new TCC prompt +
  health-check surface (the app already has a `PermissionsController` pattern
  to extend).
- **Calendar-only misses unscheduled calls** (ad-hoc huddles, someone calls
  you). That's what E (Slack power-assertion fallback) is for.

## Decisions Still Open

- [ ] Allowlist default: all-calendars-on, or opt-in empty? (Leaning: all-on,
      least surprising.)
- [ ] For Meet events with a join URL: auto-open the URL at event start, or
      assume the user joins manually and we just capture?
- [x] Keep the existing per-app detectors as fallbacks, or fully supersede them
      with calendar-first? **RESOLVED (2026-07-09):** calendar-first (B) as the
      primary trigger + `PowerAssertionDetector` (E) as the fallback for
      unscheduled Slack/Teams/etc. huddles. **`MeetingDetector` (window-title)
      is fully superseded and removed** along with the Screen Recording
      permission (F) — no window-title detection at all.
- [x] Generic CLI agent: one parameterized provider, or separate cases per agent?
      **RESOLVED (2026-07-09):** one parameterized `.cliAgent` provider with a
      single editable command template (no presets, no per-agent cases). Label
      field dropped (no honest UI surface without notification plumbing).
