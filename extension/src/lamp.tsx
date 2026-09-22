import { Action, ActionPanel, Color, Icon, launchCommand, LaunchType, List } from "@raycast/api";
import { useEffect, useState } from "react";
import { isLiveAvailable, isNotPaired, LampState, morph, Preset, showLampFailure, watchLamp } from "./morph";

const BRIGHTNESS_STEPS = [1, 10, 25, 50, 75, 100];
const KELVIN_STEPS = [2700, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500];
const PRESETS: { id: Preset; title: string; subtitle: string }[] = [
  { id: "study", title: "Study", subtitle: "Approximately 4700 K, 500 lm" },
  { id: "relax", title: "Relax", subtitle: "Approximately 2900 K, 250 lm" },
  { id: "precision", title: "Precision", subtitle: "Approximately 4600 K, 1000 lm" },
];

const onOff = (on?: boolean) =>
  on === undefined
    ? { tag: { value: "Unknown", color: Color.SecondaryText } }
    : { tag: { value: on ? "On" : "Off", color: on ? Color.Green : Color.SecondaryText } };

export default function Lamp() {
  const [state, setState] = useState<LampState>();
  const [isLoading, setIsLoading] = useState(true);
  const [notPaired, setNotPaired] = useState(false);
  // A new number starts the watch again, after the background process closed it.
  const [watchRun, setWatchRun] = useState(0);
  // True while the watch is open, so that the list follows the lamp.
  const [live, setLive] = useState(false);

  // `expected` holds the values that were just written. The lamp ramps to a new
  // value, so the value that it reports immediately after a write is not the target.
  async function run(args: string[], expected: Partial<LampState> = {}) {
    setIsLoading(true);
    try {
      const next = await morph(...args);
      // on/off/toggle do not report the attributes, so keep the known ones. A full
      // reply omits `preset` when no preset is active, so do not keep the old one then.
      setState((previous) => {
        const attributes = next.daylight === undefined ? { daylight: previous?.daylight, preset: previous?.preset } : {};
        return { ...attributes, ...next, ...expected };
      });
    } catch (error) {
      setNotPaired(isNotPaired(error));
      await showLampFailure(error);
    } finally {
      setIsLoading(false);
    }
  }

  // The watch gives the state at the start, then each change: from a command,
  // from the MyDyson app, or from the buttons on the lamp.
  useEffect(() => {
    if (!isLiveAvailable()) {
      run(["status"]);
      return;
    }
    setLive(true);
    return watchLamp({
      onState: (next) => {
        setState(next);
        setNotPaired(false);
        setIsLoading(false);
      },
      onError: (error) => {
        setNotPaired(isNotPaired(error));
        setIsLoading(false);
        showLampFailure(error);
      },
      onEnd: () => {
        setLive(false);
        setIsLoading(false);
      },
    });
  }, [watchRun]);

  // Read the lamp, and not the live copy. Start the watch again if it ended.
  async function refreshState() {
    await run(["status", "--fresh"]);
    if (isLiveAvailable() && !live) {
      setWatchRun((count) => count + 1);
    }
  }

  const set = (option: string, value: string, expected?: Partial<LampState>) => run(["set", option, value], expected);
  const flip = (on?: boolean) => (on ? "off" : "on");
  const refresh = (
    <Action
      title="Refresh"
      icon={Icon.ArrowClockwise}
      shortcut={{ modifiers: ["cmd"], key: "r" }}
      onAction={refreshState}
    />
  );

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter the controls">
      {notPaired && (
        <List.EmptyView
          icon={Icon.Link}
          title="The lamp is not paired"
          description="Pair it with your Dyson account one time. After that, all control is local."
          actions={
            <ActionPanel>
              <Action
                title="Pair Lamp"
                icon={Icon.Link}
                onAction={() => launchCommand({ name: "pair", type: LaunchType.UserInitiated })}
              />
            </ActionPanel>
          }
        />
      )}
      {!state && !notPaired && !isLoading && (
        <List.EmptyView
          icon={Icon.LightBulbOff}
          title="Could not reach the lamp"
          description="Close the MyDyson app, and make sure that the lamp has power and is near this Mac. Then refresh."
          actions={<ActionPanel>{refresh}</ActionPanel>}
        />
      )}
      {state && (
        <>
          <List.Section
            title="Light"
            subtitle={isLiveAvailable() && !live ? "Not live · Refresh to follow the lamp again" : undefined}
          >
            <List.Item
              title="Power"
              icon={{ source: Icon.LightBulb, tintColor: state.power ? Color.Yellow : Color.SecondaryText }}
              accessories={[onOff(state.power)]}
              actions={
                <ActionPanel>
                  <Action
                    title={state.power ? "Turn off" : "Turn on"}
                    icon={Icon.Power}
                    // The title promises a direction, so do not toggle a state that is possibly old.
                    onAction={() => run([state.power ? "off" : "on"])}
                  />
                  {refresh}
                </ActionPanel>
              }
            />
            <List.Item
              title="Brightness"
              icon={Icon.Sun}
              accessories={[{ text: `${state.brightness} % · ${state.lumens} lm` }]}
              actions={
                <ActionPanel>
                  <ActionPanel.Submenu title="Set Brightness" icon={Icon.Sun}>
                    {BRIGHTNESS_STEPS.map((percent) => (
                      <Action
                        key={percent}
                        title={`${percent} %`}
                        onAction={() =>
                          set("--brightness", String(percent), {
                            brightness: percent,
                            lumens: Math.round(100 + percent * 9),
                          })
                        }
                      />
                    ))}
                  </ActionPanel.Submenu>
                  {refresh}
                </ActionPanel>
              }
            />
            <List.Item
              title="Colour Temperature"
              icon={Icon.Temperature}
              accessories={[{ text: `${state.kelvin} K` }]}
              actions={
                <ActionPanel>
                  <ActionPanel.Submenu title="Set Colour Temperature" icon={Icon.Temperature}>
                    {KELVIN_STEPS.map((kelvin) => (
                      <Action
                        key={kelvin}
                        title={`${kelvin} K`}
                        // A manual value stops the daylight mode.
                        onAction={() => set("--kelvin", String(kelvin), { kelvin, daylight: false })}
                      />
                    ))}
                  </ActionPanel.Submenu>
                  {refresh}
                </ActionPanel>
              }
            />
          </List.Section>

          <List.Section title="Modes">
            <List.Item
              title="Daylight Tracking"
              subtitle="Moves the colour temperature through the day"
              icon={Icon.Globe}
              accessories={[onOff(state.daylight)]}
              actions={
                <ActionPanel>
                  <Action
                    title={state.daylight ? "Turn off" : "Turn on"}
                    icon={Icon.Globe}
                    onAction={() => set("--daylight", flip(state.daylight))}
                  />
                  {refresh}
                </ActionPanel>
              }
            />
            <List.Item
              title="Auto Brightness"
              subtitle="Holds the room at a constant light level"
              icon={Icon.CircleProgress50}
              accessories={[onOff(state.autoBrightness)]}
              actions={
                <ActionPanel>
                  <Action
                    title={state.autoBrightness ? "Turn off" : "Turn on"}
                    icon={Icon.CircleProgress50}
                    onAction={() => set("--auto", flip(state.autoBrightness))}
                  />
                  {refresh}
                </ActionPanel>
              }
            />
            <List.Item
              title="Movement Mode"
              subtitle="Switches on when it senses movement"
              icon={Icon.Footprints}
              accessories={[onOff(state.movement)]}
              actions={
                <ActionPanel>
                  <Action
                    title={state.movement ? "Turn off" : "Turn on"}
                    icon={Icon.Footprints}
                    onAction={() => set("--movement", flip(state.movement))}
                  />
                  {refresh}
                </ActionPanel>
              }
            />
          </List.Section>

          <List.Section title="Presets">
            {PRESETS.map((preset) => {
              const active = state.preset === preset.id;
              return (
                <List.Item
                  key={preset.id}
                  title={preset.title}
                  subtitle={preset.subtitle}
                  icon={active ? { source: Icon.CheckCircle, tintColor: Color.Green } : Icon.Circle}
                  actions={
                    <ActionPanel>
                      <Action
                        title={active ? "Clear Preset" : "Activate Preset"}
                        icon={active ? Icon.XMarkCircle : Icon.CheckCircle}
                        onAction={() => set("--preset", active ? "none" : preset.id)}
                      />
                      {refresh}
                    </ActionPanel>
                  }
                />
              );
            })}
          </List.Section>
        </>
      )}
    </List>
  );
}
