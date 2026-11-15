import { test, expect } from "nsh/test";
import {
    DEFAULT_SETTINGS,
    insertHistory,
    filterHistory,
    pruneHistory,
    parseSnippetImport,
    notificationMatches,
    modelEndpoint,
    validateSettings,
} from "./domain";
import type { HistoryEntry } from "./types";
function row(
    id: string,
    content: string,
    date = 10,
    isPinned = false,
): HistoryEntry {
    return {
        id,
        type: "text",
        content,
        title: content,
        sourceApp: "Notes",
        date,
        isPinned,
    };
}
test("repeated content becomes newest and retains pin while text/image stay distinct", () => {
    const image = {
        ...row("img", "same"),
        type: "image" as const,
        mediaPath: "/private/image.png",
    };
    const result = insertHistory(
        [row("old", "same", 1, true), row("other", "other"), image],
        row("new", "same", 20),
        DEFAULT_SETTINGS,
    );
    expect(result.map((r) => r.id)).toEqual(["new", "other", "img"]);
    expect(result[0]?.isPinned).toBe(true);
});
test("retention and count never delete pinned rows", () => {
    const settings = {
        ...DEFAULT_SETTINGS,
        historyLimit: 1,
        historyRetentionDays: 1,
    };
    const result = pruneHistory(
        [
            row("pin", "old", 0, true),
            row("recent", "r", 200000000),
            row("second", "s", 200000000),
            row("expired", "e", 0),
        ],
        settings,
        200000001,
    );
    expect(result.map((r) => r.id)).toEqual(["pin", "recent"]);
});
test("search combines type and source with case insensitive body query", () => {
    const rows = [
        row("a", "Needle"),
        { ...row("b", "needle"), sourceApp: "Safari" },
        { ...row("c", "needle"), type: "pdf" as const },
    ];
    expect(
        filterHistory(rows, "NEEDLE", "text", "Notes").map((r) => r.id),
    ).toEqual(["a"]);
});
test("imports reject dangling folder references and duplicate IDs", () => {
    let failed = 0;
    for (const data of [
        {
            version: 1,
            folders: [],
            snippets: [
                { id: "s", title: "t", content: "c", folderId: "missing" },
            ],
        },
        {
            version: 1,
            folders: [
                { id: "f", name: "One" },
                { id: "f", name: "Two" },
            ],
            snippets: [],
        },
    ]) {
        try {
            parseSnippetImport(JSON.stringify(data));
        } catch {
            failed++;
        }
    }
    expect(failed).toBe(2);
    const imported = parseSnippetImport(
        JSON.stringify({
            version: 1,
            folders: [{ id: "f", name: "Folder" }],
            snippets: [
                { id: "s", title: "Title", content: "Text", folderId: "f" },
            ],
        }),
    );
    expect(imported.snippets[0]?.content).toBe("Text");
});
test("blocked notification keyword wins over allow keyword", () => {
    expect(
        notificationMatches(
            { title: "验证码", content: "广告 123" },
            "验证码",
            "广告",
        ),
    ).toBe(false);
    expect(
        notificationMatches(
            { title: "验证码", content: "123" },
            "验证码",
            "广告",
        ),
    ).toBe(true);
});
test("model endpoint keeps custom prefix and rejects credential or public HTTP URL", () => {
    expect(modelEndpoint("http://127.0.0.1:3425")).toBe(
        "http://127.0.0.1:3425/v1/chat/completions",
    );
    expect(
        modelEndpoint("https://example.com/custom/chat/completions", "models"),
    ).toBe("https://example.com/custom/models");
    let failed = 0;
    for (const url of [
        "http://example.com/v1",
        "https://user:pass@example.com/v1",
    ]) {
        try {
            modelEndpoint(url);
        } catch {
            failed++;
        }
    }
    expect(failed).toBe(2);
});
test("settings never accept invalid port or non encrypted remote relay", () => {
    let failed = 0;
    for (const change of [
        { port: 65536 },
        { port: 1.5 },
        { relayEnabled: true, relayEndpoint: "ws://example.com" },
    ]) {
        try {
            validateSettings({ ...DEFAULT_SETTINGS, ...change });
        } catch {
            failed++;
        }
    }
    expect(failed).toBe(3);
});
