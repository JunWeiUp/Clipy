// Deferred render lifecycle fixture; no native file deletion or save panel is used.
import { mount, signal, View, Text, host } from "nsh";
import { ImageEditor } from "./ImageEditor";
import { Btn } from "../ui/primitives";
import fixture from "./fixtures/red-blue.png";
function Harness() {
    const open = signal(true),
        pending = signal(false),
        released = signal(false),
        dialog = signal(false);
    let finish: ((value: any) => void) | undefined;
    const actions = {
        invoke: async (name: string, payload: any) => {
            if (name === "image.render")
                return new Promise((resolve) => {
                    finish = resolve;
                    pending.set(true);
                });
            if (name === "files.saveCopy") {
                dialog.set(true);
                return { path: fixture.url };
            }
            if(name==="image.commit"){if(host.params.failCommit)return undefined;released.set(payload.path===fixture.url);return {committed:true,id:"fixture-committed"};}
            if (name === "image.releaseOutput") {
                released.set(payload.path === fixture.url);

            return true;
            }
            return true;
        },
    };
    return (
        <View class="flex-1">
            <If when={open()} else={<Text>editor closed</Text>}>
                <ImageEditor
                    path={fixture.url}
                    actions={actions}
                    onClose={() => open.set(false)}
                />
            </If>
            <View class="flex-row">
                <If when={pending()}>
                    <Btn
                        label="完成后台渲染"
                        onPress={() => {
                            pending.set(false);
                            finish?.({ path: fixture.url });
                        }}
                    />
                </If>
                <Text>{released() ? "output released" : ""}</Text>
                <Text>
                    {dialog() ? "save dialog opened" : "no save dialog"}
                </Text>
            </View>
        </View>
    );
}
mount(Harness);
