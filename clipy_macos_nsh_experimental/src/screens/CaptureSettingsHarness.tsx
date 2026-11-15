// Canonical capture-preference persistence fixture.
import { mount, Storage, host } from "nsh";
import { RootScreen } from "./RootScreen";
import { createAppModel } from "../core/model";
function Harness() {
    const base = createAppModel({
        storage: Storage,
        host: { call: async <T,>() => true as T },
    });
    base.actions.navigate("settings");
    const model = {
        ...base,
        state: () => ({
            ...base.state(),
            settingsSection: host.params.section || "截图",
        }),
    };
    return <RootScreen model={model} actions={base.actions} />;
}
mount(Harness);
