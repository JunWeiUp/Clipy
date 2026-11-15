import { test, expect, open } from "nsh/test";
test("relay advanced JSON validates locally and only sends parsed config when valid", async () => {
    const app = await open("./RelayHarness.tsx", { width: 1140, height: 760 });
    await app.press("中继设置");
    await app.press("高级接入配置");
    await app.type("label:公网 Key（留空保持）", "fixture-token");
    await app.type("label:接入配置 JSON（隐藏输入，最多 64 KiB）", "{");
    await app.press("保存");
    expect(app.texts()).toContain("接入配置 JSON 无效，请检查格式。");
    await app.clear("label:接入配置 JSON（隐藏输入，最多 64 KiB）");
    await app.type(
        "label:接入配置 JSON（隐藏输入，最多 64 KiB）",
        '{"app":"fixture"}',
    );
    await app.press("保存");
    expect(app.texts()).toContain(
        '{"configured":true,"url":"wss://example.invalid/relay/v1/ws","device":"self-fixture","hasToken":true,"hasConfig":true}',
    );
});
test("manual approval sends the signed request and leaves manager disabled by default", async () => {
    const app = await open("./RelayHarness.tsx", { width: 1140, height: 760 });
    expect(app.texts()).toContain("ABCD-1234");
    await app.press("配对码一致，批准加入");
    expect(app.texts()).toContain(
        '{"approved":true,"manager":false,"signed":true}',
    );
});
test("joining status exposes pairing code and a cancellable local waiting state", async () => {
    const app = await open("./RelayHarness.tsx", {
        width: 1140,
        height: 760,
        host: { params: { mode: "join" } },
    });
    expect(app.texts()).toContain("等待加入设备组");
    expect(app.texts()).toContain("ABCD-1234");
    await app.press("放弃本次申请");
    expect(app.texts().includes("等待加入设备组")).toBe(false);
});
test("invitation QR is an in-memory image and its copy command is marked sensitive in both languages", async () => {
    for (const language of ["zh-CN", "en"])
        for (const colorScheme of ["light", "dark"] as const) {
            const app = await open("./RelayHarness.tsx", {
                width: 1140,
                height: 1000,
                colorScheme,
                host: { params: { mode: "invite", language } },
            });
            expect(app.shows("id:relay-invite-qr")).toBe(true);
            await app.press(
                language === "en" ? "Copy invitation link" : "复制邀请链接",
            );
            expect(app.texts()).toContain('{"copied":true,"sensitive":true}');
            try {
                await app.screenshot(
                    `/tmp/clipy-nsh-relay-invite-${language}-${colorScheme}.png`,
                );
            } catch (error) {
                if (
                    !String(error).includes(
                        "a screenshot needs a real platform",
                    )
                )
                    throw error;
            }
            app.dispose();
        }
});
test("authentication rejection hides cached members, invitations and every group management action", async () => {
    for (const language of ["zh-CN", "en"])
        for (const colorScheme of ["light", "dark"] as const) {
            const app = await open("./RelayHarness.tsx", {
                width: 1140,
                height: 760,
                colorScheme,
                host: {
                    params: { mode: "invite", authRejected: true, language },
                },
            });
            const text = app.texts().join("\n");
            expect(text.includes("Fixture admin")).toBe(false);
            expect(text.includes("common-relay://fixture-only")).toBe(false);
            expect(app.shows("id:relay-invite-qr")).toBe(false);
            const forbidden =
                language === "en"
                    ? [
                          "Add device",
                          "Join group",
                          "Create group",
                          "Copy invitation link",
                          "Codes match — approve",
                          "Leave group",
                          "Disband group",
                          "Rename",
                          "Remove",
                      ]
                    : [
                          "添加设备",
                          "加入已有组",
                          "创建新组",
                          "复制邀请链接",
                          "配对码一致，批准加入",
                          "退出当前组",
                          "解散设备组",
                          "改名",
                          "移除",
                      ];
            for (const label of forbidden)
                expect(app.shows(`label:${label}`)).toBe(false);
            expect(
                app.shows(
                    language === "en"
                        ? "label:Relay settings"
                        : "label:中继设置",
                ),
            ).toBe(true);
            expect(
                app.shows(language === "en" ? "label:Refresh" : "label:刷新"),
            ).toBe(true);
            expect(text).toContain(
                language === "en"
                    ? "Authentication failed. Group information is hidden; your device identity and LAN settings are preserved."
                    : "认证未通过，组信息暂时隐藏，身份与局域网配置保留。",
            );
            try {
                await app.screenshot(
                    `/tmp/clipy-nsh-relay-rejected-${language}-${colorScheme}.png`,
                );
            } catch (error) {
                if (
                    !String(error).includes(
                        "a screenshot needs a real platform",
                    )
                )
                    throw error;
            }
            app.dispose();
        }
});
