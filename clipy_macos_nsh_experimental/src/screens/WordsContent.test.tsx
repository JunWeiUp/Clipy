import { test, expect, open } from "nsh/test";
test("dictionary displays every definition, phrase and bilingual example", async () => {
    const app = await open("./WordsHarness.tsx", { width: 1140, height: 1000 });
    for (const text of [
        "Definition one",
        "Definition two",
        "hello world",
        "短语释义",
        "Hello, friend.",
        "例句译文",
    ])
        expect(app.texts()).toContain(text);
});
test("word-book familiarity and hidden definition controls affect actual visible rows", async () => {
    const app = await open("./WordsHarness.tsx", { width: 1140, height: 1000 });
    expect(app.texts()).toContain("你好");
    await app.press("隐藏中文释义");
    expect(app.texts().includes("你好")).toBe(false);
    await app.press("label:hello");
    expect(app.shows("label:hello")).toBe(false);
    await app.press("熟悉 (1)");
    expect(app.shows("label:hello")).toBe(true);
});
