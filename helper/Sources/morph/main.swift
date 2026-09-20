import Foundation
import MorphCore

let usage = """
    Usage: morph [--json] [--verbose] <command>

      pair [--country SE] [--email you@example.com] [--serial ABC-EU-...]
                          Get the lamp key from the Dyson account (one time)
      scan [seconds]      List the nearby Bluetooth LE devices that have a name
      status              Show the lamp state
      on | off | toggle   Switch the lamp
      set [options]       Change one or more settings in one connection
          --power on|off
          --brightness 0-100      percent of the 100-1000 lm range
          --lumens 100-1000
          --kelvin 2700-6500
          --auto on|off           auto brightness
          --movement on|off       movement mode
          --daylight on|off       daylight tracking
          --preset study|relax|precision|none
    """

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor
func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

@MainActor
func takeOption(_ name: String) throws -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { throw MorphError.usage("\(name) needs a value.") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func onOff(_ value: String, _ name: String) throws -> Bool {
    switch value.lowercased() {
    case "on", "1", "true": return true
    case "off", "0", "false": return false
    default: throw MorphError.usage("\(name) needs `on` or `off`.")
    }
}

func integer(_ value: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
    guard let number = Int(value), range.contains(number) else {
        throw MorphError.usage("\(name) needs a number from \(range.lowerBound) to \(range.upperBound).")
    }
    return number
}

let json = takeFlag("--json")
let verbose = takeFlag("--verbose")

@MainActor
func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(data: (try? encoder.encode(value)) ?? Data("{}".utf8), encoding: .utf8)!)
}

@MainActor
func show(_ state: LampState) {
    if json {
        emit(state)
        return
    }
    func flag(_ on: Bool?) -> String { on.map { $0 ? "on" : "off" } ?? "unknown" }
    print("""
        Power:           \(flag(state.power))
        Brightness:      \(state.brightness) % (\(state.lumens) lm)
        Colour temp:     \(state.kelvin) K
        Auto brightness: \(flag(state.autoBrightness))
        Movement mode:   \(flag(state.movement))
        Daylight:        \(flag(state.daylight))
        Preset:          \(state.preset?.rawValue ?? "none")
        """)
}

func prompt(_ question: String) -> String {
    print(question, terminator: "")
    return (readLine() ?? "").trimmingCharacters(in: .whitespaces)
}

/// Connect, run `body`, then show the state and disconnect.
@MainActor
func withLamp(attributes: Bool = true, _ body: (Lamp) async throws -> Void) async throws {
    var config = try MorphConfig.load()
    let lamp = Lamp()
    let started = Date()
    if verbose {
        lamp.log = { FileHandle.standardError.write(Data(String(format: "  %5.2f s  %@\n", Date().timeIntervalSince(started), $0).utf8)) }
    }

    try await lamp.powerOn()
    let id = try await lamp.connect(
        serial: config.serial, accountId: config.accountId, ltkHex: config.ltk, cachedId: config.peripheralId)
    if id != config.peripheralId {
        config.peripheralId = id
        try? config.save()
    }
    do {
        try await body(lamp)
        show(try await lamp.readState(attributes: attributes))
    } catch {
        await lamp.disconnect()
        throw error
    }
    await lamp.disconnect()
}

@MainActor
func pair() async throws {
    let country = try takeOption("--country") ?? { let c = prompt("Country code [SE]: "); return c.isEmpty ? "SE" : c }()
    let email = try takeOption("--email") ?? prompt("Dyson account email: ")
    let password = getpass("Dyson account password: ").map { String(cString: $0) } ?? ""
    guard !password.isEmpty, !email.isEmpty else {
        throw MorphError.usage("Pairing needs the email and the password of the Dyson account.")
    }
    let requested = try takeOption("--serial")?.uppercased()

    let cloud = DysonCloud(country: country)
    print("Requesting a one-time code…")
    let challengeId = try await cloud.beginLogin(email: email)
    let code = prompt("Code from the Dyson email: ")
    let (token, accountId) = try await cloud.completeLogin(email: email, password: password, challengeId: challengeId, otpCode: code)

    var serial = requested
    if serial == nil {
        let lights = try await cloud.devices(token: token).filter(\.isBluetoothLight)
        switch lights.count {
        case 0:
            throw MorphError.cloud("The account has no Bluetooth light. Add the lamp in the MyDyson app first.")
        case 1:
            serial = lights[0].serial
            print("Found \(lights[0].name) (\(lights[0].serial))")
        default:
            for (index, light) in lights.enumerated() { print("  \(index + 1). \(light.name) (\(light.serial))") }
            guard let choice = Int(prompt("Which lamp? ")), lights.indices.contains(choice - 1) else {
                throw MorphError.usage("Not a valid choice.")
            }
            serial = lights[choice - 1].serial
        }
    }

    let ltk = try await cloud.fetchLtk(serial: serial!, token: token)
    try MorphConfig(serial: serial!, accountId: accountId, ltk: ltk).save()
    // The key is a device credential, so do not print it.
    print("Stored the key for \(serial!) in \(MorphConfig.url.path).")
}

@MainActor
func run() async throws {
    guard let command = arguments.first else { throw MorphError.usage(usage) }
    arguments.removeFirst()

    switch command {
    case "pair":
        try await pair()

    case "scan":
        let seconds = Double(arguments.first ?? "") ?? 5
        let lamp = Lamp()
        try await lamp.powerOn()
        let found = try await lamp.scan(seconds: seconds)
        if json {
            emit(found)
        } else {
            for device in found {
                print("\(device.rssi) dBm  \(device.name)  \(device.id)  \(device.services.joined(separator: ","))")
            }
        }

    case "status":
        try await withLamp { _ in }

    case "on", "off":
        try await withLamp(attributes: false) { try await $0.setPower(command == "on") }

    case "toggle":
        try await withLamp(attributes: false) { try await $0.togglePower() }

    case "set":
        let power = try takeOption("--power").map { try onOff($0, "--power") }
        let percent = try takeOption("--brightness").map { try integer($0, "--brightness", 0...100) }
        let lumens = try takeOption("--lumens").map { try integer($0, "--lumens", Limits.lumens) }
        let kelvin = try takeOption("--kelvin").map { try integer($0, "--kelvin", Limits.kelvin) }
        let auto = try takeOption("--auto").map { try onOff($0, "--auto") }
        let movement = try takeOption("--movement").map { try onOff($0, "--movement") }
        let daylight = try takeOption("--daylight").map { try onOff($0, "--daylight") }
        let presetName = try takeOption("--preset")?.lowercased()
        if let presetName, presetName != "none", Preset(rawValue: presetName) == nil {
            throw MorphError.usage("--preset needs study, relax, precision, or none.")
        }
        guard arguments.isEmpty else { throw MorphError.usage("Unknown option: \(arguments[0])") }

        try await withLamp { lamp in
            if let power { try await lamp.setPower(power) }
            if let auto { try await lamp.setAutoBrightness(auto) }
            if let movement { try await lamp.setMovement(movement) }
            // A preset and daylight mode set brightness and colour temperature,
            // and a manual value ends them. Thus the manual values go last.
            if let daylight { try await lamp.setDaylight(daylight) }
            if let presetName { try await lamp.setPreset(Preset(rawValue: presetName)) }
            if let target = lumens ?? percent.map(percentToLumens) { try await lamp.setLumens(target) }
            if let kelvin { try await lamp.setKelvin(kelvin) }
            // The lamp ramps to a new value. Give it a moment before the read.
            try await Task.sleep(nanoseconds: 400_000_000)
        }

    case "help", "--help", "-h":
        print(usage)

    default:
        throw MorphError.usage("Unknown command: \(command)\n\n\(usage)")
    }
}

do {
    try await run()
} catch {
    let message = (error as? MorphError)?.description ?? error.localizedDescription
    if json {
        emit(["error": message])
    }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
