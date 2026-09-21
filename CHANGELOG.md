# Changelog

## Unreleased

- A background process holds the Bluetooth connection between commands. A
  command after the first one takes approximately 0.6 seconds, not 2.5 seconds.
- New Raycast command Disconnect Lamp, and the preference Keep the Connection Open.
- Two commands at the same time now run one after the other.
- A lamp that does not answer the handshake fails after approximately 20 seconds
  with a clear message, not after more than 2 minutes.

## 0.1.0 - 2026-09-21

The first release.

- `morph`, a command-line tool that controls the lamp over Bluetooth LE from macOS.
- A Raycast extension with the commands Lamp Controls, Toggle Lamp, Turn Lamp on,
  Turn Lamp off, Set Lamp Brightness, Set Lamp Colour Temperature, and Pair Lamp.
