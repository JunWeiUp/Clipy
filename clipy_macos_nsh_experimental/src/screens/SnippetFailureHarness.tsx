// Genuine storage rejection fixture; no production filesystem is used.
import { mount, View, Text, Storage, signal } from "nsh";
import { RootScreen } from "./RootScreen";
import { Btn } from "../ui/primitives";
import { createAppModel } from "../core/model";
function Harness() {
    let fault = false;
    const closed = signal("");
    const model = createAppModel({
        storage: {
            getItem: (key) => Storage.getItem(key),
            setItem: (key, value) =>
                fault
                    ? Promise.reject(Error("fixture disk full"))
                    : Storage.setItem(key, value),
        },
        host: { call: async <T,>() => true as T },
    });
    const actions: any = model.actions;
    void model.ready.then(async () => {
        await actions.saveSnippet({
            id: "one",
            title: "One",
            content: "first",
            folderId: "default",
        });
        actions.navigate("snippets");
        fault = true;
    });
    return (
        <View class="flex-1">
            <RootScreen model={model} actions={actions} />
            <View class="flex-row">
                <Btn
                    label="模拟关闭"
                    onPress={async () => {
                        try {
                            await actions.flushDrafts();
                            closed.set("已关闭");
                        } catch {
                            closed.set("关闭被未保存草稿阻止");
                        }
                    }}
                />
                <Btn
                    label="恢复磁盘写入"
                    onPress={() => {
                        fault = false;
                    }}
                />
                <Text>{closed()}</Text>
            </View>
        </View>
    );
}
mount(Harness);
