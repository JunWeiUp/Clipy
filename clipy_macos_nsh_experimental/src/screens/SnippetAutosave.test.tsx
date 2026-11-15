import { test, expect, open } from "nsh/test";
const library = (app: any) => {
    const raw = Object.values(app.storage()).find(
        (value: any) =>
            typeof value === "string" && value.includes('"snippets"'),
    ) as string | undefined;
    return raw ? JSON.parse(raw) : { snippets: [] };
};
test("snippet autosave keeps one new identity across repeated changes", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.press("新片段");
    await app.type("label:片段标题", "Draft");
    await app.type("label:写下常用内容…", "hello");
    await app.wait(400);
    expect(
        library(app).snippets.filter((s: any) => s.title === "Draft").length,
    ).toBe(1);
    await app.type("label:写下常用内容…", " world");
    await app.wait(400);
    const saved = library(app).snippets.filter((s: any) => s.title === "Draft");
    expect(saved.length).toBe(1);
    expect(saved[0].content).toBe("hello world");
});
test("switching snippets flushes the captured ID rather than the next selected row", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.press("label:One");
    await app.type("label:写下常用内容…", " edited");
    await app.press("label:Two");
    await app.type("label:写下常用内容…", " changed");
    await app.press("历史");
    await app.wait(350);
    expect(library(app).snippets.find((s: any) => s.id === "one").content).toBe(
        "first edited",
    );
    expect(library(app).snippets.find((s: any) => s.id === "two").content).toBe(
        "second changed",
    );
});
test("same-column dragging persists snippet ordering and filtering disables sorting", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.drag("label:One", { y: 70 });
    await app.wait(100);
    expect(library(app).snippets.map((s: any) => s.id)).toEqual(["two", "one"]);
    await app.type("label:搜索此文件夹", "One");
    await app.drag("label:One", { y: -70 });
    await app.wait(100);
    expect(library(app).snippets.map((s: any) => s.id)).toEqual(["two", "one"]);
});

test("folder dragging persists ordering in its own column", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.drag("label:常用", { y: 40 });
    await app.wait(100);
    expect(library(app).folders.map((f: any) => f.id)).toEqual([
        "other",
        "default",
    ]);
});
test("clearing a snippet shortcut persists an empty string through later autosaves", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.press("label:One");
    await app.press("录入快捷键");
    await app.wait(100);
    expect(
        library(app).snippets.find((s: any) => s.id === "one").shortcut,
    ).toBe("ctrl+alt+1");
    await app.press("清除快捷键");
    await app.type("label:写下常用内容…", " updated");
    await app.wait(400);
    expect(
        library(app).snippets.find((s: any) => s.id === "one").shortcut,
    ).toBe("");
});
test("folder shortcut clearing is explicit and does not resurrect the old chord", async () => {
    const app = await open("./SnippetHarness.tsx", {
        width: 1140,
        height: 760,
    });
    await app.press("文件夹设置");
    await app.press("label:录入快捷键 >> nth=1");
    await app.press("保存");
    await app.wait(100);
    expect(
        library(app).folders.find((f: any) => f.id === "default").shortcut,
    ).toBe("ctrl+alt+1");
    await app.press("文件夹设置");
    await app.press("label:清除快捷键 >> nth=1");
    await app.press("保存");
    await app.wait(100);
    expect(
        library(app).folders.find((f: any) => f.id === "default").shortcut,
    ).toBe("");
});
test("disk failure preserves the local draft, rejects close, blocks navigation, and supports retry", async () => {
    const app = await open("./SnippetFailureHarness.tsx", {
        width: 1140,
        height: 800,
    });
    await app.press("label:One");
    await app.type("label:写下常用内容…", " unsaved");
    await app.wait(400);
    expect(app.texts()).toContain("未保存草稿已保留（1），关闭前请重试。");
    await app.press("历史");
    expect(app.texts()).toContain("片段库");
    expect(app.value("label:写下常用内容…")).toBe("first unsaved");
    await app.press("模拟关闭");
    expect(app.texts()).toContain("关闭被未保存草稿阻止");
    expect(library(app).snippets[0].content).toBe("first");
    await app.press("恢复磁盘写入");
    await app.press("重试保存草稿");
    await app.wait(100);
    expect(library(app).snippets[0].content).toBe("first unsaved");
    await app.press("历史");
    expect(app.texts()).toContain("暂无历史记录");
});
