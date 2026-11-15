import { test, open, expect } from "nsh/test";
const openSettings = async () => {
    const app = await open("./ModelConfigHarness.tsx", {
        width: 1140,
        height: 950,
    });
    await app.press("label:API 设置 >> nth=0");
    return app;
};
test("safe saved model metadata restores the form without hydrating or displaying a key", async () => {
    const app = await openSettings();
    expect(app.value("label:接口地址")).toBe("http://127.0.0.1:1");
    expect(app.value("label:模型名称")).toBe("fixture-small");
    expect(app.value("label:API Key")).toBe("");
    expect(app.texts()).toContain("API Key 已保存（不显示密钥）");
    expect(
        app.texts().some((text) => text.includes("never-display-fixture-key")),
    ).toBe(false);
});
test("pristine drafts hydrate new versions while edited drafts survive metadata updates and reopen restores saved values", async () => {
    const app = await openSettings();
    await app.press("推送外部配置");
    expect(app.value("label:模型名称")).toBe("external-large");
    await app.type("label:模型名称", " draft");
    await app.press("推送外部配置");
    expect(app.value("label:模型名称")).toBe("external-large draft");
    await app.press("label:单词表");
    await app.press("label:API 设置 >> nth=0");
    expect(app.value("label:模型名称")).toBe("external-large");
    expect(app.value("label:API Key")).toBe("");
});
test("saving an empty key requires explicit deletion and updates the safe stored-key indicator", async () => {
    const app = await openSettings();
    expect(app.texts()).toContain("留空保存将删除已存密钥。");
    await app.press("保存");
    expect(app.dialogs().at(-1)?.title).toBe("删除已存 API Key？");
    expect(app.texts().some((text) => text.includes('"configured":true'))).toBe(
        false,
    );
    app.onDialog(() => "删除并保存");
    await app.press("保存");
    expect(app.texts()).toContain('{"configured":true,"keyMode":"deleted"}');
    expect(app.texts()).toContain("尚未保存 API Key");
});
