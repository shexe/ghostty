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

        return true
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

    @State private var text: String = ""
    @State private var attachments: [NSImage] = []
    @State private var textHeight: CGFloat = 0

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
                                        Image(nsImage: attachments[i])
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: thumbnailSize, height: thumbnailSize)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(.separator, lineWidth: 1))
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    attachments.remove(at: i)
                                                    syncDraft()
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.secondary)
                                                        .background(Circle().fill(.background))
                                                }
                                                .buttonStyle(.plain)
                                                .padding(3)
                                            }
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
                                onDismiss: { isPresented = false },
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
                                onCollapsePaste: collapsePaste)
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
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the panel disappears, return focus to the surface it was
            // overlaid on. Same pattern as the command palette.
            if !newValue {
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
