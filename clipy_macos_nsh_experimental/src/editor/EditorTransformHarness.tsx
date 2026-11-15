// Native viewport transform fixture. No real clipboard or output files are touched.
import { mount, signal, View, Text } from "nsh";
import { ImageEditor } from "./ImageEditor";
import fixture from "./fixtures/red-blue.png";
function Harness() {
    const result = signal("");
    const actions = {
        invoke: async (name: string, payload: any) => {
            if (name === "image.render") {
                if (!payload.preview) {
                    const points = payload.annotations[0]?.points || [];
                    const round = (v: number) => Math.round(v * 10) / 10;
                    result.set(
                        JSON.stringify({
                            first: points[0]
                                ? [round(points[0].x), round(points[0].y)]
                                : [],
                            last: points.length
                                ? [
                                      round(points[points.length - 1].x),
                                      round(points[points.length - 1].y),
                                  ]
                                : [],
                        }),
                    );
                }
                return { path: fixture.url };
            }
            if (name === "files.saveCopy") return { path: fixture.url };
            if(name==="image.commit")return {committed:true,id:"fixture-committed"};
            return true;
        },
    };
    return (
        <View class="flex-1">
            <ImageEditor
                initialSize={{ width: 64, height: 48 }}
                path={fixture.url}
                actions={actions}
                onClose={() => {}}
            />
            <Text>{result()}</Text>
        </View>
    );
}
mount(Harness);
