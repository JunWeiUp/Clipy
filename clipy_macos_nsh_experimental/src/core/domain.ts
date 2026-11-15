import type {
    HistoryEntry,
    HistoryType,
    Settings,
    Snippet,
    Folder,
} from "./types";

export const DEFAULT_SETTINGS: Settings = {
    language: "zh-CN",
    theme: "system",
    historyLimit: 1000,
    historyRetentionDays: 0,
    excludedApps: [],
    recentAnnotationColors: [],
    captureTranslationBackend: "system",
    encryptHistory: false,
    ocrEnabled: true,
    syncEnabled: false,
    deviceName: "Clipy TSX",
    port: 5567,
    relayEnabled: false,
    relayEndpoint: "",
    notificationsEnabled: true,
    notificationSound: false,
    keywords: "",
    blockedKeywords: "",
    lookupShortcut: "ctrl+alt+mod+d",
    searchShortcut: "ctrl+alt+mod+f",
    screenshotShortcut: "ctrl+alt+mod+5",
    launchAtLogin: false,
    captureMode: "region",
    captureAction: "copy",
    autoSave: false,
    captureDirectory: "",
    fps: 30,
    systemAudio: false,
    microphone: false,
    camera: false,
};
Object.assign(DEFAULT_SETTINGS, {
    stylusPressure: false,
    showGuides: true,
    rememberTool: false,
    showTooltips: true,
    showToolShortcuts: true,
    smartHighlighter: false,
    lastAnnotationTool: "pen",
    beautify: false,
    beautifyPadding: 48,
    beautifyRadius: 12,
    beautifyShadow: 20,
    brightness: 0,
    contrast: 1,
    saturation: 1,
    sharpness: 0,
    captureMagnifier: true,
    captureSnapping: true,
    highlightClicks: false,
    showKeys: false,
    keyMode: "shortcuts",
    hideHUD: false,
    onboardingComplete: false,
    showHiddenIcons: false,
    notificationBanner: false,
    thumbnailEnabled: true,
    stackThumbnails: true,
    thumbnailPosition: "bottomRight",
    thumbnailScale: 1,
    captureCursor: false,
    captureSound: false,
    downscaleRetina: false,
    saveFormat: "png",
    saveQuality: 85,
    scrollMaxHeight: 20000,
    scrollAutomatic: false,
    scrollSpeed: 3,
    scrollFreezeHeader: true,
});

export function filterHistory(
    rows: HistoryEntry[],
    query = "",
    type: HistoryType | "all" = "all",
    source = "",
): HistoryEntry[] {
    const q = query.trim().toLocaleLowerCase();
    return rows.filter(
        (r) =>
            (type === "all" || r.type === type) &&
            (!source || r.sourceApp === source) &&
            (!q ||
                `${r.title}\n${r.content}\n${r.ocrText || ""}\n${r.sourceApp}`
                    .toLocaleLowerCase()
                    .includes(q)),
    );
}
export function pruneHistory(
    rows: HistoryEntry[],
    settings: Settings,
    now: number,
): HistoryEntry[] {
    const retained = rows.filter(
        (r) =>
            r.isPinned ||
            !settings.historyRetentionDays ||
            now - r.date < settings.historyRetentionDays * 86400000,
    );
    let count = 0;
    return retained.filter(
        (r) => r.isPinned || ++count <= settings.historyLimit,
    );
}
export function insertHistory(
    rows: HistoryEntry[],
    entry: HistoryEntry,
    settings: Settings,
): HistoryEntry[] {
    const duplicate = rows.find(
        (r) =>
            r.type === entry.type &&
            (r.mediaId && entry.mediaId
                ? r.mediaId === entry.mediaId
                : r.content === entry.content &&
                  r.mediaPath === entry.mediaPath),
    );
    return pruneHistory(
        [
            { ...entry, isPinned: duplicate?.isPinned || entry.isPinned },
            ...rows.filter(
                (r) =>
                    r.id !== entry.id &&
                    !(
                        r.type === entry.type &&
                        (r.mediaId && entry.mediaId
                            ? r.mediaId === entry.mediaId
                            : r.content === entry.content &&
                              r.mediaPath === entry.mediaPath)
                    ),
            ),
        ],
        settings,
        entry.date,
    );
}
export function validateSettings(settings: Settings): void {
    if (
        !Number.isInteger(settings.port) ||
        settings.port < 1 ||
        settings.port > 65535
    )
        throw Error("端口必须为 1–65535 的整数");
    if (
        !Number.isInteger(settings.historyLimit) ||
        settings.historyLimit < 1 ||
        settings.historyLimit > 100000
    )
        throw Error("历史数量必须为 1–100000");
    if (
        !Number.isInteger(settings.historyRetentionDays) ||
        settings.historyRetentionDays < 0
    )
        throw Error("保留天数必须为非负整数");
    if (!settings.deviceName.trim() || settings.deviceName.length > 128)
        throw Error("设备名称必须为 1–128 字");
    if (![15, 24, 25, 30, 50, 60].includes(settings.fps))
        throw Error("不支持的录屏帧率");
    if (settings.relayEnabled && !/^wss:\/\//i.test(settings.relayEndpoint))
        throw Error("公网中继地址必须使用 wss://");
}
export function parseSnippetImport(json: string): {
    folders: Folder[];
    snippets: Snippet[];
} {
    if (json.length > 8 * 1024 * 1024) throw Error("导入文件不能超过 8 MiB");
    const data = JSON.parse(json);
    if (
        data?.version !== 1 ||
        !Array.isArray(data.folders) ||
        !Array.isArray(data.snippets)
    )
        throw Error("片段文件格式无效");
    if (data.folders.length > 1000 || data.snippets.length > 10000)
        throw Error("导入数量超出上限");
    const ids = new Set<string>();
    for (const f of data.folders) {
        if (
            typeof f.id !== "string" ||
            !f.id ||
            typeof f.name !== "string" ||
            !f.name.trim() ||
            ids.has(f.id)
        )
            throw Error("文件夹格式无效或 ID 重复");
        ids.add(f.id);
    }
    const snippets = new Set<string>();
    for (const s of data.snippets) {
        if (
            typeof s.id !== "string" ||
            !s.id ||
            typeof s.title !== "string" ||
            typeof s.content !== "string" ||
            s.content.length > 1024 * 1024 ||
            !ids.has(s.folderId) ||
            snippets.has(s.id)
        )
            throw Error("片段格式无效、ID 重复或文件夹缺失");
        snippets.add(s.id);
    }
    return {
        folders: data.folders.map((f: Folder) => ({
            id: f.id,
            name: f.name,
            shortcut: f.shortcut,
        })),
        snippets: data.snippets.map((s: Snippet) => ({
            id: s.id,
            title: s.title,
            content: s.content,
            folderId: s.folderId,
            shortcut: s.shortcut,
        })),
    };
}
export function notificationMatches(
    value: { title: string; content: string },
    keywords: string,
    blocked: string,
): boolean {
    const text = `${value.title}\n${value.content}`.toLocaleLowerCase();
    const split = (s: string) =>
        s
            .split(/[,，]/)
            .map((w) => w.trim().toLocaleLowerCase())
            .filter(Boolean);
    return (
        !split(blocked).some((w) => text.includes(w)) &&
        (!split(keywords).length ||
            split(keywords).some((w) => text.includes(w)))
    );
}
export function modelEndpoint(
    base: string,
    kind: "chat/completions" | "models" = "chat/completions",
): string {
    let url: URL;
    try {
        url = new URL(base.trim());
    } catch {
        throw Error("接口地址无效");
    }
    if (url.username || url.password || url.hash || url.search)
        throw Error("接口地址不能包含用户名、密码、查询或片段");
    const loopback = ["127.0.0.1", "localhost", "[::1]", "::1"].includes(
        url.hostname.toLowerCase(),
    );
    if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))
        throw Error("远程接口必须使用 HTTPS；HTTP 仅支持本机回环");
    let p = url.pathname
        .replace(/\/+$/, "")
        .replace(/\/(chat\/completions|models)$/, "");
    if (!p) p = "/v1";
    url.pathname = `${p}/${kind}`;
    return url.toString();
}
