// Isolated persistent snippet tests; never opens production storage or system hooks.
import { mount, Storage } from "nsh";
import { RootScreen } from "./RootScreen";
import { createAppModel } from "../core/model";
function Harness() {
    const model = createAppModel({
        storage: Storage,
        host: { call: async <T,>() => true as T },
    });
    void model.ready.then(async () => {
        await model.actions.saveSnippet({
            id: "one",
            title: "One",
            content: "first",
            folderId: "default",
        });
        await model.actions.saveSnippet({
            id: "two",
            title: "Two",
            content: "second",
            folderId: "default",
        });
        await model.actions.saveFolder({ id: "other", name: "Other" });
        model.actions.selectFolder("default");
        model.actions.navigate("snippets");
    });
    return (
        <RootScreen
            model={model}
            actions={{
                ...model.actions,
                invoke: async (name: string, payload?: any) =>
                    name === "shortcuts.capture"
                        ? { shortcut: "ctrl+alt+1", cancelled: false }
                        : model.actions.invoke(name, payload),
            }}
        />
    );
}
mount(Harness);
