//
//  CopyButton.swift
//  JSONExport
//
//  Small button that copies text to the pasteboard and briefly confirms it with "Copied".
//

import Cocoa

class CopyButton: NSButton {

    //Returns the text to copy when the button is clicked
    var textProvider: (() -> String?)?

    private let idleTitle: String
    private var feedbackToken = 0

    init(title: String) {
        idleTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .rounded
        controlSize = .small
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        imagePosition = .imageLeading
        target = self
        action = #selector(copyText(_:))
        showIdleState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func copyText(_ sender: Any?) {
        guard let text = textProvider?(), !text.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopiedState()
    }

    private func showIdleState() {
        title = idleTitle
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        contentTintColor = nil
    }

    private func showCopiedState() {
        feedbackToken += 1
        let token = feedbackToken
        title = "Copied"
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        contentTintColor = NSColor.systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.feedbackToken == token else { return }
            self.showIdleState()
        }
    }
}
