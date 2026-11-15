import { open, test, expect } from "nsh/test";
test("a render arriving after editor close is released without opening a save dialog", async () => {
    const app = await open("./EditorCleanupHarness.tsx", {
        width: 1140,
        height: 800,
    });
    await app.press("保存 PNG");
    await app.press("返回");
    expect(app.texts()).toContain("editor closed");
    await app.press("完成后台渲染");
    expect(app.texts()).toContain("output released");
    expect(app.texts()).toContain("no save dialog");
});
test("a visible editor requests the user save location and then releases private output", async () => {
    const app = await open("./EditorCleanupHarness.tsx", {
        width: 1140,
        height: 800,
    });
    await app.press("保存 PNG");
    await app.press("完成后台渲染");
    expect(app.texts()).toContain("save dialog opened");
    expect(app.texts()).toContain("output released");
});

test("an undefined commit result keeps the editor open and reports the preserved draft",async()=>{const app=await open('./EditorCleanupHarness.tsx',{width:1140,height:800,host:{params:{failCommit:true}}});await app.press('label:完成');await app.press('完成后台渲染');await app.waitUntil(()=>app.texts().some(text=>text.includes('保存截图历史失败')));expect(app.shows('label:标注画布')).toBe(true);expect(app.texts()).toContain('output released');expect(app.texts()).not.toContain('editor closed');});
