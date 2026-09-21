import { environment, launchCommand, LaunchType, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import path from "node:path";

export type Preset = "study" | "relax" | "precision";

/** The `--json` output of the helper. */
export interface LampState {
  power: boolean;
  lumens: number;
  /** Linear position in the 100–1000 lm range. */
  brightness: number;
  kelvin: number;
  autoBrightness: boolean;
  movement: boolean;
  /** Absent after on/off/toggle, which skip the attribute channel for speed. */
  daylight?: boolean;
  preset?: Preset;
}

const helper = path.join(environment.assetsPath, "morph");

// The lamp accepts one connection at a time, so calls go one after the other.
let queue: Promise<unknown> = Promise.resolve();

export function morph(...args: string[]): Promise<LampState> {
  const call = queue.then(() => helperCall<LampState>(args));
  queue = call.catch(() => undefined);
  return call;
}

export class HelperError extends Error {
  constructor(
    message: string,
    readonly code?: string,
  ) {
    super(message);
  }
}

/**
 * Run the helper and parse its `--json` reply.
 *
 * @param input JSON for the stdin of the helper. Secrets go here and not in the
 * arguments, because other processes can read an argument list.
 */
export function helperCall<T>(args: string[], input?: object): Promise<T> {
  return new Promise((resolve, reject) => {
    // The helper retries the connection itself, so the timeout is generous.
    const child = execFile(helper, ["--json", ...args], { timeout: 60_000 }, (error, stdout, stderr) => {
      try {
        const reply = JSON.parse(stdout);
        if (!error && reply.error === undefined) {
          resolve(reply as T);
          return;
        }
        reject(new HelperError(reply.error ?? stderr.trim(), reply.code));
      } catch {
        reject(new HelperError(stderr.trim() || error?.message || "The helper gave no reply."));
      }
    });
    child.stdin?.end(input === undefined ? "" : JSON.stringify(input));
  });
}

export const isNotPaired = (error: unknown) => error instanceof HelperError && error.code === "notPaired";

/** Show a failure. When the lamp is not paired, the toast offers the pairing command. */
export async function showLampFailure(error: unknown, toast?: Toast) {
  const options: Toast.Options = isNotPaired(error)
    ? {
        style: Toast.Style.Failure,
        title: "The lamp is not paired",
        message: "Run the Pair Lamp command first.",
        primaryAction: {
          title: "Pair Lamp",
          onAction: () => launchCommand({ name: "pair", type: LaunchType.UserInitiated }),
        },
      }
    : {
        style: Toast.Style.Failure,
        title: "Could not control the lamp",
        message: error instanceof Error ? error.message : String(error),
      };
  if (toast) {
    Object.assign(toast, options);
  } else {
    await showToast(options);
  }
}

/** Run a helper command from a no-view command, with a HUD for the result. */
export async function quick(args: string[], done: (state: LampState) => string) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Connecting to the lamp…" });
  try {
    await showHUD(done(await morph(...args)));
  } catch (error) {
    await showLampFailure(error, toast);
  }
}

export function parseNumber(value: string, min: number, max: number): number | undefined {
  const number = Number(value.replace(/[%kK\s]/g, ""));
  return Number.isInteger(number) && number >= min && number <= max ? number : undefined;
}
