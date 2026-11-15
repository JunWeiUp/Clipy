import { open, test, expect } from "nsh/test";
test("wordbook requests open the list despite cached prefill, while local sidebar and new lookup routes still work", async () => {
    const app = await open("./WordBookRoutingHarness.tsx", {
        width: 1140,
        height: 850,
    });
    await app.press("label:单词本 >> nth=0");
    expect(app.texts()).toContain("saved-word");
    expect(app.shows("label:输入单词或需要翻译的句子")).toBe(false);
    await app.press("label:单词查询");
    expect(app.value("label:输入单词或需要翻译的句子")).toBe("cached-word");
    await app.press("label:单词表");
    expect(app.texts()).toContain("saved-word");
    await app.press("模拟查词入口");
    expect(app.value("label:输入单词或需要翻译的句子")).toBe("new-query-word");
    await app.press("label:单词表");
    await app.press("模拟空剪贴板查词入口");
    expect(app.shows("label:输入单词或需要翻译的句子")).toBe(true);
    expect(app.value("label:输入单词或需要翻译的句子")).toBe("");
    expect(app.texts().includes("saved-word")).toBe(false);
});
