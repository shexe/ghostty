import AppKit
import GhosttyKit

/// Moves text already typed at Claude Code's prompt into the compose box
/// when the box opens.
///
/// Without this, typing in the terminal (auto-popup off, bypassed with
/// compose_bypass_once, or focus simply sitting in the terminal) and then
/// opening the compose box leaves the same message split across two
/// editors: whichever one gets sent is missing the other half.
///
/// The terminal cannot know what program is attached to the pty, so this
/// works by scraping the visible screen for Claude Code's input box. The
/// parse is deliberately narrow — a bordered box whose first content row
/// starts with `> ` — so a plain shell prompt never matches and never gets
/// cleared. Nothing is removed from the terminal until the scraped text is
/// safely in the draft store.
///
/// Set GHOSTTY_COMPOSE_ADOPT_DEBUG=1 to append every read and its parse
/// result to /tmp/ghostty-compose-adopt.log (NSLog is invisible for this
/// app, so file logging is the only usable channel).
@MainActor
enum ComposePromptAdopter {
    /// How the terminal's copy of the text is removed once adopted.
    enum ClearStrategy: Equatable {
        /// Ctrl+C. Claude Code treats this as "clear the input" when the
        /// prompt has text in it. The default.
        case interrupt

        /// One Backspace per adopted character. Deterministic with respect
        /// to what we scraped, but only correct when the cursor is at the
        /// end of the input.
        case backspace

        /// Leave the terminal alone (adopt is then a copy, not a move).
        case none

        static func parse(_ raw: String?) -> ClearStrategy {
            switch raw?.lowercased() {
            case "backspace": return .backspace
            case "none", "off", "false": return .none
            default: return .interrupt
            }
        }
    }

    struct Adoption {
        let text: String
        let strategy: ClearStrategy
    }

    // MARK: - Entry point

    /// Reads the terminal and returns the text to pull into the compose
    /// box, or nil when there's nothing to adopt. Does not touch the
    /// terminal; call `clearTerminalInput` once the text is in the draft.
    static func adopt(from surfaceView: Ghostty.SurfaceView) -> Adoption? {
        note("adopt: called")
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        guard config?.composeAdoptPromptText ?? true else {
            note("adopt: disabled by compose-adopt-prompt-text")
            return nil
        }
        guard let read = viewportText(for: surfaceView) else {
            note("adopt: viewport read failed (no surface?)")
            return nil
        }

        let parsed = parseDetailed(read.text)
        debugLog(viewport: read.text, parsed: parsed?.text)
        guard let parsed, !parsed.text.isEmpty else { return nil }

        let caret = caretAtEndOfInput(
            parsed: parsed, read: read, surfaceView: surfaceView)
        let text = parsed.text + String(repeating: " ", count: caret?.trailingSpaces ?? 0)

        let configured = ClearStrategy.parse(config?.composeAdoptPromptClear)
        let strategy = clearStrategy(
            configured: configured,
            caretIsAtEnd: caret != nil,
            adoptedLength: text.count)

        return Adoption(text: text, strategy: strategy)
    }

    /// The result of proving the caret sits at the end of Claude Code's input.
    ///
    /// Two things depend on this proof, and they're the same question asked
    /// twice: how many trailing spaces the user typed (the gap between the
    /// drawn text and the caret), and whether Backspace is a safe way to
    /// clear the terminal (it deletes leftwards, so only from the end).
    private struct CaretAtEnd {
        let trailingSpaces: Int
    }

    /// Returns non-nil only when the caret is provably at the end of the
    /// input. Every branch that can't establish that returns nil, because
    /// both callers do something wrong if this is guessed: bogus spaces get
    /// appended, or backspaces eat the wrong characters.
    private static func caretAtEndOfInput(
        parsed: ParseResult,
        read: ViewportRead,
        surfaceView: Ghostty.SurfaceView
    ) -> CaretAtEnd? {
        guard parsed.lastRowEndColumn >= 0 else { return nil }
        guard let cursor = cursorPosition(for: surfaceView, read: read) else {
            note("caret: no cursor position available")
            return nil
        }

        // The caret must be at or past where the drawn text ends, and no
        // further past it than a plausible run of trailing spaces.
        let gap = cursor.column - parsed.lastRowEndColumn
        guard gap >= 0, gap <= maxRecoveredTrailingSpaces else {
            note("caret: column \(cursor.column) vs endCol \(parsed.lastRowEndColumn) (gap=\(gap)) — not at end")
            return nil
        }

        // A single-row input needs no row check: the caret is inside the
        // input box, so on a one-row box it can only be on that row.
        if parsed.rowCount == 1 {
            note("caret: at end of single-row input, \(gap) trailing space(s)")
            return CaretAtEnd(trailingSpaces: gap)
        }

        // Multi-row: the column alone proves nothing, because a caret parked
        // on an earlier row can still report a column past the last row's
        // end. The row has to match too, which means treating emitted line N
        // as viewport row N.
        //
        // That mapping survives the read dropping trailing blank lines (the
        // formatter always trims those, so a full screen routinely yields
        // one fewer line than there are rows) because dropping from the end
        // doesn't move anything above it. It does NOT survive lines being
        // joined mid-screen by soft-wrap unwrapping, which shifts everything
        // below. A join can only pull the input's lines UP relative to their
        // true rows, so the comparison below stops matching and this fails
        // closed rather than clearing the wrong text.
        guard let gridRows = gridRowCount(for: surfaceView) else {
            note("caret: no grid size, can't verify row on multi-row input")
            return nil
        }
        guard parsed.lineCount <= gridRows else {
            note("caret: \(parsed.lineCount) lines exceeds \(gridRows) rows — mapping impossible")
            return nil
        }
        guard cursor.row == parsed.lastRowIndex else {
            note("caret: on row \(cursor.row), input ends on row \(parsed.lastRowIndex) — not at end")
            return nil
        }

        note("caret: at end of \(parsed.rowCount)-row input, \(gap) trailing space(s)")
        return CaretAtEnd(trailingSpaces: gap)
    }

    /// Picks how to clear the terminal's copy.
    ///
    /// Ctrl+C is the reliable clear but it is also Claude Code's interrupt:
    /// adopting mid-turn kills the turn (confirmed live 2026-07-31). Backspace
    /// never interrupts anything, but it deletes leftwards, so it is only
    /// correct when the caret sits at the end of the input.
    ///
    /// Thanks to the cursor read we can prove that rather than assume it, so
    /// backspace is used whenever the proof holds and the configured strategy
    /// is the fallback for when it doesn't.
    ///
    /// Backspace is used whenever the caret is provably at the end of the
    /// input; the configured strategy is only the fallback for when that
    /// proof fails.
    private static func clearStrategy(
        configured: ClearStrategy,
        caretIsAtEnd: Bool,
        adoptedLength: Int
    ) -> ClearStrategy {
        // Already backspacing: nothing to decide.
        guard configured != .backspace else { return configured }
        // `none` is deliberately NOT short-circuited here. It means "send
        // nothing when Backspace can't be proven safe" — it is the fallback,
        // not a veto. Treating it as a veto disabled the proof path entirely
        // for anyone who took the advice to set it.

        guard caretIsAtEnd else {
            note("clear: caret not provably at end, using configured \(configured)")
            return configured
        }

        // A very long draft would mean thousands of synthetic key events.
        // Falling back is the lesser evil; with `none` configured that just
        // leaves the text for the user to clear.
        guard adoptedLength <= maxBackspaces else {
            note("clear: \(adoptedLength) chars exceeds backspace cap, using configured \(configured)")
            return configured
        }

        note("clear: caret at end, \(adoptedLength) backspaces instead of \(configured)")
        return .backspace
    }

    /// Maximum number of trailing spaces inferred from the cursor gap.
    private static let maxRecoveredTrailingSpaces = 32

    /// Upper bound on synthetic Backspace presses used to clear the prompt.
    private static let maxBackspaces = 1000

    /// The terminal cursor's cell position, derived from the IME point.
    ///
    /// That point is `cursor.x * cellWidth + padding.left + cellWidth / 2`
    /// horizontally and the BOTTOM of the cursor cell vertically, both
    /// unscaled. The viewport read hands back the pixel origin of its
    /// top-left cell in the same space, so subtracting it cancels the window
    /// padding, which isn't queryable from Swift.
    private static func cursorPosition(
        for surfaceView: Ghostty.SurfaceView,
        read: ViewportRead
    ) -> (column: Int, row: Int)? {
        guard let surface = surfaceView.surface else { return nil }
        let cellWidth = surfaceView.cellSize.width
        let cellHeight = surfaceView.cellSize.height
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Horizontally both points carry the same padding, and the IME point
        // adds half a cell to reach the midpoint: the difference is
        // `cursor.x + 0.5`.
        let column = (x - read.originX) / cellWidth - 0.5

        // Vertically the two differ by more than padding. read_text's origin
        // is a text BASELINE (`+ cellHeight - baseline`) while the IME point
        // is the cell's BOTTOM (`+ cellHeight`), so the cell-height terms
        // cancel and the difference is `cursor.y * cellHeight + baseline`.
        // The baseline always falls inside the cell, so it is strictly less
        // than one row and floor() drops it exactly — no need for the font
        // metric itself, which isn't exposed here.
        let rowFloat = (y - read.originY) / cellHeight
        let row = rowFloat.rounded(.down)
        note(String(
            format: "cursor: imeX=%.1f imeY=%.1f origin=(%.1f,%.1f) cell=%.2fx%.2f -> col=%.2f row=%.2f (raw %.2f)",
            x, y, read.originX, read.originY, cellWidth, cellHeight, column, row, rowFloat))
        guard column.isFinite, column >= 0, column < 10_000 else { return nil }
        guard row.isFinite, row >= 0, row < 10_000 else { return nil }
        return (Int(column.rounded()), Int(row))
    }

    /// Rows in the terminal grid, used to check that the viewport read gave
    /// us exactly one line per row before trusting line indices as rows.
    private static func gridRowCount(for surfaceView: Ghostty.SurfaceView) -> Int? {
        guard let surface = surfaceView.surface else { return nil }
        return Int(ghostty_surface_size(surface).rows)
    }

    /// Removes the adopted text from Claude Code's input. Only call this
    /// after the text has been written to ComposeDraftStore, so a bad
    /// scrape can never destroy typing that exists nowhere else.
    static func clearTerminalInput(
        _ adoption: Adoption,
        surfaceView: Ghostty.SurfaceView
    ) {
        guard let surface = surfaceView.surfaceModel else { return }
        switch adoption.strategy {
        case .none:
            return

        case .interrupt:
            // Same synthetic-key shape as ComposeBoxView.sendInterrupt: the
            // legacy encoding derives the control byte (0x03) from the key's
            // codepoint, so text and unshiftedCodepoint must both be set.
            surface.sendKeyEvent(.init(
                key: .c,
                action: .press,
                text: "\u{03}",
                mods: .ctrl,
                unshiftedCodepoint: 0x63))
            surface.sendKeyEvent(.init(
                key: .c,
                action: .release,
                mods: .ctrl,
                unshiftedCodepoint: 0x63))

        case .backspace:
            for _ in 0..<adoption.text.count {
                surface.sendKeyEvent(.init(key: .backspace, action: .press))
                surface.sendKeyEvent(.init(key: .backspace, action: .release))
            }
        }
    }

    // MARK: - Reading the screen

    /// A fresh read of the visible viewport. SurfaceView.cachedVisibleContents
    /// exists but caches for 500ms, which is long enough to miss the last few
    /// characters typed before the box was opened — exactly the text we're
    /// here to adopt.
    /// A viewport read plus the pixel origin of its top-left cell, which is
    /// the reference point for turning the cursor's pixel position back into
    /// a column (it carries the window padding we can't query directly).
    struct ViewportRead {
        let text: String
        let originX: Double
        let originY: Double
    }

    private static func viewportText(for surfaceView: Ghostty.SurfaceView) -> ViewportRead? {
        guard let surface = surfaceView.surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return ViewportRead(
            text: String(cString: text.text),
            originX: text.tl_px_x,
            originY: text.tl_px_y)
    }

    // MARK: - Parsing

    /// Left and right box-drawing borders Claude Code has used.
    private static let borderChars: Set<Character> = ["│", "|", "┃", "┆", "┊"]

    /// Corner/edge characters that close the input box.
    private static func isBottomBorder(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "╰└┗╚".contains(first)
    }

    /// Pulls the user's in-progress text out of a viewport dump.
    ///
    /// Claude Code renders the input as:
    ///
    ///     ╭──────────────────────────────╮
    ///     │ > some text the user typed   │
    ///     │   that wrapped onto row two  │
    ///     ╰──────────────────────────────╯
    ///
    /// Returns nil when no such box is visible or it holds only placeholder
    /// hint text.
    /// A successful parse, plus the screen column the drawn text ends at on
    /// its last row. That column is the anchor for recovering trailing
    /// whitespace from the cursor; -1 means "don't try" (the bordered box
    /// pads its rows, so its row length says nothing about where text ends).
    struct ParseResult {
        let text: String
        let lastRowEndColumn: Int
        /// Screen rows the input occupies. A single-row input lets the cursor
        /// column alone prove the caret is at the end; more rows need the
        /// cursor's row as well.
        let rowCount: Int
        /// Index of the input's last row within the viewport lines.
        let lastRowIndex: Int
        /// Total viewport lines the read produced. Equal to the terminal's
        /// row count exactly when no line was joined or dropped, which is
        /// what makes a line index usable as a row index.
        let lineCount: Int
    }

    static func parse(_ viewport: String) -> String? {
        parseDetailed(viewport)?.text
    }

    static func parseDetailed(_ viewport: String) -> ParseResult? {
        let raw = normalizeSpaces(unjoinSoftWrappedRows(viewport))
            .components(separatedBy: "\n")
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }

        // Search bottom-up: on a busy screen the newest box is the live one.
        guard let promptIndex = lines.lastIndex(where: isPromptRow) else {
            return parseRuleDelimited(raw: raw, lines: lines)
        }

        // Collect the prompt row plus any bordered continuation rows below
        // it, stopping at the box's bottom edge.
        var rows: [String] = [lines[promptIndex]]
        var i = promptIndex + 1
        while i < lines.count {
            let line = lines[i]
            if isBottomBorder(line) { break }
            guard let first = line.first, borderChars.contains(first) else { break }
            // A blank bordered row means the box is padded, not wrapped.
            if stripBorders(line).trimmingCharacters(in: .whitespaces).isEmpty { break }
            rows.append(line)
            i += 1
        }

        // Require the box to actually close below the rows we took. Without
        // this, a lone "> " line — zsh's continuation prompt, a quoted line
        // in scrollback — would look like a prompt and we'd fire the clear
        // keystroke at whatever is really running.
        let closed = (i < lines.count && isBottomBorder(lines[i]))
            || (i + 1 < lines.count && isBottomBorder(lines[i + 1]))
        guard closed else { return parseRuleDelimited(raw: raw, lines: lines) }

        // Strip borders and the "> " marker. Rows are space-padded out to
        // the border, so the padded inner width is the usable text width and
        // is the same on every row of the box.
        var contents: [String] = []
        var filledToEdge: [Bool] = []
        for (index, row) in rows.enumerated() {
            let innerPadded = stripBorders(row)
            let innerWidth = innerPadded.count
            filledToEdge.append(
                innerWidth > 0 && trimTrailing(innerPadded).count >= innerWidth - 1)

            var inner = innerPadded
            if index == 0 {
                inner = stripPromptMarker(inner)
            } else if inner.hasPrefix("  ") {
                inner = String(inner.dropFirst(2))
            }
            contents.append(trimTrailing(inner))
        }

        // Rejoin. A row whose text ran to the box edge was soft-wrapped by
        // Claude Code, so it continues the same logical line; a short row
        // ended in a newline the user actually typed. One cell of slack
        // tolerates wide glyphs that can't straddle the boundary.
        var result = ""
        for (index, content) in contents.enumerated() {
            if index > 0 {
                result += filledToEdge[index - 1] ? "" : "\n"
            }
            result += content
        }

        result = trimTrailing(result)
        guard !result.isEmpty else { return nil }
        guard !isPlaceholder(result) else { return nil }
        // -1: this box pads its rows out to the border, so there's no honest
        // "where the text ends" column to hang trailing-space recovery on.
        return ParseResult(
            text: result,
            lastRowEndColumn: -1,
            rowCount: rows.count,
            lastRowIndex: promptIndex + rows.count - 1,
            lineCount: lines.count)
    }

    /// Pulls the user's text out of the *rule-delimited* input Claude Code
    /// renders in current versions — no side borders, a `❯` marker, and a
    /// horizontal rule above (often carrying the conversation title) and
    /// below:
    ///
    ///     ─────────────────────── Some conversation title ──
    ///     ❯ text the user typed
    ///       that wrapped onto row two
    ///     ──────────────────────────────────────────────────
    ///
    /// Both rules are required. A bare `❯ ` line is a common shell prompt
    /// (starship, pure, p10k), and adopting from one would fire the clear
    /// keystroke at a shell — the enclosing rules are what make this
    /// unambiguously Claude Code.
    private static func parseRuleDelimited(raw: [String], lines: [String]) -> ParseResult? {
        guard let promptIndex = lines.lastIndex(where: isRulePromptRow) else { return nil }

        // A rule above, allowing one blank row of slack.
        let ruleAbove = (promptIndex >= 1 && isRule(lines[promptIndex - 1]))
            || (promptIndex >= 2 && isRule(lines[promptIndex - 2]))
        guard ruleAbove else { return nil }

        // Content runs to the closing rule. Anything else (a truly blank row,
        // the end of the viewport) means this isn't the live input box. The
        // test is on the raw row, not the trimmed one: a row holding only
        // spaces is a line of the draft whose content is trailing whitespace,
        // while a row where nothing was ever written is the end of the box.
        var rows: [Int] = [promptIndex]
        var i = promptIndex + 1
        while i < lines.count, !isRule(lines[i]) {
            guard !raw[i].isEmpty else { return nil }
            rows.append(i)
            i += 1
        }
        guard i < lines.count else { return nil }

        // The closing rule spans the box, so its width is the width at which
        // Claude Code soft-wraps the input.
        let boxWidth = lines[i].count

        // Continuation rows are indented to sit under the text, by however
        // many columns the marker and its trailing space occupy. Measuring it
        // off the marker row beats assuming 2, in case the marker changes.
        let markerIndent = raw[promptIndex].count
            - stripPromptMarker(raw[promptIndex]).count

        // Content comes from the RAW rows. `lines` is trimmed on both ends,
        // which silently ate any trailing spaces the user typed — Ghostty
        // reads the screen with trim=false and Claude Code doesn't pad the
        // row past its text (verified in a viewport dump: an empty prompt row
        // is exactly "❯\u{00A0}"), so trailing spaces here are real input.
        var contents: [String] = []
        var filledToEdge: [Bool] = []
        for (offset, index) in rows.enumerated() {
            var inner = Substring(raw[index])
            if offset == 0 {
                inner = Substring(stripPromptMarker(String(inner)))
            } else {
                var dropped = 0
                while dropped < markerIndent, inner.first == " " {
                    inner = inner.dropFirst()
                    dropped += 1
                }
            }
            filledToEdge.append(boxWidth > 0 && raw[index].count >= boxWidth - 1)
            contents.append(String(inner))
        }

        var result = ""
        for (index, content) in contents.enumerated() {
            if index > 0 { result += filledToEdge[index - 1] ? "" : "\n" }
            result += content
        }

        // Whitespace-only means the prompt is empty and the spaces are
        // Claude Code's own layout, not typing worth adopting — and adopting
        // it would fire the clear keystroke at an empty prompt.
        guard result.contains(where: { !$0.isWhitespace }) else { return nil }
        guard !isPlaceholder(result) else { return nil }

        // This box starts at column 0 and isn't padded, so the last row's
        // length is exactly the column the drawn text ends at.
        let lastRowIndex = rows[rows.count - 1]
        return ParseResult(
            text: result,
            lastRowEndColumn: raw[lastRowIndex].count,
            rowCount: rows.count,
            lastRowIndex: lastRowIndex,
            lineCount: lines.count)
    }

    /// A row like `❯ text`, with no border. Also accepts `> ` so a version
    /// that drops the fancy marker still adopts; the enclosing rules carry
    /// the real safety burden here.
    private static func isRulePromptRow(_ line: String) -> Bool {
        guard let first = line.first, promptMarkers.contains(first) else { return false }
        let rest = line.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    /// A full-width horizontal rule, with or without a title baked into it.
    private static func isRule(_ line: String) -> Bool {
        guard let first = line.first, ruleChars.contains(first) else { return false }
        return line.filter { ruleChars.contains($0) }.count >= 8
    }

    private static let promptMarkers: Set<Character> = ["❯", ">", "›", "▶"]
    private static let ruleChars: Set<Character> = ["─", "━", "═", "╌", "┈"]

    /// Border characters that can end a rendered row, and ones that can
    /// start one. When Claude Code's box spans the full terminal width the
    /// rows soft-wrap, and read_text joins soft-wrapped rows into a single
    /// line — so `│ > hello  ││   world  │` arrives as one string and no
    /// line looks like a prompt row. Splitting on a right-edge character
    /// immediately followed by a left-edge one puts the rows back.
    private static let rowEndChars: Set<Character> = ["│", "|", "┃", "╮", "╯", "┐", "┘", "╗", "╝"]
    private static let rowStartChars: Set<Character> = ["│", "|", "┃", "╭", "╰", "┌", "└", "╔", "╚"]

    /// Space-like characters Claude Code uses that aren't U+0020. The gap
    /// after the `❯` marker is a NO-BREAK SPACE (U+00A0) — verified in a
    /// viewport dump — which made every `== " "` test in the parser fail and
    /// took the whole parse to nil. Mapping them to plain spaces is
    /// one-character-for-one, so the padded-width math that infers soft wrap
    /// from row length is unaffected.
    private static let spaceLikeChars: Set<Character> = [
        "\u{00A0}",  // no-break space
        "\u{2007}",  // figure space
        "\u{202F}",  // narrow no-break space
        "\u{2009}",  // thin space
        "\u{200A}",  // hair space
    ]

    private static func normalizeSpaces(_ text: String) -> String {
        guard text.contains(where: { spaceLikeChars.contains($0) }) else { return text }
        return String(text.map { spaceLikeChars.contains($0) ? " " : $0 })
    }

    private static func unjoinSoftWrappedRows(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for ch in text {
            if let previous, rowEndChars.contains(previous), rowStartChars.contains(ch) {
                out.append("\n")
            }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// A row like `│ > text`. The border is required: an unboxed `> ` line
    /// is far more likely to be a shell continuation prompt or quoted text
    /// than Claude Code's input.
    private static func isPromptRow(_ line: String) -> Bool {
        var s = Substring(line)
        guard let first = s.first, borderChars.contains(first) else { return false }
        s = s.dropFirst()
        while s.first == " " { s = s.dropFirst() }
        return s.hasPrefix(">")
    }

    private static func stripBorders(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, borderChars.contains(first) { s = s.dropFirst() }
        if let last = s.last, borderChars.contains(last) { s = s.dropLast() }
        // Every content row is indented one space inside the border.
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    /// Drops the `❯ ` / `> ` marker. Leading spaces are skipped first so this
    /// works on a raw screen row, where the box may be indented — the
    /// rule-delimited parser measures its continuation indent from what this
    /// removes, so returning the row unchanged there would be a silent miss.
    private static func stripPromptMarker(_ inner: String) -> String {
        var s = Substring(inner)
        while s.first == " " { s = s.dropFirst() }
        guard let first = s.first, promptMarkers.contains(first) else { return inner }
        s = s.dropFirst()
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    private static func trimTrailing(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, last == " " || last == "\t" { out = out.dropLast() }
        return String(out)
    }

    /// Claude Code fills an empty input with dim hint text. read_text gives
    /// us no styling, so the hints have to be recognized by content.
    private static let placeholderPrefixes = [
        "try \"",
        "try '",
        "ask anything",
        "how can i help",
        "/ for commands",
        "@ for files",
        "# to memorize",
        "run /init",
        "esc to interrupt",
        "shift+tab to cycle",
        "press up to",
        "plan mode on",
        "accept edits on",
    ]

    private static func isPlaceholder(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        let lower = text.lowercased()
        return placeholderPrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: - Debug

    /// Debug logging is on when GHOSTTY_COMPOSE_ADOPT_DEBUG=1 is in the
    /// environment, or — since the app is normally launched from Finder,
    /// where setting an env var isn't practical — when the flag file
    /// /tmp/ghostty-compose-adopt.on exists. `touch` it to start logging
    /// without restarting Ghostty; `rm` it to stop.
    private static var debugEnabled: Bool {
        if ProcessInfo.processInfo.environment["GHOSTTY_COMPOSE_ADOPT_DEBUG"] == "1" {
            return true
        }
        return FileManager.default.fileExists(atPath: "/tmp/ghostty-compose-adopt.on")
    }

    /// One-line breadcrumb to the debug log.
    static func note(_ message: String) {
        guard debugEnabled else { return }
        append("\(message)\n")
    }

    private static func debugLog(viewport: String, parsed: String?) {
        guard debugEnabled else { return }
        // Only the tail matters: the input box lives at the bottom. Rows are
        // bracketed so trailing spaces and empty rows are visible.
        let lines = viewport.components(separatedBy: "\n")
        let tail = lines
            .suffix(30)
            .map { "|\($0)|" }
            .joined(separator: "\n")
        append("""
            === compose adopt === (\(lines.count) viewport lines)
            --- viewport tail ---
            \(tail)
            --- parsed ---
            \(parsed.map { "[\($0)]" } ?? "<nil>")

            """)
    }

    private static func append(_ entry: String) {
        let url = URL(fileURLWithPath: "/tmp/ghostty-compose-adopt.log")
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
