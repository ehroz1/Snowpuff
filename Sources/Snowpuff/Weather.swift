import Foundation

/// What falls, picked under Mode in the menu.
enum Weather: Int, CaseIterable {
    case snow, leaves, petals, rain, hail

    var title: String {
        switch self {
        case .snow: tr("Snow", "Снег")
        case .leaves: tr("Autumn Leaves", "Осенние листья")
        case .petals: tr("Cherry Blossom", "Цветущая сакура")
        case .rain: tr("Rain", "Дождь")
        case .hail: tr("Hail", "Град")
        }
    }

    /// Leaves and petals fall the way leaves do.
    var isLeafy: Bool { self == .leaves || self == .petals }
    /// Snow, leaves and petals pile up; rain and hail don't.
    var piles: Bool { self == .snow || isLeafy }
    /// The kind for the shared core's extras.
    var core: UInt8 { UInt8(rawValue) }
}
