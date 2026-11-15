// Isolated test entry: no production data, credentials or system operations.
import { mount, signal, View, Text } from "nsh";
import { Onboarding } from "./Onboarding";
function Harness() {
    const done = signal(false);
    const state = () => ({
        settings: { deviceName: "Test Mac", port: 5567 },
        devices: [],
    });
    const actions = {
        navigate: () => done.set(true),
        saveSettings: () => {},
        invoke: async () => ({}),
    };
    return (
        <View class="flex-1">
            <If when={!done()} else={<Text>已开始使用</Text>}>
                <Onboarding state={state} actions={actions} />
            </If>
        </View>
    );
}
mount(Harness);
