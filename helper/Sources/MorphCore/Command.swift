import Foundation

/// One lamp command, parsed from the argument list: `status`, `on`, `off`,
/// `toggle`, or `set` with its options.
///
/// The direct mode and the daemon use the same parser, so a command behaves
/// the same in the two modes.
public struct LampCommand {
    public enum Power { case on, off, toggle }
    public enum PresetChange { case activate(Preset), clear }

    public var power: Power?
    public var lumens: Int?
    public var kelvin: Int?
    public var autoBrightness: Bool?
    public var movement: Bool?
    public var daylight: Bool?
    public var preset: PresetChange?
    /// on/off/toggle skip the attribute channel. Each question there is a paced round trip.
    public var readsAttributes = true

    public static let names: Set<String> = ["status", "on", "off", "toggle", "set"]

    public init(arguments: [String]) throws {
        var options = arguments
        guard let name = options.first else { throw MorphError.usage("No command.") }
        options.removeFirst()

        switch name {
        case "status":
            break
        case "on", "off", "toggle":
            power = name == "on" ? .on : name == "off" ? .off : .toggle
            readsAttributes = false
        case "set":
            func take(_ option: String) throws -> String? {
                guard let index = options.firstIndex(of: option) else { return nil }
                guard index + 1 < options.count else { throw MorphError.usage("\(option) needs a value.") }
                let value = options[index + 1]
                options.removeSubrange(index...index + 1)
                return value
            }
            power = try take("--power").map { try Self.onOff($0, "--power") ? .on : .off }
            let percent = try take("--brightness").map { try Self.integer($0, "--brightness", 0...100) }
            lumens = try take("--lumens").map { try Self.integer($0, "--lumens", Limits.lumens) } ?? percent.map(percentToLumens)
            kelvin = try take("--kelvin").map { try Self.integer($0, "--kelvin", Limits.kelvin) }
            autoBrightness = try take("--auto").map { try Self.onOff($0, "--auto") }
            movement = try take("--movement").map { try Self.onOff($0, "--movement") }
            daylight = try take("--daylight").map { try Self.onOff($0, "--daylight") }
            if let presetName = try take("--preset")?.lowercased() {
                if presetName == "none" {
                    preset = .clear
                } else if let named = Preset(rawValue: presetName) {
                    preset = .activate(named)
                } else {
                    throw MorphError.usage("--preset needs study, relax, precision, or none.")
                }
            }
        default:
            throw MorphError.usage("Unknown command: \(name)")
        }
        guard options.isEmpty else { throw MorphError.usage("Unknown option: \(options[0])") }
    }

    /// Apply the command to a connected lamp, then read the state.
    public func run(on lamp: Lamp) async throws -> LampState {
        switch power {
        case .on: try await lamp.setPower(true)
        case .off: try await lamp.setPower(false)
        case .toggle: try await lamp.togglePower()
        case nil: break
        }
        if let autoBrightness { try await lamp.setAutoBrightness(autoBrightness) }
        if let movement { try await lamp.setMovement(movement) }
        // A preset and daylight mode set brightness and colour temperature,
        // and a manual value ends them. Thus the manual values go last.
        if let daylight { try await lamp.setDaylight(daylight) }
        switch preset {
        case .activate(let named): try await lamp.setPreset(named)
        case .clear: try await lamp.setPreset(nil)
        case nil: break
        }
        if let lumens { try await lamp.setLumens(lumens) }
        if let kelvin { try await lamp.setKelvin(kelvin) }
        if lumens != nil || kelvin != nil || daylight != nil || preset != nil {
            // The lamp ramps to a new value. Give it a moment before the read.
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        return try await lamp.readState(attributes: readsAttributes)
    }

    static func onOff(_ value: String, _ name: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "1", "true": return true
        case "off", "0", "false": return false
        default: throw MorphError.usage("\(name) needs `on` or `off`.")
        }
    }

    static func integer(_ value: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let number = Int(value), range.contains(number) else {
            throw MorphError.usage("\(name) needs a number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }
}
