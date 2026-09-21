import { showHUD } from "@raycast/api";
import { helperCall } from "./morph";

export default async () => {
  const { stopped } = await helperCall<{ stopped: boolean }>(["daemon", "stop"]);
  await showHUD(stopped ? "Lamp disconnected" : "The lamp was not connected");
};
