import { test, expect, open } from "nsh/test";
test("English switches real page labels and switching back retains Chinese controls", async () => {
    const app = await open("./LocaleHarness.tsx", { width: 1140, height: 760 });
    expect(app.texts()).toContain("通用");
    await app.press("English");
    expect(app.texts()).toContain("General");
    expect(app.texts()).toContain("Launch at login");
    expect(app.texts()).toContain("Settings");
    await app.wait(100);
    try {
        await app.screenshot("/tmp/clipy-nsh-english-settings.png");
    } catch (e) {
        if (!String(e).includes("a screenshot needs a real platform")) throw e;
    }
    await app.press("Chinese");
    expect(app.texts()).toContain("通用");
    expect(app.texts()).toContain("登录时启动");
});
test("English labels remain active across the main feature pages", async () => {
    const app = await open("./LocaleHarness.tsx", { width: 1140, height: 760 });
    await app.press("English");
    for (const [label, expected] of [
        ["History", "No history yet"],
        ["Snippets", "Snippet library"],
        ["Devices", "My devices"],
        ["Notifications", "Phone notifications"],
        ["Tools", "Password generator"],
    ]) {
        await app.press(`label:${label} >> nth=0`);
        expect(app.texts()).toContain(expected);
    }
    await app.wait(100);
    try {
        await app.screenshot("/tmp/clipy-nsh-english-tools.png");
    } catch (e) {
        if (!String(e).includes("a screenshot needs a real platform")) throw e;
    }
});
test("English never translates user folder names, snippet titles or snippet content", async () => {
    const app = await open("./LocaleContentHarness.tsx", {
        width: 1140,
        height: 760,
    });
    expect(app.shows("label:历史")).toBe(true);
    expect(app.shows("label:通用")).toBe(true);
    expect(app.texts()).toContain("文件");
});
test("all English feature surfaces render in a native desktop-sized viewport", async () => {
    for (const page of [
        "history",
        "snippets",
        "devices",
        "notifications",
        "settings",
        "words",
        "tools",
        "relay",
        "capture",
        "recording",
        "video",
        "onboarding",
    ]) {
        const app = await open("./LocaleHarness.tsx", {
            width: 1140,
            height: 760,
            host: { params: { language: "en", page } },
        });
        expect(app.texts().length > 5).toBe(true);
        expect(
            app.texts().filter((text) => /[\u3400-\u9fff]/.test(text)),
        ).toEqual([]);
        try {
            await app.screenshot(`/tmp/clipy-nsh-english-${page}.png`);
        } catch (error) {
            if (!String(error).includes("a screenshot needs a real platform"))
                throw error;
        }
        app.dispose();
    }
});
