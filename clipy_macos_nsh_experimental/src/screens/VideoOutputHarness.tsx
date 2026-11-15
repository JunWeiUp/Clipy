// Export-option UI fixture. Native encoding is tested separately; no media is opened here.
import { mount, signal, View, Text } from "nsh";
import { RootScreen } from "./RootScreen";
function Harness() {
    const summary = signal("");
    const state = signal<any>({
        page: "video",
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: {},
        videoPath: "asset:/fixture.mp4",
        videoInfo: { width: 640, height: 360, duration: 8, fps: 30 },
        videoEffects: [],
    });
    const actions = {
        invoke: async (name: string, payload: any) => {
            if (name === "video.export") {
                summary.set(
                    JSON.stringify({
                        scale: payload.scale,
                        quality: payload.quality,
                        format: payload.format,
                    }),
                );
                const result = {
                    path:
                        payload.format === "gif"
                            ? "asset:/fixture-export.gif"
                            : "asset:/fixture-export.mp4",
                    format: payload.format,
                    fps: payload.format === "gif" ? 6 : 30,
                    width: 320,
                    height: 180,
                    duration: 4,
                    bytes: 1048576,
                };
                state.set({ ...state(), videoExport: result });
                return result;
            }
            return true;
        },
    };
    return (
        <View class="flex-1">
            <RootScreen model={{ state }} actions={actions} />
            <Text>{summary()}</Text>
        </View>
    );
}
mount(Harness);
