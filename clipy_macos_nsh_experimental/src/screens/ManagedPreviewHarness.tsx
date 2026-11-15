// Managed-media lease fixture: the first row has no path until an asynchronous callback.
import { mount, signal, View, Text, host } from "nsh";
import { RootScreen } from "./RootScreen";
import { Btn } from "../ui/primitives";
import fixture from "../editor/fixtures/red-blue.png";
function Harness() {
    const requests = signal(0);
    const state = signal<any>({
        page: "history",
        history: [
            {
                id: "managed",
                type: host.params.type === "pdf" ? "pdf" : "image",
                title: "",
                content: "media:internal-fixture-reference",
                mediaId: "fixture-media-id",
                sourceApp: "Fixture",
                date: 1,
                isPinned: false,
            },
        ],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        selection: null,
        uiVisible: true,
    });
    const actions = {
        navigate: (page: string) =>
            state.set({
                ...state(),
                page,
                selection: null,
                history: state().history.map((row: any) => ({
                    ...row,
                    mediaPath: page === "history" ? row.mediaPath : undefined,
                })),
            }),
        selectHistory: (id: string) => {
            requests.set(requests() + 1);
            state.set({ ...state(), selection: id });
            setTimeout(
                () =>
                    state.set({
                        ...state(),
                        history: state().history.map((row: any) =>
                            row.id === id
                                ? { ...row, mediaPath: fixture.url }
                                : row,
                        ),
                    }),
                30,
            );
        },
        invoke: async () => true,
    };
    return (
        <View class="flex-1">
            <RootScreen model={{ state }} actions={actions} />
            <View class="flex-row">
                <Text>{`requests:${requests()}`}</Text>
                <Btn
                    label="回填其它模型字段"
                    onPress={() =>
                        state.set({ ...state(), previewVersion: Date.now() })
                    }
                />
            </View>
        </View>
    );
}
mount(Harness);
