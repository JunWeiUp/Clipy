// State-owned safe model metadata fixture. The synthetic key must never be hydrated into an input.
import { mount, signal, View, Text } from "nsh";
import { RootScreen } from "./RootScreen";
import { Btn } from "../ui/primitives";
function Harness() {
    const summary = signal("");
    const state = signal<any>({
        page: "words",
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        modelConfig: {
            endpoint: "http://127.0.0.1:1",
            model: "fixture-small",
            hasKey: true,
            key: "never-display-fixture-key",
        },
        modelConfigVersion: 1,
    });
    const actions = {
        invoke: async (name: string, payload?: any) => {
            if (name === "model.status") return state().modelConfig;
            if (name === "models.configure") {
                const config = {
                    endpoint: payload.endpoint,
                    model: payload.model,
                    hasKey: !!payload.key,
                };
                state.set({
                    ...state(),
                    modelConfig: config,
                    modelConfigVersion: state().modelConfigVersion + 1,
                });
                summary.set(
                    JSON.stringify({
                        configured: true,
                        keyMode: payload.key ? "updated" : "deleted",
                    }),
                );
                return config;
            }
            return true;
        },
    };
    return (
        <View class="flex-1">
            <RootScreen model={{ state }} actions={actions} />
            <View class="flex-row">
                <Btn
                    label="推送外部配置"
                    onPress={() =>
                        state.set({
                            ...state(),
                            modelConfig: {
                                endpoint: "http://127.0.0.1:2",
                                model: "external-large",
                                hasKey: true,
                            },
                            modelConfigVersion: state().modelConfigVersion + 1,
                        })
                    }
                />
                <Text>{summary()}</Text>
            </View>
        </View>
    );
}
mount(Harness);
