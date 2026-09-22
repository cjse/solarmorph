import { showHUD } from "@raycast/api";
import { helperCall, showLampFailure } from "./morph";

export default async () => {
  try {
    const { stopped } = await helperCall<{ stopped: boolean }>(["daemon", "stop"]);
    await showHUD(stopped ? "Lamp disconnected" : "The lamp was not connected");
  } catch (error) {
    await showLampFailure(error);
  }
};
