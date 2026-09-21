import Foundation

/// The merge of one notification into a known state. The daemon keeps the state
/// current with these, so that `status` needs no round trip to the lamp.
extension LampState {
    /// - Returns: true when the value changed the state.
    mutating func apply(characteristic uuid: String, value: Data) -> Bool {
        let before = self
        switch uuid {
        case CharUUID.power:
            if let byte = value.first { power = byte != 0 }
        case CharUUID.brightnessLm:
            if let word = readLE16(value) {
                lumens = word
                brightness = lumensToPercent(word)
            }
        case CharUUID.colorTemp:
            if let word = readLE16(value) { kelvin = word }
        case CharUUID.autoBrightness:
            if let byte = value.first { autoBrightness = byte != 0 }
        case CharUUID.movement:
            if let byte = value.first { movement = byte != 0 }
        default:
            break
        }
        return self != before
    }

    /// - Returns: true when the value changed the state.
    mutating func apply(attribute: UInt16, value: Data) -> Bool {
        guard let byte = value.first else { return false }
        let before = self
        if attribute == Attribute.daylight {
            daylight = byte != 0
        } else if let named = Preset.allCases.first(where: { $0.attribute == attribute }) {
            // The lamp reports the old preset as off when a new one starts, in any sequence.
            if byte != 0 {
                preset = named
            } else if preset == named {
                preset = nil
            }
        }
        return self != before
    }

    /// The characteristics that hold the state and that can notify.
    static let liveCharacteristics = [
        CharUUID.power, CharUUID.brightnessLm, CharUUID.colorTemp, CharUUID.autoBrightness, CharUUID.movement,
    ]
}
