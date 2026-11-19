import AppKit
import SwiftUI

/// Snowpuff's settings, everything the menu has and what is too rarely changed to sit in it.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = tr("Snowpuff Settings", "Настройки Snowpuff")
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsFile.scheduleSave()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            snow.tabItem { Label(tr("Snow", "Снег"), systemImage: "snowflake") }
            magic.tabItem { Label(tr("Magic", "Волшебство"), systemImage: "sparkles") }
            sound.tabItem { Label(tr("Sound", "Звук"), systemImage: "speaker.wave.2") }
            system.tabItem { Label(tr("System", "Система"), systemImage: "gearshape") }
            AboutView().tabItem { Label(tr("About", "О Snowpuff"), systemImage: "info.circle") }
        }
        .tint(Night.amber)
        .frame(width: 560, height: 520)
    }

    private var snow: some View {
        Form {
            Section {
                Picker(tr("Snowfall", "Снегопад"), selection: $model.snowfall) {
                    ForEach(Snowfall.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(tr("Mode", "Режим"), selection: $model.mode) {
                    ForEach(SnowMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.liveWeather)
                Toggle(tr("Add rain", "Добавить дождь"), isOn: $model.mixRain)
                    .disabled(!model.mode.piles || model.liveWeather)
                Toggle(isOn: $model.liveWeather) {
                    SettingLabel(
                        title: tr("Weather outside", "Погода за окном"),
                        hint: tr("Snow, rain or hail as it is where you are, from open-meteo.com.", "Снег, дождь или град — как сейчас у тебя на улице, по данным open-meteo.com.")
                    )
                }
                HStack {
                    Text(tr("Opacity of what falls", "Прозрачность падающего"))
                    Slider(value: $model.opacity, in: 0.15...1)
                }
            }
            Section {
                Toggle(isOn: $model.accumulate) {
                    SettingLabel(title: tr("Accumulate", "Сугробы"), hint: tr("Snow piles up at the bottom of the screen.", "Снег копится внизу экрана."))
                }
                .disabled(model.mode == .rain)
                Toggle(isOn: $model.melt) {
                    SettingLabel(title: tr("Melt", "Таяние"), hint: tr("Drifts slowly thaw and never bury the screen.", "Сугробы медленно оттаивают и не заваливают экран."))
                }
                .disabled(!model.accumulate || model.mode == .rain)
                Toggle(tr("Snow on windows", "Снег на окнах"), isOn: $model.snowOnWindows)
                    .disabled(model.behindWindows)
                Toggle(tr("Snow on the Dock", "Снег на Dock"), isOn: $model.snowOnDock)
                    .disabled(!model.snowOnWindows || model.behindWindows)
                Toggle(isOn: $model.deepInteraction) {
                    SettingLabel(title: tr("Snow on a selection", "Снег на рамке выделения"), hint: tr("Drag a selection on the desktop and the snow settles on it.", "Потяни рамку на рабочем столе — снег ляжет на неё."))
                }
                .disabled(!model.snowOnWindows)
                Toggle(isOn: $model.icicles) {
                    SettingLabel(title: tr("Icicles", "Сосульки"), hint: tr("Grow under windows with snow; a shake breaks them off.", "Растут под окнами со снегом; если дёрнуть окно, слетают."))
                }
                .disabled(!model.snowOnWindows || model.mode != .snow)
                Toggle(isOn: $model.warmGlow) {
                    SettingLabel(title: tr("Warm window light", "Тёплый свет окна"), hint: tr("The active window glows onto the snow.", "Активное окно светится тёплым светом."))
                }
            }
            Section {
                HStack {
                    Text(tr("Too much snow?", "Слишком много снега?"))
                    Spacer()
                    Button(tr("Clear Snow", "Смести весь снег")) { model.controls?.clearSnow() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var magic: some View {
        Form {
            Section {
                Toggle(isOn: $model.frost) {
                    SettingLabel(title: tr("Frost patterns and misted glass", "Морозные узоры и запотевшее стекло"), hint: tr("Hold ⌥ and move the cursor to draw on them.", "Зажми ⌥ и води курсором, чтобы рисовать по ним."))
                }
                Toggle(isOn: $model.garland) {
                    SettingLabel(title: tr("Garland on windows", "Гирлянда на окнах"), hint: tr("Fairy lights along the tops of your windows.", "Огоньки вдоль верха окон."))
                }
                Toggle(isOn: $model.stars) {
                    SettingLabel(title: tr("Starry sky", "Звёздное небо"), hint: tr("Stars and meteors over the desktop at night.", "Ночью над рабочим столом звёзды и метеоры."))
                }
                Toggle(tr("Fog", "Туман"), isOn: $model.fog)
                Toggle(tr("Swirl behind the cursor", "Метель за курсором"), isOn: $model.blizzard)
                Toggle(isOn: $model.creatures) {
                    SettingLabel(title: tr("Cat and bullfinch", "Кот и снегирь"), hint: tr("A cat peeks out of the drifts; a bullfinch lands on windows.", "Из сугроба выглядывает кот, на окна садится снегирь."))
                }
            }
            Section {
                Toggle(isOn: $model.words) {
                    SettingLabel(
                        title: tr("Typing \"snow\" brings a flurry", "Слово «снег» вызывает снегопад"),
                        hint: tr("Only the keys of \"snow\" and \"снег\" are watched; nothing typed is kept.", "Отслеживаются только клавиши слов «snow» и «снег»; набранное не сохраняется.")
                    )
                }
                Toggle(isOn: $model.hotkeys) {
                    SettingLabel(
                        title: tr("Shortcuts ⌃⌥ + letter", "Горячие клавиши ⌃⌥ + буква"),
                        hint: tr("S snow · M mode · N snowman · B snowball · C clear · F frost · G garland · H help", "S снег · M режим · N снеговик · B снежок · C смести · F иней · G гирлянда · H подсказка")
                    )
                }
                HStack {
                    Spacer()
                    Button(tr("How to Use…", "Как пользоваться…")) { model.controls?.openHelp() }
                }
                SettingLabel(
                    title: tr("Snowmen and snowballs", "Снеговики и снежки"),
                    hint: tr("Hold ⌥ with the cursor low on the screen for a second, or press ⌃⌥N; ⌥-click or ⌃⌥B throws a snowball.", "Зажми ⌥ и подержи курсор внизу экрана секунду или нажми ⌃⌥N; ⌥ + клик или ⌃⌥B бросает снежок.")
                )
            }
        }
        .formStyle(.grouped)
    }

    private var sound: some View {
        Form {
            Section {
                Picker(tr("Sound", "Звук"), selection: $model.sound) {
                    ForEach(Ambience.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Text(tr("Volume", "Громкость"))
                    Slider(value: $model.volume, in: 0.05...1)
                }
                .disabled(model.sound == .off)
            }
            Section {
                Toggle(isOn: $model.puff) {
                    SettingLabel(
                        title: tr("Blow on the snow", "Подуть на снег"),
                        hint: tr("Uses the microphone only to notice a breath. Nothing is recorded.", "Микрофон нужен только чтобы заметить дуновение. Ничего не записывается.")
                    )
                }
                Toggle(isOn: $model.soundEffects) {
                    SettingLabel(title: tr("Sound effects", "Звуки эффектов"), hint: tr("Rain on the glass, hail, snow crunching, icicles ringing.", "Дождь по стеклу, град, хруст снега, звон сосулек."))
                }
                Toggle(isOn: $model.quietOnCalls) {
                    SettingLabel(
                        title: tr("Hide during calls", "Прятать на созвонах"),
                        hint: tr("When another app uses the camera or microphone, the snow and its sound fade away.", "Когда другое приложение включает камеру или микрофон, снег и звук плавно исчезают.")
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var system: some View {
        Form {
            Section {
                Toggle(tr("Open at login", "Открывать при входе"), isOn: $model.openAtLogin)
                Toggle(isOn: $model.autoUpdate) {
                    SettingLabel(title: tr("Update automatically", "Обновлять автоматически"), hint: tr("New versions install themselves and Snowpuff reopens; never during a call.", "Новые версии ставятся сами, Snowpuff перезапускается; во время созвона — нет."))
                }
                HStack {
                    Text("Snowpuff \(Updater.version)")
                    Spacer()
                    Button(tr("Check for Updates…", "Проверить обновления…")) { model.controls?.checkForUpdates() }
                }
            }
            Section {
                Toggle(tr("Behind windows", "За окнами"), isOn: $model.behindWindows)
                Toggle(tr("Show over full-screen apps", "Поверх полноэкранных приложений"), isOn: $model.overFullScreen)
                    .disabled(model.behindWindows)
                Toggle(tr("Show in screenshots", "Показывать на скриншотах"), isOn: $model.showInScreenshots)
                Toggle(isOn: $model.batterySaver) {
                    SettingLabel(title: tr("Battery saver", "Экономить батарею"), hint: tr("On battery, a little less snow drawn a little less often.", "От батареи снега чуть меньше, и рисуется он реже."))
                }
                Picker(tr("Performance", "Производительность"), selection: $model.maxPerformance) {
                    Text(tr("Default", "Обычная")).tag(false)
                    Text(tr("Max", "Максимальная")).tag(true)
                }
            }
            Section {
                HStack {
                    SettingLabel(
                        title: tr("Settings file", "Файл настроек"),
                        hint: tr("Stays when the app is removed; installed again, Snowpuff picks it up.", "Остаётся, если удалить приложение; при новой установке Snowpuff подхватит его сам.")
                    )
                    Spacer()
                    Button(tr("Show in Finder", "Показать в Finder")) {
                        SettingsFile.save()
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsFile.url])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Snowpuff").font(.system(size: 26, weight: .semibold))
            Text(tr("Version \(Updater.version)", "Версия \(Updater.version)")).foregroundStyle(.secondary)
            Text(tr("Warm snow on your desktop.", "Тёплый снег на рабочем столе."))
            VStack(spacing: 8) {
                link(tr("Website — snowpuff.ehroz.pro", "Сайт — snowpuff.ehroz.pro"), "https://snowpuff.ehroz.pro")
                link(tr("More apps — ehroz.pro", "Другие приложения — ehroz.pro"), "https://ehroz.pro")
                link(tr("Source on GitHub", "Исходники на GitHub"), "https://github.com/\(Updater.repository)")
                link(tr("Support the author ♥", "Поддержать автора ♥"), "https://t.me/hhrrzz1")
                Button(tr("What's New", "Что нового")) { (NSApp.delegate as? SnowControls)?.openWhatsNew() }.buttonStyle(.link)
                Button(tr("Report a Problem…", "Сообщить о проблеме…")) { (NSApp.delegate as? SnowControls)?.reportProblem() }.buttonStyle(.link)
            }
            .padding(.top, 6)
            Spacer()
            Text(tr("Based on Snowhush by Mykhailo Bezruchko (MIT).", "Основан на Snowhush Михаила Безручко (MIT)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func link(_ title: String, _ address: String) -> some View {
        Button(title) {
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.link)
    }
}
