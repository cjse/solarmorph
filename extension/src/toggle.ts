import { quick } from "./morph";

export default () => quick(["toggle"], (state) => (state.power ? "Lamp on" : "Lamp off"));
