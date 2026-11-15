// Model-list selection fixture; does not contact an API or store credentials.
import { mount, signal } from "nsh";
import { RootScreen } from "./RootScreen";
function Harness() {
    const state = signal<any>({
        page: "words",
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        models: [],
    });
    const actions = {
        invoke: async (name: string) => {
            if (name === "model.status")
                return {
                    endpoint: "http://127.0.0.1:1",
                    model: "fixture-small",
                    hasKey: false,
                };
            if (name === "models.list") {
                const models = ["fixture-small", "other-large"];
                state.set({ ...state(), models });
                return models;
            }
            return true;
        },
    };
    return <RootScreen model={{ state }} actions={actions} />;
}
mount(Harness);
