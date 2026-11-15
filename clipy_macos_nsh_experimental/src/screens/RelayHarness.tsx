// Relay form/approval tests. All identities and request envelopes are synthetic.
import { mount, signal, Text, View, host } from "nsh";
import { setLocale } from "../ui/locale";
import { RootScreen } from "./RootScreen";
function Harness() {
    const summary = signal("");
    const state = signal<any>({
        page: "relay",
        history: [],
        snippets: [],
        folders: [],
        devices: [],
        notifications: [],
        settings: { language: String(host.params.language || "zh-CN") },
        invitation:
            host.params.mode === "invite"
                ? {
                      short_link: "common-relay://fixture-only",
                      qrImage:
                          "data:image/png;base64,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",
                  }
                : undefined,
        relay:
            host.params.mode === "join"
                ? { joinPending: true, pairingCode: "ABCD-1234" }
                : {
                      authRejected: host.params.authRejected === true,
                      url: "wss://example.invalid/relay/v1/ws",
                      device: "self-fixture",
                      group: "fixture",
                      members: [
                          {
                              device: "self-fixture",
                              name: "Fixture admin",
                              manager: true,
                          },
                      ],
                      pending: [
                          {
                              device: "new-fixture",
                              name: "New fixture",
                              pairingCode: "ABCD-1234",
                              request: {
                                  payload: "fixture-request",
                                  signature: "fixture-signature",
                              },
                          },
                      ],
                  },
    });
    setLocale(String(host.params.language || "zh-CN"));
    const actions = {
        invoke: async (name: string, payload: any) => {
            if (name === "clipboard.write") {
                summary.set(
                    JSON.stringify({
                        copied: payload.text === "common-relay://fixture-only",
                        sensitive: payload.sensitive === true,
                    }),
                );
                return true;
            }
            if (name === "relay.configure") {
                summary.set(
                    JSON.stringify({
                        configured: true,
                        url: payload.url,
                        device: payload.device,
                        hasToken: !!payload.token,
                        hasConfig: !!payload.config,
                    }),
                );
                return { configured: true };
            }
            if (name === "relay.approve") {
                summary.set(
                    JSON.stringify({
                        approved: true,
                        manager: payload.manager,
                        signed: payload.request?.payload === "fixture-request",
                    }),
                );
                state.set({
                    ...state(),
                    relay: { ...state().relay, pending: [] },
                });
                return true;
            }
            if (name === "relay.cancelJoin") {
                state.set({ ...state(), relay: {} });
                return true;
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
