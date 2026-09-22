# Changelog

## 0.4.0 - 2026-09-22

- The live state is correct from the start. Before, a change during the first
  seconds of the background process, for example the end of a brightness ramp,
  could stay out of the live copy.
- A daylight or preset change goes into the live state as soon as the lamp
  acknowledges it.
- The preference "Never (slower commands)" works while a background process is
  active. Before, the commands failed until that process stopped. A changed
  idle time applies to the next command.
- Lamp Controls shows "Could not reach the lamp" with a Refresh action when the
  first load fails, and says when the list no longer follows the lamp. The
  power action switches the lamp to the state that its title shows.
- The background process is more robust: a client that stops reading cannot
  block it, it does not stop in the middle of a command at its idle limit, and
  it skips a command whose client gave up. The helper from the terminal and the
  helper in Raycast share one background process when they are the same build.
- The pairing sends a real locale to Dyson (for example `en-GB`), and the
  command-line pairing suggests the region of the Mac.
- Smaller fixes: a failed scan stops, a lost Bluetooth fragment makes the
  handshake try again, and the configuration file is written atomically.

## 0.3.0 - 2026-09-21

- The background process follows the notifications of the lamp and keeps a live
  copy of the state. `status` takes approximately 0.01 seconds, not 0.8 seconds.
- The Lamp Controls list shows each change immediately, also a change from the
  buttons on the lamp or from the MyDyson app.
- `morph watch` shows the state and then each change. `morph status --fresh`
  reads the lamp and not the live copy.

## 0.2.0 - 2026-09-21

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
