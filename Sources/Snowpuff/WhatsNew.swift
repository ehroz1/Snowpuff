import AppKit

/// "What's New": shown once after Snowpuff updates itself, and from the menu any time.
final class WhatsNewController: NSObject, NSWindowDelegate {
    /// The news of each version, newest first.
    static let notes: [(version: String, english: [String], russian: [String])] = [
        ("1.3.1", [
            "Cherry Blossom and Hail join Snow, Autumn Leaves and Rain under Mode. Add Rain mixes rain into any of them.",
            "Real weather: Weather Outside makes it snow, rain or hail as it does where you are.",
            "Frost patterns grow in from the screen's edges, and in rain the glass mists over. Hold Option and draw on it.",
            "Hold Option with the cursor on a drift to build a snowman. Option-click throws a snowball.",
            "A cat peeks out of the drifts now and then, and a bullfinch lands on your windows.",
            "Stars and meteors at night, fog along the bottom, fairy lights on your windows, a swirl behind a fast cursor.",
            "Sounds: rain on the glass, hail, snow crunching under the cursor, icicles ringing when you click them.",
            "Type \"snow\" anywhere for a flurry (turn it on in Settings).",
            "A New Year countdown in the menu.",
            "Settings gathers the options; Opacity fades what falls; Accumulate picks the ground, the Dock and windows.",
            "Snow on Selection: drag a selection across the desktop and the snow settles on it.",
            "Battery Saver, Report a Problem, and this window after every update.",
        ], [
            "В меню «Режим» к снегу, листьям и дождю добавились «Цветущая сакура» и «Град». «Добавить дождь» подмешивает дождь к любому режиму.",
            "Настоящая погода: «Погода за окном» включает снег, дождь или град, как сейчас у тебя на улице.",
            "С краёв экрана растут морозные узоры, а в дождь стекло запотевает. Зажми ⌥ и рисуй по ним курсором.",
            "Зажми ⌥ и подержи курсор на сугробе — слепится снеговик. ⌥ + клик бросает снежок.",
            "Иногда из сугроба выглядывает кот, а на окна садится снегирь.",
            "Ночью звёзды и падающие метеоры, туман по низу экрана, гирлянда на окнах и вихрь за быстрым курсором.",
            "Звуки: дождь по стеклу, град, хруст снега под курсором и звон сосулек, если по ним кликнуть.",
            "Напиши «снег» или «snow» где угодно — пойдёт густой снегопад (включается в настройках).",
            "В меню отсчёт до Нового года.",
            "Параметры собраны в «Настройках». «Прозрачность» приглушает падающее, «Сугробы» выбирают землю, Dock и окна.",
            "«Снег на рамке выделения»: потяни рамку на рабочем столе, и снег ляжет на неё.",
            "Экономия батареи, «Сообщить о проблеме» и это окно после каждого обновления.",
        ]),
    ]

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let width: CGFloat = 470
        let version = Updater.version
        let entry = Self.notes.first { $0.version == version } ?? Self.notes[0]
        let items = speaksRussian ? entry.russian : entry.english

        let cocoa = NSColor(srgbRed: 0.17, green: 0.12, blue: 0.1, alpha: 1)
        let cream = NSColor(srgbRed: 0.98, green: 0.93, blue: 0.85, alpha: 1)
        let glow = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.49, alpha: 1)

        let body = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.headIndent = 16
        paragraph.firstLineHeadIndent = 0
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        for item in items {
            body.append(NSAttributedString(string: "❄\t", attributes: [.foregroundColor: glow, .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph]))
            body.append(NSAttributedString(string: item + "\n", attributes: [.foregroundColor: cream, .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph]))
        }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 64, height: 10))
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textStorage?.setAttributedString(body)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let textHeight = min(text.layoutManager?.usedRect(for: text.textContainer!).height ?? 300, 380)

        let scroll = NSScrollView(frame: NSRect(x: 32, y: 70, width: width - 64, height: textHeight + 4))
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = textHeight >= 380
        text.frame.size.height = text.layoutManager?.usedRect(for: text.textContainer!).height ?? textHeight

        let height = textHeight + 190
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = cocoa.cgColor

        let icon = NSImageView(frame: NSRect(x: (width - 64) / 2, y: height - 84, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        let title = NSTextField(labelWithString: tr("What's New in Snowpuff \(version)", "Что нового в Snowpuff \(version)"))
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        title.textColor = cream
        title.alignment = .center
        title.frame = NSRect(x: 20, y: height - 120, width: width - 40, height: 26)

        let button = NSButton(title: tr("Lovely", "Отлично"), target: self, action: #selector(close))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: (width - 140) / 2, y: 22, width: 140, height: 32)

        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(scroll)
        content.addSubview(button)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = cocoa
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
