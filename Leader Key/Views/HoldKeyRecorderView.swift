import AppKit
import Defaults
import SwiftUI

struct HoldKeyRecorderView: NSViewRepresentable {
    func makeNSView(context: Context) -> HoldKeyRecorderNSView {
        HoldKeyRecorderNSView()
    }

    func updateNSView(_ nsView: HoldKeyRecorderNSView, context: Context) {
        nsView.refresh()
    }
}

class HoldKeyRecorderNSView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var isRecording = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.title = ""
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear key")
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearKey)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),

            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        refresh()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let handled = KeyCapture.handle(
            event: event,
            onSet: { displayString in
                guard let displayString = displayString, !displayString.isEmpty else {
                    self.clearKey()
                    return
                }
                Defaults[.holdToStickyKeyCode] = Int(event.keyCode)
                Defaults[.holdToStickyKeyDisplay] = displayString
                self.isRecording = false
                self.refresh()
            },
            onCancel: {
                self.isRecording = false
                self.refresh()
            },
            onClear: {
                self.clearKey()
            })

        if !handled {
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refresh()
        return super.resignFirstResponder()
    }

    @objc private func clearKey() {
        Defaults[.holdToStickyKeyCode] = -1
        Defaults[.holdToStickyKeyDisplay] = ""
        isRecording = false
        refresh()
    }

    func refresh() {
        let display = Defaults[.holdToStickyKeyDisplay]
        let hasKey = Defaults[.holdToStickyKeyCode] >= 0 && !display.isEmpty

        if isRecording {
            label.stringValue = "Press a key..."
            label.textColor = .secondaryLabelColor
        } else if hasKey {
            label.stringValue = display
            label.textColor = .labelColor
        } else {
            label.stringValue = "Record Key..."
            label.textColor = .tertiaryLabelColor
        }

        clearButton.isHidden = !hasKey || isRecording

        layer?.borderColor = isRecording
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
    }
}
