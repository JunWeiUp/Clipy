// User content intentionally matches translation keys; it must remain unchanged.
import { mount, signal } from "nsh";
import { setLocale } from "../ui/locale";
import { RootScreen } from "./RootScreen";
function Harness() {
    const state = signal({
        page: "snippets",
        history: [],
        snippets: [{ id: "s", title: "通用", content: "文件", folderId: "f" }],
        folders: [{ id: "f", name: "历史" }],
        selectedFolder: "f",
        devices: [],
        notifications: [],
        settings: { language: "en" },
        selection: null,
    });
    return (
        <RootScreen
            model={{ state }}
            actions={{ navigate: () => {}, invoke: async () => {} }}
        />
    );
}
setLocale("en");
mount(Harness);
