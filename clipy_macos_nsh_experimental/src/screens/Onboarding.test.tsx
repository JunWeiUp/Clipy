import { open, test, expect } from "nsh/test";
test("onboarding supports all three steps without forcing optional permissions", async () => {
    const app = await open("./OnboardingHarness.tsx", {
        width: 860,
        height: 580,
    });
    expect(app.texts()).toContain("随时唤起 Clipy");
    await app.press("继续");
    expect(app.texts()).toContain("开启需要的权限");
    await app.press("继续");
    expect(app.texts()).toContain("连接你的设备（可选）");
    await app.press("开始使用");
    expect(app.texts()).toContain("已开始使用");
});
test("onboarding may be skipped before requesting system permissions", async () => {
    const app = await open("./OnboardingHarness.tsx", {
        width: 860,
        height: 580,
    });
    await app.press("跳过");
    expect(app.texts()).toContain("已开始使用");
});
