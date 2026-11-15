import { test, expect, open } from "nsh/test";
test("history date and source filters affect the actual result rows", async () => {
    const app = await open("./HistoryHarness.tsx", {
        width: 1140,
        height: 760,
    });
    expect(app.shows("label:hello today")).toBe(true);
    expect(app.shows("label:older JSON")).toBe(true);
    await app.press("今天");
    expect(app.shows("label:hello today")).toBe(true);
    expect(app.shows("label:older JSON")).toBe(false);
    await app.press("全部");
    await app.press("Terminal");
    expect(app.shows("label:hello today")).toBe(false);
    expect(app.shows("label:older JSON")).toBe(true);
});
test("history JSON classification and invalid regex do not retain an invisible preview", async () => {
    const app = await open("./HistoryHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.press("label:JSON");
    expect(app.shows("label:older JSON")).toBe(true);
    expect(app.shows("label:hello today")).toBe(false);
    await app.press("全部历史");
    await app.press("正则");
    await app.type("label:搜索内容、路径或来源应用", "[");
    expect(app.texts()).toContain("暂无历史记录");
    expect(app.shows("label:older JSON")).toBe(false);
});
test("history mounts at most 100 rows initially and searches OCR beyond the visible page", async () => {
    const app = await open("./HistoryLargeHarness.tsx", {
        width: 1140,
        height: 760,
    });
    expect(app.shows("label:entry-99")).toBe(true);
    expect(app.shows("label:entry-100")).toBe(false);
    await app.press("加载更多历史（已显示 100 / 150）");
    expect(app.shows("label:entry-149")).toBe(true);
    await app.type("label:搜索内容、路径或来源应用", "recognized needle");
    expect(app.shows("label:entry-0")).toBe(true);
    expect(app.shows("label:entry-1")).toBe(false);
});
