// Real keyboard dispatch fixture; clipboard/system effects are recorded locally.
import { mount, signal, View, Text } from "nsh";
import { RootScreen } from "./RootScreen";
function Harness() {
    const rows = [
        {
            id: "one",
            title: "One",
            content: "First",
            type: "text",
            sourceApp: "Fixture",
            date: Date.now(),
            isPinned: false,
        },
        {
            id: "two",
            title: "Two",
            content: "Second",
            type: "text",
            sourceApp: "Fixture",
            date: Date.now(),
            isPinned: false,
        },
        {
            id: "file",
            title: "Fixture file",
            content: "/tmp/fixture.txt",
            files: ["/tmp/fixture.txt"],
            type: "file",
            sourceApp: "Fixture",
            date: Date.now(),
            isPinned: false,
        },
    ];
    const state = signal<any>({
        page: "history",
        history: rows,
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        selection: null,
    });
    const operation = signal("");
    let removed: any[] = [];
    const actions = {
        selectHistory: (id: string) => state.set({ ...state(), selection: id }),
        copyHistory: (id: string, paste: boolean, plain: boolean) =>
            operation.set(`copy:${id}:${paste}:${plain}`),
        deleteHistory: (id: string) => {
            removed = state().history.filter((row: any) => row.id === id);
            state.set({
                ...state(),
                history: state().history.filter((row: any) => row.id !== id),
                selection: null,
            });
        },
        undoDelete: () => {
            state.set({
                ...state(),
                history: rows.filter(
                    (row) =>
                        state().history.some((old: any) => old.id === row.id) ||
                        removed.some((old) => old.id === row.id),
                ),
            });
            removed = [];
        },
        pinHistory: (id: string) =>
            state.set({
                ...state(),
                history: state().history.map((row: any) =>
                    row.id === id ? { ...row, isPinned: !row.isPinned } : row,
                ),
            }),
        pasteFileNames: (id: string) => operation.set(`filenames:${id}`),
        setQuery: () => {},
        invoke: async () => {},
    };
    return (
        <View class="flex-1">
            <RootScreen model={{ state }} actions={actions} />
            <Text>{operation()}</Text>
        </View>
    );
}
mount(Harness);
