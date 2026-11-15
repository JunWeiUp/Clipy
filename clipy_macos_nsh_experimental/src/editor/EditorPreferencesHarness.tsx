// Synthetic preferences/pressure integration fixture.
import { mount, signal, View, Text } from "nsh";
import { ImageEditor } from "./ImageEditor";
import fixture from "./fixtures/red-blue.png";
function Harness() {
    const summary = signal(""),
        remembered = signal("");
    const actions = {
        saveSettings: async (value: any) =>
            remembered.set(value.lastAnnotationTool),
        invoke: async (name: string, payload: any) => {
            if (name === "image.render" && !payload.preview) {
                summary.set(
                    JSON.stringify({
                        pressure: payload.annotations[0]?.points[1]?.pressure,
                        brightness: payload.effects.brightness,
                    }),
                );
                return { path: fixture.url };
            }
            if (name === "image.render" || name === "files.saveCopy")
                return { path: fixture.url };
            if(name==="image.commit")return {committed:true,id:"fixture-committed"};
            return true;
        },
    };
    return (
        <View class="flex-1">
            <ImageEditor
                path={fixture.url}
                pressure={0.4}
                defaults={{
                    rememberTool: true,
                    lastAnnotationTool: "pen",
                    showGuides: true,
                    showToolShortcuts: true,
                    stylusPressure: true,
                    brightness: 0.1,
                }}
                actions={actions}
                onClose={() => {}}
            />
            <Text>{remembered() ? `remembered:${remembered()}` : ""}</Text>
            <Text>{summary()}</Text>
        </View>
    );
}
mount(Harness);
