// Simulates the controller's wordbook alias with a cached clipboard-prefill token.
import { mount, signal, View } from "nsh";
import { RootScreen } from "./RootScreen";
import { Btn } from "../ui/primitives";
function Harness() {
    let routeVersion = 1;
    const state = signal<any>({
        page: "tools",
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        words: [
            {
                id: "w",
                text: "saved-word",
                definition: "fixture definition",
                familiar: false,
                count: 1,
                date: 1,
            },
        ],
        wordPrefill: "cached-word",
        wordPrefillVersion: 1,
    });
    const actions = {
        invoke: async () => true,
        navigate: (page: string) => {
            if (page === "wordbook")
                state.set({
                    ...state(),
                    page: "words",
                    wordBookRequestVersion: ++routeVersion,
                });
            else if (page === "words")
                state.set({
                    ...state(),
                    page,
                    wordPrefill: "new-query-word",
                    wordPrefillVersion: routeVersion + 1,
                    wordQueryRequestVersion: ++routeVersion,
                });
            else state.set({ ...state(), page });
        },
    };
    return (
        <View class="flex-1">
            <RootScreen model={{ state }} actions={actions} />
            <Btn
                label="模拟查词入口"
                onPress={() => actions.navigate("words")}
            />
            <Btn
                label="模拟空剪贴板查词入口"
                onPress={() => {
                    const version = ++routeVersion;
                    state.set({
                        ...state(),
                        page: "words",
                        wordQueryRequestVersion: version,
                        wordPrefillVersion: version,
                        wordPrefill: "",
                    });
                }}
            />
        </View>
    );
}
mount(Harness);
