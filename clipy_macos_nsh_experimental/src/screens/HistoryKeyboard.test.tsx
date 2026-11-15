import { open, test, expect } from "nsh/test";
test("history arrow, Enter, quick paste and plain paste shortcuts use the selected filtered row", async () => {
    const app = await open("./HistoryKeysHarness.tsx", {
        width: 1140,
        height: 800,
        platform: "macos",
    });
    await app.press("label:One");
    await app.keyboard.press("down");
    await app.keyboard.press("enter");
    expect(app.texts()).toContain("copy:two:true:false");
    await app.keyboard.press("mod+1");
    expect(app.texts()).toContain("copy:one:true:false");
    await app.keyboard.press("alt+mod+v");
    expect(app.texts()).toContain("copy:two:true:true");
});
test("history delete undo works while Backspace in the search input never deletes an entry", async () => {
    const app = await open("./HistoryKeysHarness.tsx", {
        width: 1140,
        height: 800,
        platform: "macos",
    });
    await app.press("label:One");
    await app.keyboard.press("delete");
    expect(app.shows("label:One")).toBe(false);
    await app.keyboard.press("mod+z");
    expect(app.shows("label:One")).toBe(true);
    await app.type("label:搜索内容、路径或来源应用", "OneX");
    await app.keyboard.press("backspace");
    expect(app.value("label:搜索内容、路径或来源应用")).toBe("One");
    expect(app.shows("label:One")).toBe(true);
});
test("history context menus expose native file actions and capture the clicked entry", async () => {
    const app = await open("./HistoryKeysHarness.tsx", {
        width: 1140,
        height: 800,
        platform: "macos",
    });
    await app.rightClick("label:Fixture file");
    expect((app.menu() || []).map((item) => item.label)).toContain(
        "粘贴文件名",
    );
    expect((app.menu() || []).map((item) => item.label)).toContain(
        "在 Finder 中显示",
    );
    await app.chooseMenuItem("粘贴文件名");
    expect(app.texts()).toContain("filenames:file");
});
