import AppKit

/// "What's New": shown once after Snowpuff updates itself, and from the menu any time.
final class WhatsNewController: NSObject, NSWindowDelegate {
    /// The news of each version, newest first.
    static let notes: [(version: String, english: [String], russian: [String])] = [
        ("1.4.0", [
            "Snowpuff now has everything from Snowhush 0.14: snow that falls into your wallpaper and lies on what is in it, and snowball fights with friends (Snowball Fight in the menu).",
            "A Christmas tree and fireworks for the New Year, ghosts and pumpkins at Halloween.",
            "Mixed: two kinds fall together, snow with leaves or rain with petals. Autumn leaves and cherry blossom are drawn from real ones.",
            "Intensity and Opacity are sliders now; Accumulate picks the ground, the Dock, widgets, windows, a selection and the wallpaper.",
            "Snow follows a window dragged to another display. The menus speak nine languages.",
            "Snowpuff's own stay: icicles, the warm window glow, frost to draw on, the garland, stars, fog, the cat and the bullfinch, hail, Weather Outside, sounds, blowing on the snow and hiding during calls, now under Settings › Magic and Sound.",
            "Snowpuff is now under the PolyForm Noncommercial license, as Snowhush is.",
        ], [
            "В Snowpuff теперь всё из Snowhush 0.14: снег падает в обои и ложится на то, что на них нарисовано, и снежки с друзьями (пункт «Снежки» в меню).",
            "Ёлка и салют на Новый год, привидения и тыквы на Хеллоуин.",
            "«Смешанный» режим: падают сразу два вида — снег с листьями или дождь с лепестками. Листья и сакура нарисованы по настоящим.",
            "Интенсивность и непрозрачность — ползунки; «Накопление» выбирает землю, Dock, виджеты, окна, рамку выделения и обои.",
            "Снег переезжает вместе с окном на другой монитор. Меню на девяти языках.",
            "Всё своё у Snowpuff осталось: сосульки, тёплый свет окна, морозные узоры, гирлянда, звёзды, туман, кот и снегирь, град, «Погода за окном», звуки, «Подуть на снег» и «Прятать на созвонах» — теперь в «Настройки → Волшебство» и «Звук».",
            "Snowpuff теперь под некоммерческой лицензией PolyForm Noncommercial, как и Snowhush.",
        ]),
        ("1.3.2", [
            "Shortcuts anywhere: ⌃⌥N builds a snowman at the cursor, ⌃⌥B throws a snowball, ⌃⌥S turns the snow on and off, ⌃⌥M changes the mode. ⌃⌥H shows them all.",
            "Snowmen are easier: hold ⌥ with the cursor low on the screen for a second, drift or no drift.",
            "How to Use, in the menu.",
        ], [
            "Горячие клавиши где угодно: ⌃⌥N — снеговик у курсора, ⌃⌥B — снежок, ⌃⌥S — снег вкл/выкл, ⌃⌥M — сменить режим. ⌃⌥H покажет все.",
            "Снеговика слепить проще: зажми ⌥ и подержи курсор внизу экрана секунду — даже без сугроба.",
            "В меню появилось «Как пользоваться».",
        ]),
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

    /// How to use it: the mouse with Option, and the shortcuts.
    static let help: (english: [String], russian: [String]) = ([
        "Hold ⌥ and move the cursor near an edge: draw on the frost or misted glass.",
        "Click an icicle: it falls with a ring. Flick the mouse fast: a swirl of snow follows it.",
        "Snowball Fight in the menu: invite a friend with a link, or join theirs; throw at the snowmen in the wallpaper.",
        "Drag a window and its snow slides off; shake it and the icicles break.",
        "⌃⌥S — snow on / off   ·   ⌃⌥M — the next mode   ·   ⌃⌥C — clear the snow",
        "⌃⌥F — frost   ·   ⌃⌥G — garland   ·   ⌃⌥H — this window",
        "The shortcuts can be turned off in Settings › Magic.",
    ], [
        "Зажми ⌥ и веди курсором у края экрана — рисуешь по инею или запотевшему стеклу.",
        "Клик по сосульке — она падает со звоном. Быстро махни мышью — за курсором закружится метель.",
        "«Снежки» в меню: позови друга ссылкой или зайди по его ссылке и бросай снежки в снеговиков на обоях.",
        "Потяни окно — снег с него соскользнёт; потряси — сосульки оборвутся.",
        "⌃⌥S — снег вкл / выкл   ·   ⌃⌥M — следующий режим   ·   ⌃⌥C — смести снег",
        "⌃⌥F — иней   ·   ⌃⌥G — гирлянда   ·   ⌃⌥H — это окно",
        "Клавиши можно выключить: Настройки → Волшебство.",
    ])

    private var window: NSWindow?

    /// What's New.
    func show() {
        let entry = Self.notes.first { $0.version == Updater.version } ?? Self.notes[0]
        present(title: tr("What's New in Snowpuff \(Updater.version)", "Что нового в Snowpuff \(Updater.version)"), items: speaksRussian ? entry.russian : entry.english)
    }

    /// How to Use.
    func showHelp() {
        present(title: tr("How to Use Snowpuff", "Как пользоваться Snowpuff"), items: speaksRussian ? Self.help.russian : Self.help.english)
    }

    private func present(title heading: String, items: [String]) {
        window?.close()
        let width: CGFloat = 500

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
        let title = NSTextField(labelWithString: heading)
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
