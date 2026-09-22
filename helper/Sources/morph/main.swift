import Foundation
import MorphCore

let usage = """
    Usage: morph [--json] [--verbose] [--direct] <command>

      pair [--country SE] [--email you@example.com] [--serial ABC-EU-...]
                          Get the lamp key from the Dyson account (one time)
      pair-begin | pair-complete | pair-save
                          The same pairing in three steps without prompts, for the
                          Raycast extension. The secrets arrive as JSON on stdin.
      scan [seconds]      List the nearby Bluetooth LE devices that have a name
      status [--fresh]    Show the lamp state. --fresh reads the lamp, and not the
                          live copy of the background process.
      watch               Show the state, then each change, until Ctrl-C
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
      daemon [--idle 60]  Keep the lamp connection open between commands, and stop
                          after this number of idle seconds (or SOLARMORPH_IDLE).
                          The lamp commands start it themselves. --direct, or
                          SOLARMORPH_DIRECT=1, does not use it.
      daemon stop         Stop the daemon and free the lamp
      daemon status       Show if the daemon is active
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

let json = takeFlag("--json")
let verbose = takeFlag("--verbose")
let direct = takeFlag("--direct") || ProcessInfo.processInfo.environment["SOLARMORPH_DIRECT"] == "1"

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

/// Run a lamp command: through the daemon, or with a connection of its own.
@MainActor
func runLampCommand(_ command: LampCommand, _ args: [String]) async throws {
    let started = Date()
    let log: (String) -> Void = { message in
        guard verbose else { return }
        FileHandle.standardError.write(Data(String(format: "  %5.2f s  %@\n", Date().timeIntervalSince(started), message).utf8))
    }

    if !direct {
        if let state = try await DaemonClient.run(args) {
            log("Done through the daemon. Its log is \(DaemonPaths.log)")
            show(state)
            return
        }
        log("The daemon did not start. Using a direct connection.")
    } else if DaemonClient.isRunning {
        // The lamp ignores a second session, so a direct connection needs the session of the daemon.
        if (try? await DaemonClient.stop()) == true { log("Stopped the daemon, which held the lamp session.") }
    }

    var config = try MorphConfig.load()
    let lamp = Lamp()
    lamp.log = log
    try await lamp.powerOn()
    let id = try await lamp.connect(
        serial: config.serial, accountId: config.accountId, ltkHex: config.ltk, cachedId: config.peripheralId)
    if id != config.peripheralId {
        config.peripheralId = id
        try? config.save()
    }
    do {
        show(try await command.run(on: lamp))
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

    try await storeKey(cloud, serial: serial!, token: token, accountId: accountId)
    // The key is a device credential, so do not print it.
    print("Stored the key for \(serial!) in \(MorphConfig.url.path).")
}

func storeKey(_ cloud: DysonCloud, serial: String, token: String, accountId: String) async throws {
    let ltk = try await cloud.fetchLtk(serial: serial, token: token)
    // The Bluetooth identifier stays correct when the same lamp is paired again.
    let known = try? MorphConfig.load()
    let peripheralId = known?.serial == serial ? known?.peripheralId : nil
    try MorphConfig(serial: serial, accountId: accountId, ltk: ltk, peripheralId: peripheralId).save()
}

// The pairing steps for the Raycast extension. The password, the one-time code
// and the token arrive on stdin, because other processes can read an argument list.

struct PairCompleteInput: Decodable {
    let country, email, password, challengeId, otpCode: String
}

struct PairSaveInput: Decodable {
    let country, token, accountId, serial: String
}

struct PairLight: Encodable {
    let serial, name: String
}

struct PairSession: Encodable {
    let token, accountId: String
    let lights: [PairLight]
}

func readInput<T: Decodable>(_ type: T.Type) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: FileHandle.standardInput.readDataToEndOfFile())
    } catch {
        throw MorphError.usage("This command needs its input as JSON on stdin.")
    }
}

@MainActor
func run() async throws {
    guard let command = arguments.first else { throw MorphError.usage(usage) }
    arguments.removeFirst()

    switch command {
    case "pair":
        try await pair()

    case "pair-begin":
        guard let country = try takeOption("--country"), let email = try takeOption("--email") else {
            throw MorphError.usage("pair-begin needs --country and --email.")
        }
        emit(["challengeId": try await DysonCloud(country: country).beginLogin(email: email)])

    case "pair-complete":
        let input = try readInput(PairCompleteInput.self)
        let cloud = DysonCloud(country: input.country)
        let (token, accountId) = try await cloud.completeLogin(
            email: input.email, password: input.password, challengeId: input.challengeId, otpCode: input.otpCode)
        let lights = try await cloud.devices(token: token).filter(\.isBluetoothLight)
        emit(PairSession(token: token, accountId: accountId, lights: lights.map { PairLight(serial: $0.serial, name: $0.name) }))

    case "pair-save":
        let input = try readInput(PairSaveInput.self)
        try await storeKey(DysonCloud(country: input.country), serial: input.serial, token: input.token, accountId: input.accountId)
        emit(["serial": input.serial])

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

    case _ where LampCommand.names.contains(command):
        // Parse before the connection, so that a usage error is immediate.
        let args = [command] + arguments
        try await runLampCommand(try LampCommand(arguments: args), args)

    case "watch":
        guard !direct else { throw MorphError.usage("watch needs the background process, so it does not work with --direct.") }
        let asJson = json
        try await DaemonClient.watch { reply in
            // Write each line immediately. `print` keeps lines in a buffer when stdout is a pipe.
            let line: String
            if asJson {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = reply.state.flatMap { try? encoder.encode($0) }
                    ?? (try? encoder.encode(["error": reply.error ?? "Unknown error", "code": reply.code ?? ""]))
                line = String(data: data ?? Data("{}".utf8), encoding: .utf8)!
            } else if let state = reply.state {
                func flag(_ on: Bool?) -> String { on.map { $0 ? "on" : "off" } ?? "?" }
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                line = "\(time)  power \(flag(state.power))  \(state.lumens) lm  \(state.kelvin) K  "
                    + "auto \(flag(state.autoBrightness))  movement \(flag(state.movement))  "
                    + "daylight \(flag(state.daylight))  preset \(state.preset?.rawValue ?? "none")"
            } else {
                line = reply.error ?? "Unknown error"
            }
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

    case "daemon":
        switch arguments.first {
        case "stop":
            let stopped = try await DaemonClient.stop()
            if json { emit(["stopped": stopped]) } else { print(stopped ? "Stopped the daemon." : "No daemon was active.") }
        case "status":
            let active = DaemonClient.isRunning
            if json { emit(["active": active]) } else { print(active ? "The daemon is active." : "The daemon is not active.") }
        default:
            let environment = ProcessInfo.processInfo.environment["SOLARMORPH_IDLE"]
            let idle = try (takeOption("--idle") ?? environment).flatMap(Double.init) ?? 60
            try await DaemonServer.run(idle: idle)
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
        var reply = ["error": message]
        if case .notPaired? = error as? MorphError { reply["code"] = "notPaired" }
        emit(reply)
    }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
