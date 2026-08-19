import AppKit
import SevenCitiesCore

/// The screen a session starts on: the classic map, or a world made fresh.
///
/// Deliberately plain AppKit. The C64-styled frame, palette and charset are the
/// next chunk of work and they depend on glyphs that have to be extracted from
/// the user's own disk first; this needs neither, and holding the whole flow
/// hostage to the charset would have meant nothing runnable until both were
/// done. Expect it to be restyled once the shell exists.
@MainActor
final class NewGameView: NSView {

    /// What the player picked. `.classic` is a request to load `historical.map`;
    /// `.random` already carries the finished world, because generating it is
    /// what the progress bar was for.
    enum Choice {
        case classic
        case random(WorldMaker.World)
    }

    var onChoice: ((Choice) -> Void)?
    var onImportDisks: (() -> Void)?

    private let classicButton = NSButton()
    private let randomButton = NSButton()
    private let note = NSTextField(labelWithString: "")
    private let importButton = NSButton()
    private let bar = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let choices = NSStackView()
    private let progressStack = NSStackView()

    /// The last step shown, so the bar can only ever move forward.
    ///
    /// Progress arrives from the generator's thread and is hopped to the main
    /// actor to be drawn, and unstructured tasks carry no ordering guarantee
    /// between them — nineteen of them land inside about a second and a half,
    /// so two arriving out of order is not hypothetical. A bar that jumps
    /// backwards reads as a bug in the generator, which is the one thing here
    /// that is known to be correct.
    private var shownStep = 0
    private var shownAttempt = 0

    /// - Parameter haveClassicMap: whether `historical.map` has been extracted.
    ///   Without it the classic map cannot be offered, and the way out is to
    ///   import disk images rather than to pick something else.
    init(haveClassicMap: Bool) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: "Seven Cities of Gold")
        title.font = .systemFont(ofSize: 34, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Choose a world to explore")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        configure(classicButton, title: "Classic Map",
                  subtitle: "North & South America, as the original shipped it",
                  action: #selector(pickClassic))
        classicButton.isEnabled = haveClassicMap

        configure(randomButton, title: "Random World",
                  subtitle: "A fresh world from the original's World Maker",
                  action: #selector(pickRandom))

        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.isHidden = haveClassicMap
        note.stringValue = "The classic map needs your own disk images — no game data ships with this app."

        importButton.title = "Import Disk Images…"
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importDisks)
        importButton.isHidden = haveClassicMap

        choices.orientation = .vertical
        choices.spacing = 14
        choices.alignment = .centerX
        for view in [title, subtitle, classicButton, randomButton, note, importButton] {
            choices.addArrangedSubview(view)
        }
        choices.setCustomSpacing(4, after: title)
        choices.setCustomSpacing(28, after: subtitle)

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .regular

        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .center

        progressStack.orientation = .vertical
        progressStack.spacing = 12
        progressStack.alignment = .centerX
        let building = NSTextField(labelWithString: "Building a world…")
        building.font = .systemFont(ofSize: 18, weight: .medium)
        for view in [building, bar, status] { progressStack.addArrangedSubview(view) }
        progressStack.isHidden = true

        for stack in [choices, progressStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 360),
            classicButton.widthAnchor.constraint(equalToConstant: 360),
            randomButton.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirty.fill()
    }

    private func configure(_ button: NSButton, title: String, subtitle: String,
                           action: Selector) {
        let text = NSMutableAttributedString(
            string: title + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        text.append(NSAttributedString(
            string: subtitle,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        text.addAttribute(.paragraphStyle, value: centered,
                          range: NSRange(location: 0, length: text.length))
        button.attributedTitle = text
        button.bezelStyle = .regularSquare
        button.target = self
        button.action = action
    }

    // MARK: - Choices

    @objc private func pickClassic() { onChoice?(.classic) }

    @objc private func importDisks() { onImportDisks?() }

    @objc private func pickRandom() {
        choices.isHidden = true
        progressStack.isHidden = false
        shownStep = 0
        shownAttempt = 0
        bar.doubleValue = 0
        status.stringValue = "Landmasses"

        // Off the main thread: a world is 1.2 to 2.2 seconds in a debug build,
        // which is long enough that generating it in place freezes the window
        // and the bar never draws at all.
        let handler: WorldMaker.ProgressHandler = { progress in
            Task { @MainActor [weak self] in self?.show(progress) }
        }
        Task.detached(priority: .userInitiated) {
            do {
                let world = try WorldMaker.randomWorld(progress: handler)
                await MainActor.run { [weak self] in self?.onChoice?(.random(world)) }
            } catch {
                await MainActor.run { [weak self] in self?.failed(error) }
            }
        }
    }

    private func show(_ progress: WorldMaker.Progress) {
        // A new attempt starts the count over, so it is the one case where the
        // step going down is real rather than a race.
        if progress.attempt != shownAttempt {
            shownAttempt = progress.attempt
            shownStep = 0
        } else if progress.step <= shownStep {
            return
        }
        shownStep = progress.step
        bar.doubleValue = progress.fraction
        status.stringValue = progress.attempt > 1
            ? "\(progress.label)  (attempt \(progress.attempt))"
            : progress.label
    }

    private func failed(_ error: Error) {
        progressStack.isHidden = true
        choices.isHidden = false
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not build a world"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}
