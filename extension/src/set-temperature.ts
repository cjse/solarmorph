import { LaunchProps, showToast, Toast } from "@raycast/api";
import { parseNumber, quick } from "./morph";

export default async (props: LaunchProps<{ arguments: Arguments.SetTemperature }>) => {
  const kelvin = parseNumber(props.arguments.kelvin, 2700, 6500);
  if (kelvin === undefined) {
    await showToast({ style: Toast.Style.Failure, title: "Colour temperature must be from 2700 to 6500 K" });
    return;
  }
  await quick(["set", "--power", "on", "--kelvin", String(kelvin)], () => `Colour temperature ${kelvin} K`);
};
