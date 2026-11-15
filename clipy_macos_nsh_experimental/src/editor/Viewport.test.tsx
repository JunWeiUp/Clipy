import { test, open, expect } from "nsh/test";
import { screenToImage, imageOffset, anchoredPan } from "./viewport";
test("viewport anchor math preserves original image coordinates across scale and pan", () => {
    const view = { width: 800, height: 600 },
        image = { width: 400, height: 300 },
        point = { x: 420, y: 310 };
    const original = screenToImage(point, view, image, 1, { x: 0, y: 0 });
    const pan = anchoredPan(point, original, view, image, 2);
    expect(screenToImage(point, view, image, 2, pan)).toEqual(original);
    expect(imageOffset(view, image, 2, pan)).toEqual({ x: -20, y: -10 });
});
test("native editor zoom then hand-pan exports the correct original rectangle coordinates", async () => {
    const app = await open("./EditorTransformHarness.tsx", {
        width: 1140,
        height: 800,
        platform: "macos",
    });
    await app.press("label:缩放菜单");await app.chooseMenuItem("100%");await app.keyboard.press("mod+plus");
    await app.press("label:矩形");
    await app.drag("label:标注画布", { x: 20, y: 10 });
    await app.press("保存 PNG");
    expect(app.texts()).toContain('{"first":[32,24],"last":[48,32]}');
    await app.keyboard.press("mod+z");
    await app.press("label:抓手");
    await app.drag("label:标注画布", { x: 20, y: 10 });
    await app.press("label:矩形");
    await app.drag("label:标注画布", { x: 20, y: 10 });
    await app.press("保存 PNG");
    expect(app.texts()).toContain('{"first":[16,16],"last":[32,24]}');
    await app.setViewport(900, 600);
    expect(app.shows("label:抓手")).toBe(true);
    try {
        await app.screenshot("/tmp/clipy-nsh-editor-zoom-macos.png");
    } catch (error) {
        if (!String(error).includes("a screenshot needs a real platform"))
            throw error;
    }
});
