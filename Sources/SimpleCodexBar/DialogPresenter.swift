import AppKit
import SwiftUI
import Observation
import CodexUsageCore

/// Consistent, non-modal native panels: no NSAlert accessory sizing or nested modal run loops.
@MainActor
final class DialogPresenter: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private let language: LanguageController
    private var didClose: (() -> Void)?
    private var currentTitle: (@MainActor () -> String)?
    private var titleObservationGeneration: UInt = 0

    init(language: LanguageController) {
        self.language = language
        super.init()
    }

    func rename(_ account: Account, onSave: @escaping (String) -> Void) {
        present(title: { [language] in language.text("dialog.rename", table: "Dialogs") },
                view: RenameDialog(account: account, language: language,
            cancel: { [weak self] in self?.dismiss() },
            save: { [weak self] name in self?.dismiss(); onSave(name) }))
    }

    func confirmRemoval(_ account: Account, onConfirm: @escaping () -> Void) {
        let detail = LocalizedText(account.isManaged ? "dialog.removeManagedDetail" : "dialog.removeLinkedDetail", table: "Dialogs")
        present(title: { [language] in language.text("dialog.remove", table: "Dialogs") },
                view: MessageDialog(language: language,
            title: { [language] in language.text("dialog.removeAccount", account.displayName(in: language.language), table: "Dialogs") },
            detail: { [language] in language.resolve(detail) },
            confirmTitle: LocalizedText("dialog.removeAction", table: "Dialogs"), destructive: true,
            cancel: { [weak self] in self?.dismiss() },
            confirm: { [weak self] in self?.dismiss(); onConfirm() }))
    }

    func message(title: LocalizedText, detail: LocalizedText, onClose: @escaping () -> Void = {}) {
        present(title: { [language] in language.resolve(title) },
                view: MessageDialog(language: language,
            title: { [language] in language.resolve(title) }, detail: { [language] in language.resolve(detail) },
            confirmTitle: LocalizedText("dialog.close", table: "Dialogs"), destructive: false, cancel: nil,
            confirm: { [weak self] in self?.dismiss() }), onClose: onClose)
    }

    func dismiss() {
        stopTitleObservation()
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            stopTitleObservation()
            window = nil
            let action = didClose; didClose = nil
            action?()
        }
    }

    private func stopTitleObservation() {
        titleObservationGeneration &+= 1
        currentTitle = nil
    }

    private func observeTitle(generation: UInt) {
        guard generation == titleObservationGeneration, let window, let currentTitle else { return }
        withObservationTracking {
            // The same hosted view remains alive, preserving its text field and focus state.
            _ = language.language
            window.title = currentTitle()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.titleObservationGeneration else { return }
                self.observeTitle(generation: generation)
            }
        }
    }

    private func present<V: View>(title: @escaping @MainActor () -> String, view: V, onClose: (() -> Void)? = nil) {
        dismiss()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 408, height: 240),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .normal
        panel.delegate = self
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(host.view.fittingSize)
        panel.center()
        window = panel
        currentTitle = title
        didClose = onClose
        observeTitle(generation: titleObservationGeneration)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct RenameDialog: View {
    let account: Account
    let language: LanguageController
    let cancel: () -> Void
    let save: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(account: Account, language: LanguageController, cancel: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.account = account; self.language = language; self.cancel = cancel; self.save = save
        _name = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("dialog.renameHeading", table: "Dialogs")).font(.headline)
                .accessibilityIdentifier("dialog-title")
            Text(account.identity.email ?? account.displayName(in: language.language)).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            TextField(language.text("dialog.renamePlaceholder", table: "Dialogs"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("account-name-field")
                .onSubmit { save(name) }
            Text(language.text("dialog.renameDetail", table: "Dialogs"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(language.text("dialog.cancel", table: "Dialogs"), action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dialog-cancel")
                Button(language.text("dialog.save", table: "Dialogs")) { save(name) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dialog-confirm")
            }
        }
        .frame(width: 360, alignment: .leading).padding(24).background(Color(nsColor: .windowBackgroundColor))
        .task { await Task.yield(); focused = true }
    }
}

private struct MessageDialog: View {
    let language: LanguageController
    let title: @MainActor () -> String
    let detail: @MainActor () -> String
    let confirmTitle: LocalizedText
    let destructive: Bool
    let cancel: (() -> Void)?
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title(), systemImage: destructive ? "trash" : "exclamationmark.circle")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dialog-title")
            Text(detail()).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dialog-detail")
            HStack {
                Spacer()
                if let cancel {
                    Button(language.text("dialog.cancel", table: "Dialogs"), action: cancel).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("dialog-cancel")
                }
                Button(language.resolve(confirmTitle), action: confirm).buttonStyle(.borderedProminent)
                    .tint(destructive ? .red : .accentColor).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dialog-confirm")
            }
        }
        .frame(width: 360, alignment: .leading).padding(24).background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { (cancel ?? confirm)() }
    }
}
