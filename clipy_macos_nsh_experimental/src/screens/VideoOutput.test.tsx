import { open, test, expect } from "nsh/test";
test("video scale and quality are explicit export arguments and metadata comes from the result", async () => {
    const app = await open("./VideoOutputHarness.tsx", {
        width: 1140,
        height: 1200,
    });
    await app.press("75%");
    await app.press("label:中");
    await app.press("导出 MP4");
    expect(app.texts()).toContain(
        '{"scale":0.75,"quality":"medium","format":"mp4"}',
    );
    expect(app.value("label:实际输出尺寸")).toBe("320 × 180");
    expect(app.value("label:文件大小")).toBe("1.00 MiB");
    await app.press("25%");
    await app.press("label:低");
    await app.press("导出 GIF");
    expect(app.texts()).toContain(
        '{"scale":0.25,"quality":"low","format":"gif"}',
    );
    expect(app.value("label:实际帧率")).toBe("6.00 fps");
    expect(app.texts()).toContain("GIF 已导出，预览继续播放原视频。");
});
