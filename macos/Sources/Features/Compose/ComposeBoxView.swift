import SwiftUI
import AppKit
import GhosttyKit

/// A per-surface compose draft: unsent text and attached images.
class ComposeDraft {
    var text: String = ""
    var images: [NSImage] = []

    /// Large pastes are collapsed to a "[Pasted text #N +K lines]"
    /// placeholder in the editor; this maps each placeholder back to its
    /// full text for expansion at send time. Deleting a placeholder from
    /// the draft simply orphans its entry here, which is harmless.
    var pastes: [String: String] = [:]
    var pasteCounter: Int = 0

    var isEmpty: Bool { text.isEmpty && images.isEmpty }
}

/// Stores in-progress compose box drafts per surface so a draft survives the
/// panel being closed or the surface losing focus. Keys are held weakly so
/// entries disappear with their surface.
class ComposeDraftStore {
    static let shared = ComposeDraftStore()

    private let drafts = NSMapTable<Ghostty.SurfaceView, ComposeDraft>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    func draft(for surface: Ghostty.SurfaceView) -> ComposeDraft {
        if let existing = drafts.object(forKey: surface) { return existing }
        let draft = ComposeDraft()
        drafts.setObject(draft, forKey: surface)
        return draft
    }

    func clear(for surface: Ghostty.SurfaceView) {
        drafts.removeObject(forKey: surface)
    }

    // Convenience for the auto-popup seed path.
    func setDraft(_ text: String, for surface: Ghostty.SurfaceView) {
        draft(for: surface).text = text
    }

    /// If the string is a large paste (compose-paste-collapse-lines),
    /// registers it on the surface's draft and returns the placeholder
    /// token to insert instead. Returns nil when it should paste inline.
    static func collapsedToken(
        for string: String,
        surface: Ghostty.SurfaceView
    ) -> String? {
        let threshold = (NSApp.delegate as? AppDelegate)?
            .ghostty.config.composePasteCollapseLines ?? 5
        guard threshold > 0 else { return nil }
        let lines = string.components(separatedBy: "\n").count
        guard lines >= threshold else { return nil }

        let draft = shared.draft(for: surface)
        draft.pasteCounter += 1
        let token = "[Pasted text #\(draft.pasteCounter) +\(lines - 1) lines]"
        draft.pastes[token] = string
        return token
    }
}

/// Transient per-surface compose UI state (currently just the open image
/// preview). This lives outside the view because TerminalView recreates
/// the compose view off lastFocusedSurface: a click that shuffles window
/// focus can tear the view down and rebuild it mid-interaction, wiping
/// any @State. Draft text/images already survive that via
/// ComposeDraftStore; this is the same pattern for non-draft UI state.
class ComposeUIState: ObservableObject {
    @Published var previewImage: NSImage?

    private static let states = NSMapTable<Ghostty.SurfaceView, ComposeUIState>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    static func state(for surface: Ghostty.SurfaceView) -> ComposeUIState {
        if let existing = states.object(forKey: surface) { return existing }
        let state = ComposeUIState()
        states.setObject(state, forKey: surface)
        return state
    }
}

extension Notification.Name {
    /// Key in ghosttyComposeAutoPopup userInfo carrying the keystroke text
    /// that triggered the popup, so it seeds the draft.
    static let ghosttyComposeSeedKey = "com.mitchellh.ghostty.composeSeed"

    /// Key in ghosttyComposeAutoPopup userInfo carrying an image pasted in
    /// the terminal, attached to the draft when the popup opens.
    static let ghosttyComposeSeedImageKey = "com.mitchellh.ghostty.composeSeedImage"
}

/// Per-surface auto-popup state: whether plain typing/pasting in the
/// terminal should open the compose box. Defaults on when the surface looks
/// like a Claude Code session (title heuristic) and off otherwise; the
/// "Auto-Open Compose Box" menu item / toggle_compose_auto_popup keybind
/// overrides per surface.
class ComposeAutoPopupStore {
    static let shared = ComposeAutoPopupStore()

    private let overrides = NSMapTable<Ghostty.SurfaceView, NSNumber>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    /// Claude Code sets the terminal title with a leading spinner glyph
    /// (e.g. "✳ Fixing the parser"); a plain shell shows a path. This is
    /// the best available signal — the terminal cannot know what program
    /// is attached to the pty.
    static func titleLooksLikeClaude(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let first = surface.title.unicodeScalars.first else { return false }
        return "✳✻✢✶✽·*".unicodeScalars.contains(first)
    }

    /// Surfaces with a one-shot bypass active (compose_bypass_once): the
    /// next command is typed directly into the terminal, and auto-popup
    /// resumes after Enter.
    private let bypassed = NSMapTable<Ghostty.SurfaceView, NSNumber>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    func isEnabled(for surface: Ghostty.SurfaceView) -> Bool {
        guard (NSApp.delegate as? AppDelegate)?.ghostty.config.composeEnabled ?? true else {
            return false
        }
        if isBypassed(for: surface) { return false }
        if isInSlashCommand(for: surface) { return false }
        return overrides.object(forKey: surface)?.boolValue
            ?? Self.titleLooksLikeClaude(surface)
    }

    func setOverride(_ enabled: Bool, for surface: Ghostty.SurfaceView) {
        overrides.setObject(NSNumber(value: enabled), forKey: surface)
    }

    func isBypassed(for surface: Ghostty.SurfaceView) -> Bool {
        bypassed.object(forKey: surface)?.boolValue ?? false
    }

    func beginBypass(for surface: Ghostty.SurfaceView) {
        bypassed.setObject(NSNumber(value: true), forKey: surface)
    }

    func endBypass(for surface: Ghostty.SurfaceView) {
        bypassed.removeObject(forKey: surface)
    }

    /// Per-surface slash-command state: a "/" was handed to the terminal's
    /// slash-command menu, and auto-popup stays suppressed until the
    /// command is submitted, cancelled, or deleted. `typed` is the
    /// best-effort text since and including the "/" (tab-completed text
    /// can't be seen), so backspacing all the way past the "/" re-arms.
    /// `answered` marks a dialog answered by a printable key: suppression
    /// covers that key, then the state ends on the next event.
    private class SlashCommandState {
        var typed = "/"
        var inDialog = false
        var answered = false
    }

    private let slashStates = NSMapTable<Ghostty.SurfaceView, SlashCommandState>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    /// Slash commands that follow Enter with an interactive dialog
    /// (dismissed by a single key like "s" in /model, a digit, Enter, or
    /// Esc). For these, suppression extends past Enter until one more
    /// printable key, Enter, or Esc so the answer reaches the dialog
    /// instead of popping the compose box. Matched by prefix on the
    /// typed text, since tab-completion hides the full name.
    private static let dialogCommands = [
        "model", "config", "usage", "permissions", "mcp", "agents",
        "status", "hooks", "memory", "resume", "login", "theme", "ide",
        "help", "todos",
    ]

    private static func commandOpensDialog(_ typed: String) -> Bool {
        guard let name = typed.dropFirst() // leading "/"
            .split(separator: " ").first?.lowercased(),
              !name.isEmpty else { return false }
        return dialogCommands.contains { $0.hasPrefix(name) }
    }

    /// Plain printable typing: what auto-popup would intercept.
    private static func isPrintableKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20
            && scalar.value != 0x7F
            && !(0xF700...0xF8FF).contains(scalar.value)
    }

    func isInSlashCommand(for surface: Ghostty.SurfaceView) -> Bool {
        slashStates.object(forKey: surface) != nil
    }

    func beginSlashCommand(for surface: Ghostty.SurfaceView) {
        slashStates.setObject(SlashCommandState(), forKey: surface)
    }

    func endSlashCommand(for surface: Ghostty.SurfaceView) {
        slashStates.removeObject(forKey: surface)
    }

    /// Observe a key event headed to the terminal while a slash command
    /// is in progress. Suppression ends when the command is submitted
    /// (Enter — or, for dialog commands, one keystroke after Enter),
    /// cancelled (Esc, Ctrl+C, Ctrl+U, Cmd+Delete), or deleted back past
    /// the "/". Tab-completion inserts text we can't count, so
    /// undercounting just keeps the terminal in charge until Enter — the
    /// safe direction.
    func trackSlashCommandKey(_ event: NSEvent, for surface: Ghostty.SurfaceView) {
        guard let state = slashStates.object(forKey: surface) else { return }

        // A printable key answered the dialog on the previous event;
        // this event gets normal treatment again.
        if state.answered {
            endSlashCommand(for: surface)
            return
        }

        let mods = event.modifierFlags.intersection([.command, .control, .option])

        if state.inDialog {
            switch event.keyCode {
            case 0x24, 0x4C, 0x35: // Enter / Esc dismiss the dialog
                endSlashCommand(for: surface)
                return
            case 0x08 where mods == [.control]: // Ctrl+C
                endSlashCommand(for: surface)
                return
            default:
                break
            }
            // A single printable key (e.g. "s" in /model, a digit choice)
            // answers and dismisses the dialog. Suppression must still
            // cover this event so the key reaches the terminal; end on
            // the next one. Arrows/Tab navigate and keep the dialog open.
            if Self.isPrintableKey(event) {
                state.answered = true
            }
            return
        }

        switch event.keyCode {
        case 0x24, 0x4C: // Return / keypad Enter: submitted
            if Self.commandOpensDialog(state.typed) {
                state.inDialog = true
            } else {
                endSlashCommand(for: surface)
            }
            return
        case 0x35: // Esc: Claude Code clears the input line
            endSlashCommand(for: surface)
            return
        case 0x33: // Delete
            if mods.contains(.command) { // delete to line start
                endSlashCommand(for: surface)
            } else {
                // Opt+Delete kills a word we can't measure; removing one
                // char errs toward staying in the terminal.
                if !state.typed.isEmpty { state.typed.removeLast() }
                if state.typed.isEmpty { endSlashCommand(for: surface) }
            }
            return
        case 0x08 where mods == [.control]: // Ctrl+C interrupt
            endSlashCommand(for: surface)
            return
        case 0x20 where mods == [.control]: // Ctrl+U line kill
            endSlashCommand(for: surface)
            return
        default:
            break
        }

        if Self.isPrintableKey(event) {
            state.typed.append(event.characters ?? "")
        }
    }

    /// Whether this key event is a "/" that should be handed to the
    /// terminal's slash-command menu instead of the compose box: first
    /// character (no existing draft) in a Claude Code tab.
    static func isSlashHandoff(_ event: NSEvent, surfaceView: Ghostty.SurfaceView) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control])
        guard mods.isEmpty else { return false }
        return event.characters == "/"
            && titleLooksLikeClaude(surfaceView)
            && ComposeDraftStore.shared.draft(for: surfaceView).isEmpty
    }

    /// Whether this key event should open the compose box instead of going
    /// to the terminal: plain printable typing, no command/control chords,
    /// no IME composition or key sequence in progress.
    static func shouldIntercept(_ event: NSEvent, surfaceView: Ghostty.SurfaceView) -> Bool {
        guard shared.isEnabled(for: surfaceView) else { return false }

        let mods = event.modifierFlags.intersection([.command, .control])
        guard mods.isEmpty else { return false }

        guard let characters = event.characters,
              let scalar = characters.unicodeScalars.first else { return false }

        // Control chars (Esc, Enter, Tab, Backspace...) and function keys
        // (arrows, F-keys: U+F700 private range) pass through to the terminal.
        guard scalar.value >= 0x20,
              scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value) else { return false }

        // "/" starting a command goes straight to the terminal in a Claude
        // Code tab, so its slash-command menu drives the interaction. Only
        // when it would be the first character — an existing draft means
        // the "/" is part of prose.
        if isSlashHandoff(event, surfaceView: surfaceView) { return false }

        return true
    }
}

/// Runs `action` on mouse-down over its area, via a real AppKit view.
/// SwiftUI Button/onTapGesture inside this hosted hierarchy swallow the
/// first click (they only start responding after an interaction has
/// "warmed up" the hosting view); an NSView's mouseDown always fires,
/// exactly like the terminal and text views that never had the problem.
private struct ClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    class CatcherView: NSView {
        var action: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            action()
        }
    }
}

/// A circular "x" button, claude.ai-style: white circle with a hairline
/// border that darkens while the pointer is over it. Used for removing
/// attachments and closing the image preview. Deliberately no .help
/// tooltip.
private struct HoverCircleButton: View {
    var diameter: CGFloat = 22
    let action: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: diameter * 0.45, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
            .overlay(
                Circle().strokeBorder(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            // The click region is the full frame — the same region
            // .onHover responds to — so clickable and gray-highlight
            // areas match exactly.
            .overlay(ClickCatcher(action: action))
            // The pointer-style system is what governs the cursor here
            // (the terminal surface uses it too); NSCursor.push/cursor
            // rects lose to it.
            .backport.pointerStyle(.link)
            .onHover { inside in
                hovering = inside
                onHoverChange?(inside)
            }
    }
}

/// An attached image in the compose box, claude.ai-style: the remove
/// button only appears while hovering the thumbnail (pointing-hand
/// cursor), as a white circle overlapping the top-left corner that
/// darkens when the pointer is over it. No tooltip.
private struct AttachmentThumbnail: View {
    let image: NSImage
    let size: CGFloat
    let onPreview: () -> Void
    let onRemove: () -> Void

    @State private var hoveringThumbnail = false
    @State private var hoveringRemove = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1))
            .overlay(ClickCatcher(action: onPreview))
            .backport.pointerStyle(.link)
            .onHover { hoveringThumbnail = $0 }
        .overlay(alignment: .topLeading) {
            // The button hangs past the corner, so it keeps its own
            // hover state: leaving the thumbnail's frame for the
            // button must not hide it.
            if hoveringThumbnail || hoveringRemove {
                HoverCircleButton(
                    action: onRemove,
                    onHoverChange: { hoveringRemove = $0 })
                    .offset(x: -8, y: -8)
            }
        }
        .animation(.easeOut(duration: 0.1), value: hoveringThumbnail || hoveringRemove)
    }
}

/// A claude.ai-style compose panel docked to the bottom of the terminal view.
/// Text is edited with full native text view behavior (mouse, selection,
/// multi-line) and delivered to the terminal as a paste, optionally followed
/// by a synthetic Enter to submit.
struct TerminalComposeBoxView: View {
    /// The surface that receives the composed text. Observed so the panel
    /// tracks live cell-size changes (font zoom, config reload).
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view.
    @Binding var isPresented: Bool

    /// Per-surface UI state that must survive this view being torn down
    /// and rebuilt (see ComposeUIState). Holds the open image preview.
    @ObservedObject var uiState: ComposeUIState

    @State private var text: String = ""
    @State private var attachments: [NSImage] = []
    @State private var textHeight: CGFloat = 0

    init(surfaceView: Ghostty.SurfaceView, isPresented: Binding<Bool>) {
        self.surfaceView = surfaceView
        self._isPresented = isPresented
        self.uiState = ComposeUIState.state(for: surfaceView)
    }

    /// Incremented to pull first-responder status back to the text view,
    /// e.g. when typing in the terminal is routed into an already-open box.
    @State private var focusToken: Int = 0

    /// Match the terminal's rendered text size: a cell is one line of the
    /// terminal font, and its point size is ~0.85x the cell height. The
    /// family comes from compose-font-family, defaulting to the system font.
    private var font: NSFont {
        let cellHeight = surfaceView.cellSize.height
        let size = cellHeight > 0 ? cellHeight * 0.85 : 13
        if let family = (NSApp.delegate as? AppDelegate)?.ghostty.config.composeFontFamily {
            if let named = NSFont(name: family, size: size) { return named }
            if let familyFont = NSFontManager.shared.font(
                withFamily: family, traits: [], weight: 5, size: size) {
                return familyFont
            }
        }
        return .systemFont(ofSize: size)
    }

    /// The width of the terminal's text grid (columns x cell width) in
    /// points, so the panel can align with the text column.
    private var terminalTextWidth: CGFloat? {
        guard let surface = surfaceView.surface else { return nil }
        let size = ghostty_surface_size(surface)
        let widthPx = CGFloat(size.columns) * CGFloat(size.cell_width_px)
        let scale = surfaceView.window?.backingScaleFactor ?? 2
        let width = widthPx / scale
        return width > 0 ? width : nil
    }

    /// Minimum height in lines from compose-min-lines; the box grows as
    /// content needs it.
    private var minTextHeight: CGFloat {
        let lines = CGFloat((NSApp.delegate as? AppDelegate)?.ghostty.config.composeMinLines ?? 2)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return lineHeight * lines + ComposeBoxMetrics.textInset.height * 2
    }

    private var thumbnailSize: CGFloat {
        CGFloat((NSApp.delegate as? AppDelegate)?.ghostty.config.composeThumbnailSize ?? 72)
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    let maxTextHeight = max(minTextHeight, geometry.size.height * 0.5)

                    VStack(spacing: 0) {
                        Spacer()

                        VStack(alignment: .leading, spacing: 10) {
                            if !attachments.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(attachments.indices, id: \.self) { i in
                                        AttachmentThumbnail(
                                            image: attachments[i],
                                            size: thumbnailSize,
                                            onPreview: { uiState.previewImage = attachments[i] },
                                            onRemove: {
                                                attachments.remove(at: i)
                                                syncDraft()
                                            })
                                    }
                                    Spacer()
                                }
                            }

                            ComposeTextView(
                                text: $text,
                                height: $textHeight,
                                font: font,
                                focusToken: focusToken,
                                onSend: send(submit:),
                                onDismiss: {
                                    // Esc closes the preview overlay first,
                                    // then the panel.
                                    if uiState.previewImage != nil {
                                        uiState.previewImage = nil
                                    } else {
                                        isPresented = false
                                    }
                                },
                                onPasteImage: { image in
                                    // Images can only be delivered to Claude
                                    // Code; refuse the attachment elsewhere.
                                    guard ComposeAutoPopupStore.titleLooksLikeClaude(surfaceView) else {
                                        NSSound.beep()
                                        return
                                    }
                                    attachments.append(image)
                                    syncDraft()
                                },
                                onInterrupt: sendInterrupt,
                                onCollapsePaste: collapsePaste,
                                onSlashPassthrough: slashPassthrough)
                                .frame(height: min(max(textHeight, minTextHeight), maxTextHeight))
                        }
                        .padding(14)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.separator, lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 14, y: 4)
                        .frame(width: min(
                            terminalTextWidth ?? geometry.size.width,
                            geometry.size.width - 24))
                        .padding(.bottom, 14)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .onAppear {
                    let draft = ComposeDraftStore.shared.draft(for: surfaceView)
                    text = draft.text
                    attachments = draft.images
                }
                .onChange(of: text) { _ in syncDraft() }

                // Full-size preview of a clicked attachment, claude.ai-style:
                // dimmed backdrop, image fit to the surface, circular close
                // button. Backdrop click, the button, or Esc dismisses.
                if let preview = uiState.previewImage {
                    ZStack {
                        Color.black.opacity(0.55)
                            .overlay(ClickCatcher { uiState.previewImage = nil })
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            // Absorb clicks on the image itself so only
                            // the backdrop dismisses.
                            .overlay(ClickCatcher {})
                            .padding(48)
                    }
                    .overlay(alignment: .topTrailing) {
                        HoverCircleButton(diameter: 32) { uiState.previewImage = nil }
                            .padding(16)
                    }
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the panel disappears, return focus to the surface it was
            // overlaid on. Same pattern as the command palette.
            if !newValue {
                uiState.previewImage = nil
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
        // Typing or pasting in the terminal while the box is already open
        // (focus was in the terminal, e.g. after clicking it) routes here:
        // append to the open box and pull focus back into it, instead of
        // the input silently vanishing.
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyComposeAutoPopup)) { notification in
            guard isPresented,
                  let object = notification.object as? Ghostty.SurfaceView,
                  object === surfaceView else { return }
            if let seed = notification.userInfo?[Notification.Name.ghosttyComposeSeedKey] as? String {
                text += ComposeDraftStore.collapsedToken(for: seed, surface: surfaceView) ?? seed
            }
            if let image = notification.userInfo?[Notification.Name.ghosttyComposeSeedImageKey] as? NSImage,
               ComposeAutoPopupStore.titleLooksLikeClaude(surfaceView) {
                attachments.append(image)
            }
            syncDraft()
            focusToken += 1
        }
    }

    /// Decides whether a pasted string collapses to a placeholder
    /// (compose-paste-collapse-lines). Returns the placeholder token to
    /// insert, or nil to paste inline.
    private func collapsePaste(_ string: String) -> String? {
        ComposeDraftStore.collapsedToken(for: string, surface: surfaceView)
    }

    private func syncDraft() {
        let draft = ComposeDraftStore.shared.draft(for: surfaceView)
        draft.text = text
        draft.images = attachments
    }

    /// Ctrl+C pressed in the compose box: forward it straight to the
    /// terminal (e.g. to interrupt a running Claude Code turn) and close
    /// the panel; the draft stays put. Same synthetic-key shape as the
    /// Ctrl+V image delivery: the legacy encoding derives the control
    /// byte (0x03) from the key's codepoint, so both are set.
    private func sendInterrupt() {
        guard let surface = surfaceView.surfaceModel else { return }
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
        isPresented = false
    }

    /// "/" typed into an empty box in a Claude Code tab: the user wants a
    /// slash command, whose completion menu lives in the terminal. Close
    /// the panel and type the "/" there instead. Returns false when the
    /// tab doesn't look like Claude Code so the "/" inserts normally.
    private func slashPassthrough() -> Bool {
        guard ComposeAutoPopupStore.titleLooksLikeClaude(surfaceView),
              let surface = surfaceView.surfaceModel else { return false }
        surface.sendKeyEvent(.init(
            key: .slash,
            action: .press,
            text: "/",
            unshiftedCodepoint: 0x2F))
        surface.sendKeyEvent(.init(
            key: .slash,
            action: .release,
            unshiftedCodepoint: 0x2F))
        // Keep auto-popup suppressed until the slash command is
        // submitted, cancelled, or deleted in the terminal.
        ComposeAutoPopupStore.shared.beginSlashCommand(for: surfaceView)
        isPresented = false
        return true
    }

    private func send(submit: Bool) {
        guard let surface = surfaceView.surfaceModel else { return }
        // Expand collapsed-paste placeholders back to their full text.
        var content = text
        for (token, full) in ComposeDraftStore.shared.draft(for: surfaceView).pastes {
            content = content.replacingOccurrences(of: token, with: full)
        }
        // Ctrl+V image delivery only makes sense into Claude Code; if the
        // session ended since attaching, drop images rather than spray
        // escape sequences at a shell.
        let images = ComposeAutoPopupStore.titleLooksLikeClaude(surfaceView) ? attachments : []
        guard !content.isEmpty || !images.isEmpty else {
            isPresented = false
            return
        }

        // Images are delivered the way Claude Code ingests them: put each on
        // the system clipboard and send Ctrl+V, staggered so it has time to
        // read the clipboard before the next paste replaces it.
        var delay: TimeInterval = 0
        for image in images {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                // The legacy key encoding derives Ctrl+V's control byte
                // (0x16) from the key's codepoint, so both must be set or
                // nothing reaches the pty.
                surface.sendKeyEvent(.init(
                    key: .v,
                    action: .press,
                    text: "\u{16}",
                    mods: .ctrl,
                    unshiftedCodepoint: 0x76))
                surface.sendKeyEvent(.init(
                    key: .v,
                    action: .release,
                    mods: .ctrl,
                    unshiftedCodepoint: 0x76))
            }
            delay += 0.35
        }

        // The core treats surface text input as a paste, so multi-line
        // content arrives as one bracketed-paste block and embedded newlines
        // don't submit. Submission is a separate synthetic Enter.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if !content.isEmpty {
                surface.sendText(content)
            }
            if submit {
                surface.sendKeyEvent(.init(key: .enter, action: .press))
                surface.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }

        text = ""
        attachments = []
        ComposeDraftStore.shared.clear(for: surfaceView)
        isPresented = false
    }
}

private enum ComposeBoxMetrics {
    static let textInset = NSSize(width: 4, height: 6)
}

/// NSTextView wrapper so we get full native editing plus precise control over
/// Enter (newline), Cmd+Enter (send+submit), Cmd+Shift+Enter (send only), and
/// Esc (dismiss). SwiftUI's TextEditor can't intercept these on macOS 13.
private struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont
    var focusToken: Int
    var onSend: (Bool) -> Void
    var onDismiss: () -> Void
    var onPasteImage: (NSImage) -> Void
    var onInterrupt: () -> Void
    var onCollapsePaste: (String) -> String?
    var onSlashPassthrough: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposeNSTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = ComposeBoxMetrics.textInset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onSend = onSend
        textView.onDismiss = onDismiss
        textView.onPasteImage = onPasteImage
        textView.onInterrupt = onInterrupt
        textView.onCollapsePaste = onCollapsePaste
        textView.onSlashPassthrough = onSlashPassthrough

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // Focus the editor as soon as the panel appears.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposeNSTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        textView.onSend = onSend
        textView.onDismiss = onDismiss
        textView.onPasteImage = onPasteImage
        textView.onInterrupt = onInterrupt
        textView.onCollapsePaste = onCollapsePaste
        textView.onSlashPassthrough = onSlashPassthrough
        if textView.font != font {
            textView.font = font
        }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight(for: textView)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        var lastFocusToken: Int = 0

        init(_ parent: ComposeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(for: textView)
        }

        func updateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            DispatchQueue.main.async {
                self.parent.height = used + inset
            }
        }
    }
}

private class ComposeNSTextView: NSTextView {
    var onSend: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?
    var onInterrupt: (() -> Void)?
    var onCollapsePaste: ((String) -> String?)?
    var onSlashPassthrough: (() -> Bool)?

    /// An image on the clipboard becomes an attachment, claude.ai-style;
    /// large text collapses to a "[Pasted text ...]" placeholder; anything
    /// else pastes as text. NSImage(pasteboard:) also reads image files
    /// copied in Finder.
    private func pasteClipboard() {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else {
            if let image = NSImage(pasteboard: pasteboard) {
                onPasteImage?(image)
                return
            }
            super.paste(nil)
            return
        }
        if let token = onCollapsePaste?(string) {
            insertText(token, replacementRange: selectedRange())
            return
        }
        super.paste(nil)
    }

    override func paste(_ sender: Any?) {
        pasteClipboard()
    }

    /// Parses a comma-separated list of Enter combos ("enter",
    /// "cmd+shift+enter", ...) into the modifier sets that trigger it.
    /// Returns nil if any combo is malformed so the caller falls back to
    /// the default rather than half-applying a typo'd config.
    private static func parseEnterCombos(_ spec: String) -> [NSEvent.ModifierFlags]? {
        var combos: [NSEvent.ModifierFlags] = []
        for comboSpec in spec.lowercased().split(separator: ",") {
            var mods: NSEvent.ModifierFlags = []
            var sawEnter = false
            for token in comboSpec.split(separator: "+")
                where !token.trimmingCharacters(in: .whitespaces).isEmpty {
                switch token.trimmingCharacters(in: .whitespaces) {
                case "cmd", "command", "super": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt", "option", "alt": mods.insert(.option)
                case "ctrl", "control": mods.insert(.control)
                case "enter", "return": sawEnter = true
                default: return nil
                }
            }
            guard sawEnter else { return nil }
            combos.append(mods)
        }
        return combos.isEmpty ? nil : combos
    }

    /// What each Enter combo does, from the compose-submit-key /
    /// compose-insert-key / compose-newline-key config options. Defaults:
    /// plain Enter submits, Cmd/Shift/Ctrl+Enter insert a newline,
    /// Cmd+Shift+Enter deposits without submitting.
    private static func enterComboActions() -> (
        submit: [NSEvent.ModifierFlags],
        insert: [NSEvent.ModifierFlags],
        newline: [NSEvent.ModifierFlags]
    ) {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let submit = config?.composeSubmitKey.flatMap(Self.parseEnterCombos)
            ?? [[]]
        let insert = config?.composeInsertKey.flatMap(Self.parseEnterCombos)
            ?? [[.command, .shift]]
        let newline = config?.composeNewlineKey.flatMap(Self.parseEnterCombos)
            ?? [[.command], [.shift], [.control]]
        return (submit, insert, newline)
    }

    /// Handles Enter-key combos per the configured actions. Returns false
    /// for combos bound to nothing, which fall through to default text
    /// view handling.
    private func handleEnterCombo(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 0x24 else { return false }

        let actions = Self.enterComboActions()
        if actions.submit.contains(mods) {
            onSend?(true)
            return true
        }
        if actions.insert.contains(mods) {
            onSend?(false)
            return true
        }
        if actions.newline.contains(mods) {
            // Insert explicitly: combos with cmd/ctrl arrive via the
            // key-equivalent path where super would just beep.
            insertNewline(nil)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        // Non-command insert combos (e.g. opt+enter) arrive here rather
        // than through the key-equivalent path.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if handleEnterCombo(event, mods: mods) { return }

        // "/" as the first character of an empty box hands off to the
        // terminal's slash-command menu (Claude Code tabs only; not during
        // IME composition, where "/" may be part of a composed sequence).
        if event.characters == "/",
           mods.intersection([.command, .control, .option]).isEmpty,
           string.isEmpty,
           !hasMarkedText(),
           onSlashPassthrough?() == true {
            return
        }

        // Ctrl+V pastes too (Claude Code habit for images).
        if event.keyCode == 0x09 && mods == [.control] {
            pasteClipboard()
            return
        }

        // Ctrl+C goes straight through to the terminal so an interrupt
        // doesn't require dismissing the panel first.
        if event.keyCode == 0x08 && mods == [.control] {
            onInterrupt?()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only compare against real modifier keys; keys like backspace can
        // carry incidental flags (e.g. .function) that break exact matches.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if handleEnterCombo(event, mods: mods) {
            return true
        }

        // Cmd+V: Ghostty's Edit > Paste menu item owns this key with a
        // selector we don't implement, which would otherwise swallow the
        // keystroke entirely while the panel is focused. Ctrl+V is handled
        // here too: control chords can be consumed on the key-equivalent
        // path before ever reaching keyDown.
        if event.keyCode == 0x09 && (mods == [.command] || mods == [.control]) {
            pasteClipboard()
            return true
        }

        // Standard macOS text shortcuts that don't reliably reach the text
        // system through the key-equivalent path in this hosting setup.
        if event.keyCode == 0x33 {  // delete (backspace)
            if mods == [.command] {
                deleteToBeginningOfLine(nil)
                return true
            }
            if mods == [.option] {
                deleteWordBackward(nil)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
