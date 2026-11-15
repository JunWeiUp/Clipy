import { test, expect } from "nsh/test";
import { normalizeShortcut, assertShortcutFree } from "./shortcuts";
test("shortcut aliases and modifier order cannot hide duplicate bindings", () => {
    expect(normalizeShortcut("Command+Control+Shift+D")).toBe(
        normalizeShortcut("shift+ctrl+mod+d"),
    );
    let error = "";
    try {
        assertShortcutFree("Control+Option+D", "snippet:1", [
            { owner: "folder:2", chord: "alt+ctrl+d" },
        ]);
    } catch (e) {
        error = String(e);
    }
    expect(error.includes("已被其他功能使用")).toBe(true);
    assertShortcutFree("", "snippet:1", [
        { owner: "folder:2", chord: "alt+ctrl+d" },
    ]);
    assertShortcutFree("ctrl+alt+d", "snippet:1", [
        { owner: "snippet:1", chord: "alt+ctrl+d" },
    ]);
});
