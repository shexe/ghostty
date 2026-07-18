import SwiftUI
import AppKit
import GhosttyKit

/// Stores in-progress compose box drafts per surface so a draft survives the
/// panel being closed or the surface losing focus. Keys are held weakly so
/// entries disappear with their surface.
class ComposeDraftStore {
    static let shared = ComposeDraftStore()

    private let drafts = NSMapTable<Ghostty.SurfaceView, NSString>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    func draft(for surface: Ghostty.SurfaceView) -> String {
        drafts.object(forKey: surface) as String? ?? ""
    }

    func setDraft(_ text: String, for surface: Ghostty.SurfaceView) {
        if text.isEmpty {
            drafts.removeObject(forKey: surface)
        } else {
            drafts.setObject(text as NSString, forKey: surface)
        }
    }
}

extension Notification.Name {
    /// Key in ghosttyComposeAutoPopup userInfo carrying the keystroke text
    /// that triggered the popup, so it seeds the draft.
    static let ghosttyComposeSeedKey = "com.mitchellh.ghostty.composeSeed"
}

/// Per-surface auto-popup state: whether plain typing in the terminal should
/// open the compose box. Off by default; toggled per surface via the
/// "Auto-Open Compose Box" menu item / toggle_compose_auto_popup keybind.
class ComposeAutoPopupStore {
    static let shared = ComposeAutoPopupStore()

    private let overrides = NSMapTable<Ghostty.SurfaceView, NSNumber>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    func isEnabled(for surface: Ghostty.SurfaceView) -> Bool {
        overrides.object(forKey: surface)?.boolValue ?? false
    }

    func setOverride(_ enabled: Bool, for surface: Ghostty.SurfaceView) {
        overrides.setObject(NSNumber(value: enabled), forKey: surface)
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
    @State private var textHeight: CGFloat = 0

    /// Match the terminal's rendered text size: a cell is one line of the
    /// terminal font, and its point size is ~0.85x the cell height.
    private var font: NSFont {
        let cellHeight = surfaceView.cellSize.height
        return .systemFont(ofSize: cellHeight > 0 ? cellHeight * 0.85 : 13)
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

    /// Minimum height fits about three lines, like claude.ai's composer.
    private var minTextHeight: CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return lineHeight * 3 + ComposeBoxMetrics.textInset.height * 2
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    let maxTextHeight = max(minTextHeight, geometry.size.height * 0.5)

                    VStack(spacing: 0) {
                        Spacer()

                        ComposeTextView(
                            text: $text,
                            height: $textHeight,
                            font: font,
                            onSend: send(submit:),
                            onDismiss: { isPresented = false })
                            .frame(height: min(max(textHeight, minTextHeight), maxTextHeight))
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
                    text = ComposeDraftStore.shared.draft(for: surfaceView)
                }
                .onChange(of: text) { newValue in
                    ComposeDraftStore.shared.setDraft(newValue, for: surfaceView)
                }
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
    }

    private func send(submit: Bool) {
        guard let surface = surfaceView.surfaceModel else { return }
        let content = text
        guard !content.isEmpty else {
            isPresented = false
            return
        }

        // The core treats surface text input as a paste, so multi-line
        // content arrives as one bracketed-paste block and embedded newlines
        // don't submit. Submission is a separate synthetic Enter.
        surface.sendText(content)
        if submit {
            surface.sendKeyEvent(.init(key: .enter, action: .press))
            surface.sendKeyEvent(.init(key: .enter, action: .release))
        }

        text = ""
        ComposeDraftStore.shared.setDraft("", for: surfaceView)
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
    var onSend: (Bool) -> Void
    var onDismiss: () -> Void

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
        textView.onSend = onSend
        textView.onDismiss = onDismiss
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only compare against real modifier keys; keys like backspace can
        // carry incidental flags (e.g. .function) that break exact matches.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Return key with Command held: send. Shift additionally held means
        // deposit the text without submitting.
        if event.keyCode == 0x24 && mods.contains(.command) {
            onSend?(!mods.contains(.shift))
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
