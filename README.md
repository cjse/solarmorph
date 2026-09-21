# Solarmorph

Control a Dyson Solarcycle Morph desk lamp from a Mac: a Raycast extension, and
the `morph` command-line tool that it uses.

The lamp has Bluetooth LE only and no Wi-Fi. Dyson has no desktop app, and the
other open-source implementations need Linux. Solarmorph talks to the lamp
directly through CoreBluetooth. After a one-time pairing, all control is local.

This project is not affiliated with Dyson. See [Risks](#risks-and-limits).

## What it does

Raycast commands:

| Command | What it does |
| --- | --- |
| Lamp Controls | Shows the lamp state. Changes brightness, colour temperature, the three modes (daylight tracking, auto brightness, movement), and the three presets (Study, Relax, Precision). |
| Toggle Lamp, Turn Lamp on, Turn Lamp off | Switch the lamp without a window. |
| Set Lamp Brightness | Takes a percentage, 0–100. Also switches the lamp on. |
| Set Lamp Colour Temperature | Takes a value in Kelvin, 2700–6500. Also switches the lamp on. |
| Pair Lamp | Gets the lamp key from your MyDyson account. Necessary one time. |

A command takes approximately 2.5 seconds, because each command connects, does
the handshake, and disconnects. The lamp changes after approximately 1.5 seconds.

## Status

Version 0.1.0 is an early release. It was tested with one Solarcycle Morph desk
lamp, on one Mac with Apple silicon.

- Tested on the lamp: the pairing and all the commands.
- The Intel build of the helper compiles, but nobody ran it on an Intel Mac.
- The quarantine step of the package install is not tested with a real browser
  download.

The Lightcycle Morph uses the same protocol according to the reference projects,
but it is not tested here.

## Requirements

- macOS 13 or newer, with Bluetooth
- [Raycast](https://www.raycast.com)
- Node.js 22 or newer
- The lamp is registered in the MyDyson app on your phone
- To build from source: the Xcode command line tools (`xcode-select --install`)

## Install

Raycast installs an extension that is not in its Store through the development
mode. The extension stays in Raycast after you stop the command.

### From a release package

The package contains a helper binary for Apple silicon and Intel, so Swift is
not necessary.

1. Download `solarmorph-<version>.zip` from the Releases page and unzip it.
2. macOS marks files from a browser download as quarantined, and it can refuse
   to run the helper because the helper is not notarized. Remove the mark:

   ```sh
   xattr -dr com.apple.quarantine solarmorph-<version>
   ```

3. Install and start:

   ```sh
   cd solarmorph-<version>
   npm install
   npm run dev
   ```

4. When the commands show in Raycast, stop `npm run dev` with Ctrl-C.

### From source

```sh
git clone https://github.com/cjse/solarmorph.git
cd solarmorph/extension
npm install
npm run dev
```

`npm run dev` builds the Swift helper for your Mac first.

## Pair the lamp

1. Close the MyDyson app on your phone. The lamp probably accepts only one
   connection at a time.
2. Run **Pair Lamp** in Raycast. Enter the country code, the email, and the
   password of your MyDyson account.
3. Dyson sends a 6-digit code by email. Enter it.

The first lamp command makes macOS ask for Bluetooth access for Raycast. Allow it.

The password goes only to the Dyson API and is not stored. The result of the
pairing is the key of the lamp, which the helper stores in
`~/.config/solarmorph/config.json` with mode 0600. Anybody who has this file and
is near the lamp can control the lamp. Remove the file to unpair.

## The command-line tool

The helper also works without Raycast.

```sh
cd helper
swift build -c release
.build/release/morph pair          # interactive, in a terminal
.build/release/morph status
.build/release/morph toggle
.build/release/morph set --brightness 60 --kelvin 4000
.build/release/morph --json status
.build/release/morph help
```

`set` applies all its options in one connection. `--verbose` shows each phase of
the connection with its time. `scan` lists the Bluetooth LE devices nearby; the
lamp shows with its serial number as its name.

## Troubleshooting

- **"Could not connect"**: close the MyDyson app, and stop all other systems
  that control the lamp (Homebridge, Home Assistant). Then try again.
- **The lamp refuses all connections** although it shows in `morph scan`: remove
  the power of the lamp for ten seconds. The reference project documents this
  lamp state.
- **"Bluetooth permission denied"**: allow Raycast (or your terminal app) in
  System Settings > Privacy & Security > Bluetooth.
- **The brightness is not the value that you set**: with auto brightness on, the
  lamp changes its output to hold the room level. This is the lamp, not an error.
- **The pairing fails with 404**: the lamp is not registered to this Dyson
  account. Add it in the MyDyson app first.

For a bug report, include the output of `morph --verbose status`. It does not
contain the key, but it can show the serial number of the lamp.

## Risks and limits

- The pairing uses the API of the MyDyson app. This API has no official
  documentation, and Dyson can change it or block it. Its use is possibly against
  the Dyson terms of use. You use it at your own risk. After the pairing, the
  extension does not use the network.
- The lamp does not acknowledge most writes. The helper spaces its writes and
  checks the power state, but a brightness or colour temperature command can be
  lost. Send it again.
- One lamp only.
- The key is in a file and not in the Keychain.

## How it works

`helper/` is a Swift package with no dependencies. `MorphCore` has the protocol:
the key derivation (HKDF-SHA256), the handshake (AES-128-CBC with HMAC-SHA256),
the message framing, the paced control writes, and the attribute channel for
daylight mode and presets. `extension/` is a thin layer that runs the helper with
`--json`.

The unit tests (`swift test` in `helper/`) check the crypto and the framing
against the vectors of the reference implementation.

To make a release package: `scripts/package-release.sh`. This needs the full
Xcode for the universal binary.

## Credits

The Bluetooth protocol of the Dyson lights was reverse-engineered from the
MyDyson Android app by S-Termi and documented in
[cmgrayb/hass-dyson](https://github.com/cmgrayb/hass-dyson).
[rummeyer/homebridge-dyson-solarcycle-morph](https://github.com/rummeyer/homebridge-dyson-solarcycle-morph)
by Oliver Rummeyer corrected and extended that documentation on real hardware.
Its `docs/PROTOCOL.md` is the reference for this project. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Licence

[MIT](LICENSE)
