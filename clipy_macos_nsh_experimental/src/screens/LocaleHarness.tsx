// Locale switching regression with no user data or native side effects.
import { mount, signal, effect, host } from "nsh";
import { DEFAULT_SETTINGS } from "../core/domain";
import { RootScreen } from "./RootScreen";
import { setLocale } from "../ui/locale";
function Harness() {
    const state = signal<any>({
        page: String(host.params.page || "settings"),
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {
            ...DEFAULT_SETTINGS,
            language: String(host.params.language || "zh-CN"),
        },
        selection: null,
        settingsSection: host.params.section,
    });
    effect(() => setLocale(state().settings.language));
    const actions = {
        saveSettings: async (p: any) =>
            state.set({ ...state(), settings: { ...state().settings, ...p } }),
        navigate: (page: string) => state.set({ ...state(), page }),
        invoke: async () => {},
    };
    return <RootScreen model={{ state }} actions={actions} />;
}
mount(Harness);
