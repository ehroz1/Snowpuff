import AppKit
import SwiftUI

/// The first run: a short look at what the snow does, a page of settings, and the snow starts. The same pages as the
/// Windows installer, in the style of snowpuff.ehroz.pro.
final class OnboardingController: NSObject, NSWindowDelegate {
    /// Called once, when the window closes by any means.
    var finished: () -> Void = {}
    private var window: NSWindow?

    func show(model: SettingsModel) {
        let view = OnboardingView(model: model) { [weak self] in self?.window?.close() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.067, green: 0.094, blue: 0.137, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        finished()
    }
}

private struct Slide {
    let title: String
    let body: String
    let picture: NightScene.Picture
}

private let slides = [
    Slide(
        title: "Snowpuff",
        body: tr(
            "Warm snow on your desktop. A quick look at what it does, a few settings, and it's falling in a minute.",
            "Тёплый снег на рабочем столе. Покажем, что он умеет, настроим — и через минуту он пойдёт."
        ),
        picture: .window(cat: .sitting, icicles: false)
    ),
    Slide(
        title: tr("It settles on windows", "Ложится на окна"),
        body: tr(
            "Snow gathers on the edges of windows and on the Dock. Give a window a shake and it slides off.",
            "Снег оседает на краях окон и на Dock. Дёрни окно — и он соскользнёт вниз."
        ),
        picture: .desktop
    ),
    Slide(
        title: tr("It scatters from the cursor", "Разлетается от курсора"),
        body: tr(
            "Sweep the mouse through a drift and it parts. Five kinds of snowfall, from light to a blizzard, plus rain and leaves.",
            "Проведи мышкой по сугробу — снег расступится. Пять видов снегопада, от лёгкого до метели, а ещё дождь и листья."
        ),
        picture: .cursor
    ),
    Slide(
        title: tr("Icicles and warm light", "Сосульки и тёплый свет"),
        body: tr(
            "Icicles grow under windows with snow on them, and the active window glows warm onto the snow, like the one on the icon.",
            "Под окнами со снегом растут сосульки, а активное окно светится тёплым светом, как окно на иконке."
        ),
        picture: .window(cat: .none, icicles: true)
    ),
    Slide(
        title: tr("It listens, and steps aside", "Слушает и не мешает"),
        body: tr(
            "Blow into the microphone and the snow flies; nothing is recorded. On calls, over full-screen apps and on battery it keeps out of the way.",
            "Подуй в микрофон — снег разлетится, ничего не записывается. На созвонах, в полноэкранных приложениях и на батарее он не мешает."
        ),
        picture: .microphone
    ),
]

private struct OnboardingView: View {
    @ObservedObject var model: SettingsModel
    let close: () -> Void
    @State private var page = 0
    @State private var done = false

    private var pages: Int { slides.count + 1 }

    var body: some View {
        ZStack {
            Night.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if done {
                    finale
                } else if page < slides.count {
                    slide(slides[page])
                } else {
                    settings
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(14)
        }
        .frame(width: 620, height: 470)
        .preferredColorScheme(.dark)
        .tint(Night.amber)
        .animation(.easeOut(duration: 0.18), value: page)
        .animation(.easeOut(duration: 0.18), value: done)
    }

    private func slide(_ slide: Slide) -> some View {
        VStack(spacing: 0) {
            NightScene(picture: slide.picture)
                .frame(height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(slide.title)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Night.cream)
                .padding(.top, 22)
            Text(slide.body)
                .font(.system(size: 13.5))
                .foregroundStyle(Night.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 460)
                .padding(.top, 10)
        }
        .transition(.opacity)
    }

    private var finale: some View {
        VStack(spacing: 0) {
            NightScene(picture: .window(cat: .sleeping, icicles: false))
                .frame(height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(tr("Let it settle.", "Пусть ложится."))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Night.cream)
                .padding(.top, 22)
            Text(tr(
                "Snowpuff lives in the menu bar. Everything chosen here, and more, is in its menu and in Settings.",
                "Snowpuff живёт в строке меню. Всё выбранное, и не только, — в его меню и в настройках."
            ))
            .font(.system(size: 13.5))
            .foregroundStyle(Night.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .padding(.top, 10)
        }
        .transition(.opacity)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Make it yours", "Настроим под тебя"))
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Night.cream)
                .padding(.top, 26)
            Text(tr("All of it can be changed later in Settings.", "Всё это можно поменять потом в настройках."))
                .font(.system(size: 12.5))
                .foregroundStyle(Night.muted)
                .padding(.top, 4)
                .padding(.bottom, 14)
            row(tr("Snowfall", "Снегопад")) {
                Picker("", selection: $model.snowfall) {
                    ForEach([Snowfall.light, .steady, .heavy], id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
            }
            row(tr("Sound", "Звук")) {
                Picker("", selection: $model.sound) {
                    Text(tr("Quiet", "Тихо")).tag(Ambience.Mode.off)
                    Text(Ambience.Mode.wind.title).tag(Ambience.Mode.wind)
                    Text(Ambience.Mode.fireplace.title).tag(Ambience.Mode.fireplace)
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
            }
            toggleRow(tr("Icicles under windows with snow", "Сосульки под окнами со снегом"), $model.icicles)
            toggleRow(tr("Hide during calls", "Прятать на созвонах"), $model.quietOnCalls)
            toggleRow(tr("Open at login", "Открывать при входе"), $model.openAtLogin)
            toggleRow(tr("Update automatically", "Обновляться автоматически"), $model.autoUpdate)
        }
        .padding(.horizontal, 34)
        .transition(.opacity)
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Night.ink)
                Spacer()
                control()
            }
            .frame(height: 40)
            Divider().opacity(0.4)
        }
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
        row(title) { Toggle("", isOn: value).toggleStyle(.switch).labelsHidden() }
    }

    private var footer: some View {
        HStack {
            if done {
                Button(tr("More apps — ehroz.pro", "Другие приложения — ehroz.pro")) {
                    if let url = URL(string: "https://ehroz.pro") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(QuietButton())
            } else if page == 0 {
                Button(tr("Skip to settings", "Сразу к настройкам")) { page = slides.count }.buttonStyle(QuietButton())
            } else {
                Button(tr("Back", "Назад")) { page -= 1 }.buttonStyle(QuietButton())
            }
            Spacer()
            if !done {
                HStack(spacing: 8) {
                    ForEach(0..<pages, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Night.amber : Night.muted.opacity(0.6))
                            .frame(width: index == page ? 16 : 6, height: 6)
                            .onTapGesture { page = index }
                    }
                }
            }
            Spacer()
            Button(primaryTitle) {
                if done {
                    close()
                } else if page < slides.count {
                    page += 1
                } else {
                    done = true
                }
            }
            .buttonStyle(AmberButton())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var primaryTitle: String {
        if done { return tr("Let it snow", "Пусть идёт снег") }
        return page < slides.count ? tr("Next", "Далее") : tr("Done", "Готово")
    }
}

/// The flat amber button of the site and the installer.
struct AmberButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Night.label)
            .frame(minWidth: 140)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 6).fill(Night.amber.opacity(configuration.isPressed ? 0.85 : 1)))
            .contentShape(Rectangle())
    }
}

/// A plain text button.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Night.muted.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

/// The night outside the window from the icon, drawn for the onboarding: sky, snow, a snowbank and a picture.
struct NightScene: View {
    enum Cat { case none, sitting, sleeping }
    enum Picture {
        case window(cat: Cat, icicles: Bool)
        case desktop
        case cursor
        case microphone
    }

    let picture: Picture

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let center = width / 2
            let ground = height - 38
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Night.deep, Night.horizon]), startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
            ))
            if case .cursor = picture {} else {
                glow(&context, CGPoint(x: center, y: height * 0.42), CGSize(width: width * 0.42, height: height * 0.62), Night.amber.opacity(0.28))
            }
            for i in 0..<46 {
                let x = 8 + hash(i, 1) * (width - 16)
                let y = 8 + hash(i, 2) * (ground - 12)
                let r = 0.8 + hash(i, 3) * 1.6
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(Night.snow.opacity(0.35 + hash(i, 4) * 0.5)))
            }
            switch picture {
            case .window(let cat, let icicles): litWindow(&context, center: center, top: 40, width: 132, cat: cat, icicles: icicles)
            case .desktop: desktopWindow(&context, center: center, top: 52)
            case .cursor: break
            case .microphone: microphone(&context, center: center, top: 44)
            }
            snowbank(&context, width: width, height: height, ground: ground)
            if case .cursor = picture {
                cursor(&context, x: center + 40, y: ground - 6)
            } else {
                glow(&context, CGPoint(x: center, y: ground + 10), CGSize(width: width * 0.3, height: 16), Night.amber.opacity(0.5))
            }
        }
    }

    private func glow(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGSize, _ color: Color) {
        let rect = CGRect(x: center.x - radius.width, y: center.y - radius.height, width: radius.width * 2, height: radius.height * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: max(radius.width, radius.height)
        ))
    }

    private func snowbank(_ context: inout GraphicsContext, width: CGFloat, height: CGFloat, ground: CGFloat) {
        var bank = Path()
        bank.move(to: CGPoint(x: 0, y: height))
        bank.addLine(to: CGPoint(x: 0, y: ground))
        let dip: Bool = { if case .cursor = picture { true } else { false } }()
        for i in 0...40 {
            let t = CGFloat(i) / 40
            let x = t * width
            var y = ground - 4 * sin(t * 9) - 3 * sin(t * 23 + 1.3)
            if dip {
                let d = (x - (width / 2 + 40)) / 46
                y += 18 * exp(-d * d)
            }
            bank.addLine(to: CGPoint(x: x, y: y))
        }
        bank.addLine(to: CGPoint(x: width, y: height))
        bank.closeSubpath()
        context.fill(bank, with: .color(Color(red: 0.86, green: 0.9, blue: 0.95)))
        context.stroke(bank, with: .color(Night.snow), lineWidth: 2.5)
    }

    private func litWindow(_ context: inout GraphicsContext, center: CGFloat, top: CGFloat, width: CGFloat, cat: Cat, icicles: Bool) {
        let height = width * 0.96
        let left = center - width / 2
        let frame = Color(red: 0.09, green: 0.043, blue: 0.027)
        context.fill(Path(roundedRect: CGRect(x: left, y: top, width: width, height: height), cornerRadius: 9), with: .color(frame))
        let pane = CGRect(x: left + 8, y: top + 8, width: width - 16, height: height - 16)
        context.fill(Path(roundedRect: pane, cornerRadius: 4), with: .radialGradient(
            Gradient(colors: [Color(red: 1, green: 0.96, blue: 0.84), Color(red: 1, green: 0.81, blue: 0.48), Color(red: 0.85, green: 0.5, blue: 0.23)]),
            center: CGPoint(x: center + width * 0.08, y: pane.maxY - height * 0.2), startRadius: 0, endRadius: width * 0.7
        ))
        let curtain = width * 0.22
        let red = Color(red: 0.612, green: 0.227, blue: 0.157)
        var leftCurtain = Path()
        leftCurtain.addLines([CGPoint(x: pane.minX, y: pane.minY), CGPoint(x: pane.minX + curtain, y: pane.minY), CGPoint(x: pane.minX + curtain * 0.7, y: pane.maxY), CGPoint(x: pane.minX, y: pane.maxY)])
        context.fill(leftCurtain, with: .color(red))
        var rightCurtain = Path()
        rightCurtain.addLines([CGPoint(x: pane.maxX, y: pane.minY), CGPoint(x: pane.maxX - curtain, y: pane.minY), CGPoint(x: pane.maxX - curtain * 0.7, y: pane.maxY), CGPoint(x: pane.maxX, y: pane.maxY)])
        context.fill(rightCurtain, with: .color(red))
        // The curtains' stitched hems.
        for (from, to) in [(pane.minX + curtain - 2, pane.minX + curtain * 0.7 - 2), (pane.maxX - curtain + 2, pane.maxX - curtain * 0.7 + 2)] {
            var hem = Path()
            hem.move(to: CGPoint(x: from, y: pane.minY + 3))
            hem.addLine(to: CGPoint(x: to, y: pane.maxY - 3))
            context.stroke(hem, with: .color(Color(red: 1, green: 0.85, blue: 0.63).opacity(0.75)), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2.5]))
        }
        let brown = Color(red: 0.227, green: 0.106, blue: 0.063)
        switch cat {
        case .sitting:
            let x = pane.minX + width * 0.3, y = pane.maxY, s = width / 116
            var body = Path()
            body.addLines([(0, 0), (-1, -17), (4, -23), (2, -32), (7.5, -27), (12.5, -27), (18, -32), (16, -23), (21, -17), (20, 0)].map { CGPoint(x: x + $0.0 * s, y: y + $0.1 * s) })
            context.fill(body, with: .color(brown))
        case .sleeping:
            let x = pane.minX + width * 0.32, y = pane.maxY - 6
            context.fill(Path(ellipseIn: CGRect(x: x - 8, y: y - 8, width: 32, height: 16)), with: .color(brown))
            context.fill(Path(ellipseIn: CGRect(x: x - 13, y: y - 9.5, width: 14, height: 13)), with: .color(brown))
            var ears = Path()
            ears.addLines([CGPoint(x: x - 11, y: y - 6), CGPoint(x: x - 10, y: y - 14), CGPoint(x: x - 6, y: y - 8)])
            ears.addLines([CGPoint(x: x - 4, y: y - 8), CGPoint(x: x - 0.5, y: y - 14), CGPoint(x: x + 0.5, y: y - 6)])
            context.fill(ears, with: .color(brown))
        case .none: break
        }
        // The lamp.
        let lamp = Color(red: 0.42, green: 0.18, blue: 0.11)
        let lx = pane.maxX - width * 0.3, ly = pane.maxY
        glow(&context, CGPoint(x: lx, y: ly - 16), CGSize(width: 16, height: 12), Color(red: 1, green: 0.97, blue: 0.86).opacity(0.8))
        var shade = Path()
        shade.addLines([CGPoint(x: lx - 9, y: ly - 15), CGPoint(x: lx + 9, y: ly - 15), CGPoint(x: lx + 5, y: ly - 27), CGPoint(x: lx - 5, y: ly - 27)])
        context.fill(shade, with: .color(lamp))
        context.fill(Path(CGRect(x: lx - 1.3, y: ly - 15, width: 2.6, height: 11)), with: .color(lamp))
        context.fill(Path(roundedRect: CGRect(x: lx - 6, y: ly - 4, width: 12, height: 4), cornerRadius: 2), with: .color(lamp))
        // Mullions.
        context.fill(Path(CGRect(x: center - 3.5, y: pane.minY, width: 7, height: pane.height)), with: .color(frame))
        context.fill(Path(CGRect(x: pane.minX, y: pane.midY - 7.5, width: pane.width, height: 7)), with: .color(frame))
        // A cap of snow and the sill.
        var cap = Path()
        cap.move(to: CGPoint(x: left - 12, y: top + 6))
        for i in 0...16 {
            let t = CGFloat(i) / 16
            cap.addLine(to: CGPoint(x: left - 12 + t * (width + 24), y: top - 4 - 7 * sin(t * .pi) - 2.5 * abs(sin(t * 19))))
        }
        cap.addLine(to: CGPoint(x: left + width + 12, y: top + 6))
        cap.closeSubpath()
        context.fill(cap, with: .color(Night.snow))
        let sill = CGRect(x: left - 12, y: top + height - 2, width: width + 24, height: 11)
        context.fill(Path(roundedRect: sill, cornerRadius: 3), with: .color(Night.snow))
        if icicles {
            let lengths: [CGFloat] = [14, 8, 26, 11, 34, 7, 20, 12, 24]
            for (i, length) in lengths.enumerated() {
                let x = sill.minX + 10 + CGFloat(i) * (sill.width - 20) / CGFloat(lengths.count - 1)
                var icicle = Path()
                icicle.addLines([CGPoint(x: x - 3.5, y: sill.maxY - 1), CGPoint(x: x + 3.5, y: sill.maxY - 1), CGPoint(x: x, y: sill.maxY + length)])
                context.fill(icicle, with: .color(Color(red: 0.92, green: 0.95, blue: 0.99).opacity(0.9)))
            }
        }
    }

    private func desktopWindow(_ context: inout GraphicsContext, center: CGFloat, top: CGFloat) {
        let width: CGFloat = 230
        let left = center - width / 2
        let window = CGRect(x: left, y: top, width: width, height: 116)
        context.fill(Path(roundedRect: window, cornerRadius: 9), with: .color(Color(red: 0.937, green: 0.902, blue: 0.847)))
        context.fill(Path(roundedRect: CGRect(x: left, y: top, width: width, height: 24), cornerRadii: RectangleCornerRadii(topLeading: 9, topTrailing: 9)), with: .color(Color(red: 0.886, green: 0.839, blue: 0.765)))
        for (i, color) in [Color(red: 0.83, green: 0.38, blue: 0.29), Color(red: 0.89, green: 0.66, blue: 0.25), Color(red: 0.5, green: 0.68, blue: 0.36)].enumerated() {
            context.fill(Path(ellipseIn: CGRect(x: left + 10 + CGFloat(i) * 13, y: top + 8, width: 8, height: 8)), with: .color(color))
        }
        for (i, length) in [150.0, 120.0, 170.0].enumerated() {
            context.fill(Path(roundedRect: CGRect(x: left + 20, y: top + 44 + CGFloat(i) * 20, width: length, height: 6), cornerRadius: 3), with: .color(Color(red: 0.36, green: 0.29, blue: 0.24).opacity(0.35)))
        }
        var cap = Path()
        cap.move(to: CGPoint(x: left + 2, y: top + 2))
        for i in 0...18 {
            let t = CGFloat(i) / 18
            cap.addLine(to: CGPoint(x: left + 2 + t * (width - 4), y: top - 3 - 6 * pow(sin(t * .pi), 0.6) - 2 * abs(sin(t * 21))))
        }
        cap.addLine(to: CGPoint(x: window.maxX - 2, y: top + 2))
        cap.closeSubpath()
        context.fill(cap, with: .color(Night.snow))
        for (dx, dy, r) in [(10.0, 18.0, 3.0), (16, 34, 2.2), (8, 46, 1.8), (20, 58, 1.4)] as [(CGFloat, CGFloat, CGFloat)] {
            context.fill(Path(ellipseIn: CGRect(x: window.maxX + dx - r, y: top + dy - r, width: 2 * r, height: 2 * r)), with: .color(Night.snow))
        }
    }

    private func microphone(_ context: inout GraphicsContext, center: CGFloat, top: CGFloat) {
        let x = center - 60
        context.fill(Path(roundedRect: CGRect(x: x - 16, y: top, width: 32, height: 64), cornerRadius: 16), with: .color(Night.amber))
        for i in 0..<4 {
            var grille = Path()
            let y = top + 18 + CGFloat(i) * 9
            grille.move(to: CGPoint(x: x - 9, y: y))
            grille.addLine(to: CGPoint(x: x + 9, y: y))
            context.stroke(grille, with: .color(Night.label.opacity(0.35)), lineWidth: 1.5)
        }
        var stand = Path()
        stand.addArc(center: CGPoint(x: x, y: top + 38), radius: 26, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        stand.move(to: CGPoint(x: x, y: top + 64))
        stand.addLine(to: CGPoint(x: x, y: top + 86))
        stand.move(to: CGPoint(x: x - 14, y: top + 86))
        stand.addLine(to: CGPoint(x: x + 14, y: top + 86))
        context.stroke(stand, with: .color(Night.amber), lineWidth: 3)
        for (i, (dy, length)) in [(-10.0, 70.0), (6, 96), (22, 62)].enumerated() {
            var breath = Path()
            let y = top + 32 + dy
            breath.move(to: CGPoint(x: x + 40, y: y))
            breath.addLine(to: CGPoint(x: x + 40 + length, y: y - 6 + CGFloat(i) * 3))
            context.stroke(breath, with: .color(Night.snow.opacity(0.55)), lineWidth: 2)
        }
        for i in 0..<14 {
            let r = 1.4 + hash(i, 13) * 2
            let point = CGPoint(x: x + 120 + hash(i, 11) * 80, y: top + 10 + hash(i, 12) * 60)
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(Night.snow))
        }
    }

    private func cursor(_ context: inout GraphicsContext, x: CGFloat, y: CGFloat) {
        for i in 0..<22 {
            let angle = -0.3 - hash(i, 7) * 2.5
            let reach = 20 + hash(i, 8) * 70
            let r = 1 + hash(i, 9) * 2
            let point = CGPoint(x: x + cos(angle) * reach, y: y + sin(angle) * reach * 0.8)
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(Night.snow.opacity(0.9)))
        }
        let arrow: [(CGFloat, CGFloat)] = [(0, 0), (0, 26), (7, 20), (12, 31), (16.5, 29), (11.5, 18.5), (20, 18.5)]
        var pointer = Path()
        pointer.addLines(arrow.map { CGPoint(x: x - 2 + $0.0, y: y - 30 + $0.1) })
        pointer.closeSubpath()
        context.fill(pointer, with: .color(Night.snow))
        context.stroke(pointer, with: .color(Color(red: 0.05, green: 0.07, blue: 0.1)), lineWidth: 1.5)
    }

    /// A steady pseudo-random number in [0, 1) for `i`, different for each `salt`.
    private func hash(_ i: Int, _ salt: UInt32) -> CGFloat {
        var x = UInt32(truncatingIfNeeded: i) &* 0x9E37_79B9 ^ salt &* 0x85EB_CA6B
        x ^= x >> 15
        x = x &* 0x2C1B_3C6D
        x ^= x >> 12
        return CGFloat(x % 10_000) / 10_000
    }
}
