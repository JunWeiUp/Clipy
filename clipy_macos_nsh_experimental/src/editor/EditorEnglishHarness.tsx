import { setLocale } from "../ui/locale";
// Isolated editor test entry. The image is a generated 64x48 red/blue fixture.
import { mount, View, Text, signal } from "nsh";
import fixture from "./fixtures/red-blue.png";
import { ImageEditor } from "./ImageEditor";
function Harness() {
    const saved = signal("");
    const actions = {
        invoke: async (name: string, payload: any) => {
            if (name === "image.render" && !payload.preview) {
                if (!payload.annotations.length) throw Error("未绘制标注");
                const points = payload.annotations[0].points;
                if (
                    points.length < 2 ||
                    (points[0].x === points[points.length - 1].x &&
                        points[0].y === points[points.length - 1].y)
                )
                    throw Error("拖动没有产生几何变化");
                saved.set(JSON.stringify(payload));
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
                actions={actions}
                onClose={() => {}}
            />
            <Text>{saved() ? "已导出场景" : ""}</Text>
        </View>
    );
}
setLocale("en");
mount(Harness);
