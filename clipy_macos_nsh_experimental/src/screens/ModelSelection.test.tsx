import { open, test, expect } from "nsh/test";
test("model retrieval, independent filtering, and selection update the intended model field", async () => {
    const app = await open("./ModelsHarness.tsx", { width: 1140, height: 900 });
    await app.press("label:API 设置 >> nth=0");
    expect(app.value("label:模型名称")).toBe("fixture-small");
    await app.press("获取模型");
    expect(app.shows("label:fixture-small")).toBe(true);
    expect(app.shows("label:other-large")).toBe(true);
    await app.type("label:筛选模型", "large");
    expect(app.shows("label:fixture-small")).toBe(false);
    expect(app.shows("label:other-large")).toBe(true);
    await app.press("label:other-large");
    expect(app.value("label:模型名称")).toBe("other-large");
    expect(app.value("label:筛选模型")).toBe("large");
});
