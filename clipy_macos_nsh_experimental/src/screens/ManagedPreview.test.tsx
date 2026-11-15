import { open, test, expect } from "nsh/test";
test("the default managed row requests one lease, asynchronous path fill mounts its image, and reentry requests again", async () => {
    const app = await open("./ManagedPreviewHarness.tsx", {
        width: 1140,
        height: 800,
    });
    await app.waitFor("id:history-media-image");
    expect(app.texts()).toContain("requests:1");
    expect(
        app.texts().join("\n").includes("media:internal-fixture-reference"),
    ).toBe(false);
    await app.press("回填其它模型字段");
    await app.wait(80);
    expect(app.texts()).toContain("requests:1");
    await app.press("偏好设置…");
    await app.press("label:历史");
    await app.waitFor("id:history-media-image");
    await app.wait(80);
    expect(app.texts()).toContain("requests:2");
});
test("managed PDF content is a friendly placeholder instead of an internal media reference", async () => {
    const app = await open("./ManagedPreviewHarness.tsx", {
        width: 1140,
        height: 800,
        host: { params: { type: "pdf" } },
    });
    await app.waitFor("text:PDF 已准备好，可通过下方访达入口查看。");
    expect(app.texts()).toContain("requests:1");
    expect(
        app.texts().join("\n").includes("media:internal-fixture-reference"),
    ).toBe(false);
    expect(app.shows("id:history-media-image")).toBe(false);
});
