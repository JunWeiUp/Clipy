import { test, expect, open } from "nsh/test";
const settings = (app: any) => {
    const raw = Object.values(app.storage()).find(
        (value: any) =>
            typeof value === "string" && value.includes('"settings"'),
    ) as string;
    return raw ? JSON.parse(raw).settings : {};
};
test("capture action, thumbnail, quality and format save using canonical preference names", async () => {
    const app = await open("./CaptureSettingsHarness.tsx", {
        width: 1140,
        height: 900,
    });
    await app.press("自动保存截图");
    await app.press("保存并复制");
    expect(settings(app).autoSave).toBe(true);
    expect(settings(app).captureAction).toBe("saveAndCopy");
    await app.press("输出与预览");
    await app.press("完成后显示浮动缩略图");
    await app.press("JPEG");
    await app.clear("label:图片质量（0–100）");
    await app.type("label:图片质量（0–100）", "93");
    await app.submit("label:图片质量（0–100）");
    expect(settings(app).thumbnailEnabled).toBe(false);
    expect(settings(app).saveFormat).toBe("jpeg");
    expect(settings(app).saveQuality).toBe(93);
});
test("scroll and editor preferences persist actual supported canonical keys", async () => {
    const app = await open("./CaptureSettingsHarness.tsx", {
        width: 1140,
        height: 1000,
    });
    await app.press("滚动与标注");
    await app.press("自动滚动");
    await app.clear("label:自动滚动速度");
    await app.type("label:自动滚动速度", "5");
    await app.submit("label:自动滚动速度");
    await app.press("记住上次使用的工具");
    await app.press("画笔压感");
    expect(settings(app).scrollAutomatic).toBe(true);
    expect(settings(app).scrollSpeed).toBe(5);
    expect(settings(app).rememberTool).toBe(true);
    expect(settings(app).stylusPressure).toBe(true);
});
