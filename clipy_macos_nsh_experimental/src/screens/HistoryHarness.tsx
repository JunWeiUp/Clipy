// Isolated history UI test entry. All data is synthetic.
import { mount, signal } from "nsh";
import { RootScreen } from "./RootScreen";
function Harness() {
    const state = signal({
        page: "history",
        history: [
            {
                id: "1",
                type: "text",
                title: "hello today",
                content: "hello world",
                sourceApp: "Notes",
                date: Date.now(),
                isPinned: false,
            },
            {
                id: "2",
                type: "text",
                title: "older JSON",
                content: '{"message":"hello"}',
                sourceApp: "Terminal",
                date: Date.now() - 10 * 86400000,
                isPinned: true,
            },
        ],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        selection: null,
    });
    return (
        <RootScreen
            model={{ state }}
            actions={{
                navigate: (page: string) => state.set({ ...state(), page }),
                setQuery: () => {},
                invoke: async () => {},
            }}
        />
    );
}
mount(Harness);
