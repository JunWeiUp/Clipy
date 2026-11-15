// Large-list rendering regression fixture, synthetic rows only.
import { mount, signal } from "nsh";
import { RootScreen } from "./RootScreen";
function Harness() {
    const state = signal({
        page: "history",
        history: Array.from({ length: 150 }, (_, i) => ({
            id: String(i),
            type: "text",
            title: `entry-${i}`,
            content: `content-${i}`,
            sourceApp: "Fixture",
            date: Date.now(),
            isPinned: false,
            ocrText: i === 0 ? "recognized needle" : "",
        })),
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
            actions={{ setQuery: () => {}, invoke: async () => {} }}
        />
    );
}
mount(Harness);
