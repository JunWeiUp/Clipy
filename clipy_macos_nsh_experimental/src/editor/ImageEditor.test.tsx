import { open, test, expect } from "nsh/test";
test("editor exposes full toolset and exports a real scene after drawing", async () => {
    const app = await open("./EditorHarness.tsx", { width: 1140, height: 760 });
    expect(app.texts()).toContain("标注编辑");
    await app.press("label:矩形");
    await app.drag("label:标注画布", { x: 60, y: 40 });
    await app.press("保存 PNG");
    await app.waitFor("text:已导出场景");expect(app.texts()).toContain("已导出场景");
});
test("editor has crop transforms, rich text and six arrow variants", async () => {
    const app = await open("./EditorHarness.tsx", { width: 1140, height: 760 });
    await app.press("label:箭头");
    expect(app.texts()).toContain("↝");
    expect(app.texts()).toContain("↔");
    await app.press("label:文字");
    expect(app.texts()).toContain("B");
    expect(app.texts()).toContain("U");
    expect(app.shows("label:裁剪")).toBe(true);
    expect(app.shows("label:水平翻转")).toBe(true);
    try {
        await app.screenshot("/tmp/clipy-nsh-editor-macos.png");
    } catch (error) {
        if (!String(error).includes("a screenshot needs a real platform"))
            throw error;
    }
});
test("English annotation controls use native layout without untranslated tool labels", async () => {
    const app = await open("./EditorEnglishHarness.tsx", {
        width: 1140,
        height: 760,
    });
    expect(app.texts()).toContain("Annotation editor");
    expect(app.texts()).toContain("Arrow");
    expect(app.shows("label:Save PNG")).toBe(true);
    expect(app.texts()).toContain("Color");
    await app.wait(100);
    try {
        await app.screenshot("/tmp/clipy-nsh-editor-english-macos.png");
    } catch (error) {
        if (!String(error).includes("a screenshot needs a real platform"))
            throw error;
    }
});
test("editor reads saved defaults, records pressure points, and persists tool choice only when enabled", async () => {
    const app = await open("./EditorPreferencesHarness.tsx", {
        width: 1140,
        height: 800,
    });
    await app.drag("label:标注画布", { x: 60, y: 40 });
    await app.press("保存 PNG");
    expect(app.texts()).toContain('{"pressure":0.4,"brightness":0.1}');
    await app.press("label:矩形");
    expect(app.texts()).toContain("remembered:rectangle");
});
