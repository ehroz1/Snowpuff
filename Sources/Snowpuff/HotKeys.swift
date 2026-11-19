import AppKit
import Carbon.HIToolbox

/// Control-Option and a letter, anywhere: snow on and off, the next mode, a snowman, a snowball, clear, frost, the
/// garland, and How to Use. Carbon's hot keys need no permission and see no other typing.
final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case snow = 1, mode, snowman, snowball, clear, frost, garland, help

        var key: Int {
            switch self {
            case .snow: kVK_ANSI_S
            case .mode: kVK_ANSI_M
            case .snowman: kVK_ANSI_N
            case .snowball: kVK_ANSI_B
            case .clear: kVK_ANSI_C
            case .frost: kVK_ANSI_F
            case .garland: kVK_ANSI_G
            case .help: kVK_ANSI_H
            }
        }
    }

    private static var handler: ((Action) -> Void)?
    private static var installed = false
    private var references: [EventHotKeyRef] = []

    init(_ handler: @escaping (Action) -> Void) {
        Self.handler = handler
    }

    func start() {
        guard references.isEmpty else { return }
        if !Self.installed {
            Self.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                if let action = HotKeys.Action(rawValue: id.id) {
                    DispatchQueue.main.async { HotKeys.handler?(action) }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E_5046), id: action.rawValue)
            // Another app may hold the same keys; Snowpuff's others still work.
            if RegisterEventHotKey(UInt32(action.key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference) == noErr, let reference {
                references.append(reference)
            }
        }
        NSLog("Snowpuff: \(references.count) of \(Action.allCases.count) shortcuts registered")
        // For a look from outside: defaults read app.snowpuff.Snowpuff shortcutsRegistered
        UserDefaults.standard.set(references.count, forKey: "shortcutsRegistered")
    }

    func stop() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }
}
