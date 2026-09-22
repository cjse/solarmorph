import { environment, getPreferenceValues, launchCommand, LaunchType, showHUD, showToast, Toast } from "@raycast/api";
import { execFile, spawn } from "node:child_process";
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

/** Seconds that the background process holds the connection. "0" means no background process. */
const keepAliveSeconds = () => getPreferenceValues<{ keepAlive?: string }>().keepAlive ?? "60";

/** The live state needs the background process. */
export const isLiveAvailable = () => keepAliveSeconds() !== "0";

function helperEnvironment(): NodeJS.ProcessEnv {
  const seconds = keepAliveSeconds();
  return seconds === "0" ? { ...process.env, SOLARMORPH_DIRECT: "1" } : { ...process.env, SOLARMORPH_IDLE: seconds };
}

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
    const options = { timeout: 60_000, env: helperEnvironment() };
    const child = execFile(helper, ["--json", ...args], options, (error, stdout, stderr) => {
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

/**
 * Follow the live state of the lamp: the state now, then each change from any
 * source. The background process stays active while the watch is open.
 *
 * @returns a function that stops the watch.
 */
export function watchLamp(handlers: {
  onState: (state: LampState) => void;
  onError: (error: HelperError) => void;
  onEnd: () => void;
}): () => void {
  const child = spawn(helper, ["--json", "watch"], { env: helperEnvironment(), stdio: ["ignore", "pipe", "pipe"] });
  let buffer = "";
  let stopped = false;

  child.stdout.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (stopped || !line) continue;
      try {
        const reply = JSON.parse(line);
        if (reply.error !== undefined) {
          handlers.onError(new HelperError(reply.error, reply.code || undefined));
        } else {
          handlers.onState(reply as LampState);
        }
      } catch {
        // Not a complete JSON line. The next line replaces it.
      }
    }
  });
  child.on("error", (error) => !stopped && handlers.onError(new HelperError(error.message)));
  child.on("close", () => !stopped && handlers.onEnd());

  return () => {
    stopped = true;
    child.kill();
  };
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
  const digits = value.replace(/[%kK\s]/g, "");
  // Number("") is 0, so an argument of only "%" must not become 0.
  if (!digits) {
    return undefined;
  }
  const number = Number(digits);
  return Number.isInteger(number) && number >= min && number <= max ? number : undefined;
}
