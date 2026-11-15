import { test, open, expect } from "nsh/test";
const surfaces = [
    { id: "history", page: "history" },
    { id: "snippets", page: "snippets" },
    { id: "devices", page: "devices" },
    { id: "notifications", page: "notifications" },
    { id: "settings", page: "settings" },
    { id: "words", page: "words" },
    { id: "tools", page: "tools" },
    { id: "relay", page: "relay" },
    { id: "capture", page: "capture" },
    { id: "recording", page: "recording" },
    { id: "video", page: "video" },
    { id: "onboarding", page: "onboarding" },
    { id: "capture-settings", page: "settings", section: "截图" },
    { id: "output-settings", page: "settings", section: "输出与预览" },
    { id: "scroll-settings", page: "settings", section: "滚动与标注" },
    { id: "beautify-settings", page: "settings", section: "美化与特效" },
];
for (const language of ["zh-CN", "en"])
    for (const colorScheme of ["light", "dark"] as const)
        test(`visual catalogue ${language} ${colorScheme}`, async () => {
            for (const surface of surfaces) {
                const app = await open("./LocaleHarness.tsx", {
                    width: 1140,
                    height: 760,
                    colorScheme,
                    host: {
                        params: {
                            language,
                            page: surface.page,
                            section: surface.section,
                        },
                    },
                });
                expect(app.texts().length > 5).toBe(true);
                if (language === "en")
                    expect(
                        app.texts().filter((text) => /[一-鿿]/.test(text)),
                    ).toEqual([]);
                try {
                    await app.screenshot(
                        `/tmp/clipy-nsh-visual-${language}-${colorScheme}-${surface.id}.png`,
                    );
                } catch (error) {
                    if (
                        !String(error).includes(
                            "a screenshot needs a real platform",
                        )
                    )
                        throw error;
                }
                app.dispose();
            }
        });
