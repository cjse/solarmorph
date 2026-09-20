import { LaunchProps, showToast, Toast } from "@raycast/api";
import { parseNumber, quick } from "./morph";

export default async (props: LaunchProps<{ arguments: Arguments.SetBrightness }>) => {
  const percent = parseNumber(props.arguments.percent, 0, 100);
  if (percent === undefined) {
    await showToast({ style: Toast.Style.Failure, title: "Brightness must be a number from 0 to 100" });
    return;
  }
  // A lamp that is off keeps the value but shows nothing, so switch it on too.
  await quick(["set", "--power", "on", "--brightness", String(percent)], () => `Brightness ${percent} %`);
};
