import { environment, showHUD, showToast, Toast } from "@raycast/api";
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
  const call = queue.then(() => run(args));
  queue = call.catch(() => undefined);
  return call;
}

function run(args: string[]): Promise<LampState> {
  return new Promise((resolve, reject) => {
    // The helper retries the connection itself, so the timeout is generous.
    execFile(helper, ["--json", ...args], { timeout: 60_000 }, (error, stdout, stderr) => {
      try {
        const reply = JSON.parse(stdout);
        if (!error && typeof reply.power === "boolean") {
          resolve(reply as LampState);
          return;
        }
        reject(new Error(reply.error ?? stderr.trim()));
      } catch {
        reject(new Error(stderr.trim() || error?.message || "The helper gave no reply."));
      }
    });
  });
}

/** Run a helper command from a no-view command, with a HUD for the result. */
export async function quick(args: string[], done: (state: LampState) => string) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Connecting to the lamp…" });
  try {
    await showHUD(done(await morph(...args)));
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Could not control the lamp";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}

export function parseNumber(value: string, min: number, max: number): number | undefined {
  const number = Number(value.replace(/[%kK\s]/g, ""));
  return Number.isInteger(number) && number >= min && number <= max ? number : undefined;
}
