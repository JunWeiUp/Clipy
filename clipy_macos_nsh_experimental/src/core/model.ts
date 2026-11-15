import { assertShortcutFree } from "./shortcuts";
import { signal } from "nsh";
import { randomInt, randomUUID } from "crypto";
import { lookupDictionary } from "./lookup";
import type {
    AppState,
    ModelOptions,
    HistoryEntry,
    Snippet,
    Folder,
    Page,
    PhoneNotification,
    Settings,
    WordRecord,
} from "./types";
import {
    DEFAULT_SETTINGS,
    filterHistory,
    insertHistory,
    pruneHistory,
    parseSnippetImport,
    validateSettings,
    modelEndpoint,
} from "./domain";
export * from "./types";
export * from "./domain";
const STORAGE_KEY = "clipy-tsx-state-v1";

export function createAppModel(options: ModelOptions) {
    const now = options.now || Date.now;
    const MAX_STATE_BYTES = Math.min(
        16 * 1024 * 1024,
        options.storage.maxStateBytes || 3 * 1024 * 1024,
    );
    const state = signal<AppState>({
        page: "history",
        query: "",
        history: [],
        snippets: [],
        folders: [{ id: "default", name: "常用" }],
        notifications: [],
        settings: { ...DEFAULT_SETTINGS, excludedApps: [] },
        devices: [],
        selection: null,
        selectedFolder: "default",
        message: "",
        busy: false,
        word: "",
        wordResult: null,
        words: [],
        translation: "",
        password: "",
        passwordEntropy: 0,
        undoAvailable: false,
        ready: false,
        hostAvailable: false,
    });
    let lookupAbort: AbortController | null = null;
    let closed = false,
        storageWritable = true,
        requestGeneration = 0,
        persistQueue = Promise.resolve(),
        undo: { rows: HistoryEntry[]; expires: number } | null = null;
    const patch = (next: Partial<AppState>) => {
        if (!closed) state.set({ ...state(), ...next });
    };
    const report = (message: string) => patch({ message });
    function persisted(s: AppState) {
        return JSON.stringify({
            version: 1,
            history: s.history,
            snippets: s.snippets,
            folders: s.folders,
            notifications: s.notifications,
            settings: s.settings,
            words: s.words,
        });
    }
    function commit(next: Partial<AppState>) {
        if (closed) throw Error("客户端已关闭");
        if (!state().ready) throw Error("本地数据正在加载，请稍候");
        if (!storageWritable)
            throw Error("原数据读取失败，已禁止覆盖；请先导出并修复本地数据");
        const proposed = { ...state(), ...next };
        const json = persisted(proposed);
        if (new TextEncoder().encode(json).length > MAX_STATE_BYTES)
            throw Error(
                `本地状态已达 ${MAX_STATE_BYTES / 1024 / 1024} MiB 上限，请清理历史或导出片段；媒体应保存在文件中`,
            );
        patch(next);
        persistQueue = persistQueue
            .catch(() => undefined)
            .then(() => options.storage.setItem(STORAGE_KEY, json));
        void persistQueue.catch((error) =>
            report(
                `保存失败：${error instanceof Error ? error.message : String(error)}`,
            ),
        );
        return persistQueue;
    }
    async function call<T = unknown>(
        name: string,
        payload?: unknown,
    ): Promise<T> {
        if (closed) throw Error("页面已关闭");
        return options.host.call<T>(name, payload);
    }
    async function perform<T>(work: () => Promise<T>): Promise<T | undefined> {
        try {
            return await work();
        } catch (error) {
            report(error instanceof Error ? error.message : String(error));
            return undefined;
        }
    }
    const ready = (async () => {
        try {
            const raw = await options.storage.getItem(STORAGE_KEY);
            if (raw) {
                if (new TextEncoder().encode(raw).length > MAX_STATE_BYTES)
                    throw Error("历史文件超出安全上限");
                const data = JSON.parse(raw);
                if (data.version !== 1) throw Error("本地数据版本不受支持");
                const settings = cleanSettings(data.settings);
                validateSettings(settings);
                const library = parseSnippetImport(
                    JSON.stringify({
                        version: 1,
                        folders: data.folders,
                        snippets: data.snippets,
                    }),
                );
                const history = (
                    Array.isArray(data.history) ? data.history : []
                )
                    .filter(validHistory)
                    .slice(0, 100000);
                const notifications = (
                    Array.isArray(data.notifications) ? data.notifications : []
                )
                    .filter(
                        (n: any) =>
                            typeof n.id === "string" &&
                            typeof n.title === "string" &&
                            typeof n.content === "string" &&
                            typeof n.app === "string" &&
                            typeof n.date === "number",
                    )
                    .slice(0, 1000);
                const words = (Array.isArray(data.words) ? data.words : [])
                    .filter(
                        (w: any) =>
                            typeof w.id === "string" &&
                            typeof w.text === "string" &&
                            typeof w.definition === "string",
                    )
                    .slice(0, 10000);
                patch({
                    history: pruneHistory(history, settings, now()),
                    settings,
                    ...library,
                    notifications,
                    words,
                    selectedFolder: library.folders[0]?.id || "",
                });
            }
            patch({ ready: true });
        } catch (e) {
            storageWritable = false;
            patch({
                ready: true,
                message: `读取本地数据失败，原数据未覆盖：${e instanceof Error ? e.message : String(e)}`,
            });
        }
    })();
    const bindings = () => [
        ...state().folders.map((f) => ({
            owner: `folder:${f.id}`,
            chord: f.shortcut,
        })),
        ...state().snippets.map((s) => ({
            owner: `snippet:${s.id}`,
            chord: s.shortcut,
        })),
        ...["searchShortcut", "lookupShortcut", "screenshotShortcut"].map(
            (key) => ({ owner: key, chord: state().settings[key] as string }),
        ),
    ];
    const actions = {
        navigate(page: Page) {
            if (state().page === "words" && page !== "words") {
                requestGeneration++;
                lookupAbort?.abort();
                void call("model.cancel").catch(() => undefined);
            }
            patch({ page, query: "", selection: null, busy: false });
        },
        setQuery(query: string) {
            patch({ query });
        },
        set(key: string, value: unknown) {
            if (
                [
                    "query",
                    "word",
                    "translation",
                    "selection",
                    "selectedFolder",
                    "page",
                ].includes(key)
            )
                patch({ [key]: value });
            else report(`不支持直接设置 ${key}`);
        },
        selectHistory(id: string | null) {
            patch({ selection: id });
        },
        selectFolder(id: string) {
            patch({ selectedFolder: id });
        },
        addHistory(input: Partial<HistoryEntry> & { content: string }) {
            if (!input.content && !input.mediaPath) return;
            if (new TextEncoder().encode(input.content).length > 512 * 1024)
                throw Error("单条文本超过 512 KiB");
            if (
                (input.sourceBundleId || input.sourceApp) &&
                state().settings.excludedApps.includes(
                    input.sourceBundleId || input.sourceApp || "",
                )
            )
                return;
            const entry: HistoryEntry = {
                id: input.id || randomUUID(),
                type: input.type || "text",
                content: input.content,
                title: input.title || input.content.slice(0, 80) || "文件",
                sourceApp: input.sourceApp || "Clipy",
                sourceBundleId: input.sourceBundleId,
                sourceIconPath: input.sourceIconPath,
                date: input.date || now(),
                isPinned: input.isPinned || false,
                mediaPath: input.mediaPath,
                mediaId: input.mediaId,
                ocrText: input.ocrText,
                files: input.files,
            };
            return commit({
                history: insertHistory(
                    state().history,
                    entry,
                    state().settings,
                ),
            });
        },
        copyHistory(id: string, paste = false, plain = false) {
            return perform(async () => {
                const row = state().history.find((x) => x.id === id);
                if (!row) throw Error("历史已不存在");
                await call("clipboard.write", {
                    ...row,
                    text: row.content,
                    paste,
                    plain,
                });
                report(paste ? "已请求粘贴" : "已复制");
            });
        },
        pinHistory(id: string) {
            return perform(async () => {
                await commit({
                    history: state().history.map((r) =>
                        r.id === id ? { ...r, isPinned: !r.isPinned } : r,
                    ),
                });
            });
        },
        deleteHistory(id: string | string[]) {
            const ids = new Set(Array.isArray(id) ? id : [id]);
            const rows = state().history.filter((r) => ids.has(r.id));
            if (!rows.length) return;
            undo = { rows, expires: now() + 8000 };
            return commit({
                history: state().history.filter((r) => !ids.has(r.id)),
                selection: null,
                undoAvailable: true,
                message: `已删除 ${rows.length} 条，可在 8 秒内撤销`,
            });
        },
        undoDelete() {
            if (!undo || now() > undo.expires) {
                undo = null;
                patch({ undoAvailable: false });
                return;
            }
            const current = new Map(state().history.map((r) => [r.id, r]));
            for (const row of undo.rows)
                if (!current.has(row.id)) current.set(row.id, row);
            undo = null;
            return commit({
                history: [...current.values()].sort((a, b) => b.date - a.date),
                undoAvailable: false,
                message: "已撤销删除",
            });
        },
        clearHistory() {
            undo = null;
            return commit({
                history: state().history.filter((r) => r.isPinned),
                undoAvailable: false,
            });
        },
        saveSnippet(input: Partial<Snippet>) {
            return perform(async () => {
                const current = input.id
                    ? state().snippets.find((s) => s.id === input.id)
                    : null;
                const row: Snippet = {
                    id: input.id || randomUUID(),
                    title: input.title ?? current?.title ?? "新片段",
                    content: input.content ?? current?.content ?? "",
                    folderId:
                        input.folderId ||
                        current?.folderId ||
                        state().selectedFolder,
                    shortcut: input.shortcut ?? current?.shortcut,
                };
                if (!state().folders.some((f) => f.id === row.folderId))
                    throw Error("请选择有效文件夹");
                if (row.content.length > 1024 * 1024)
                    throw Error("片段不能超过 1 MiB");
                assertShortcutFree(
                    row.shortcut || "",
                    `snippet:${row.id}`,
                    bindings(),
                );
                if (
                    row.shortcut &&
                    state().snippets.some(
                        (s) => s.id !== row.id && s.shortcut === row.shortcut,
                    )
                )
                    throw Error("快捷键已被其他片段使用");
                await commit({
                    snippets: current
                        ? state().snippets.map((s) =>
                              s.id === row.id ? row : s,
                          )
                        : [...state().snippets, row],
                });
                return row;
            });
        },
        deleteSnippet(id: string) {
            return commit({
                snippets: state().snippets.filter((s) => s.id !== id),
            });
        },
        saveFolder(input: Partial<Folder>) {
            return perform(async () => {
                const name = input.name?.trim();
                if (!name) throw Error("文件夹名称不能为空");
                const row: Folder = {
                    id: input.id || randomUUID(),
                    name,
                    shortcut:
                        input.shortcut ??
                        state().folders.find((f) => f.id === input.id)
                            ?.shortcut,
                };
                assertShortcutFree(
                    row.shortcut || "",
                    `folder:${row.id}`,
                    bindings(),
                );
                await commit({
                    folders: state().folders.some((f) => f.id === row.id)
                        ? state().folders.map((f) =>
                              f.id === row.id ? row : f,
                          )
                        : [...state().folders, row],
                    selectedFolder: row.id,
                });
                return row;
            });
        },
        deleteFolder(id: string) {
            const folders = state().folders.filter((f) => f.id !== id);
            return commit({
                folders,
                snippets: state().snippets.filter((s) => s.folderId !== id),
                selectedFolder: folders[0]?.id || "",
            });
        },
        reorderFolders(ids: string[]) {
            const byId = new Map(state().folders.map((s) => [s.id, s]));
            if (
                ids.length !== byId.size ||
                new Set(ids).size !== ids.length ||
                ids.some((id) => !byId.has(id))
            )
                throw Error("排序必须包含全部文件夹且不得重复");
            return commit({ folders: ids.map((id) => byId.get(id)!) });
        },
        updateHistory(id: string, updates: Partial<HistoryEntry>) {
            return commit({
                history: state().history.map((row) =>
                    row.id === id ? { ...row, ...updates, id: row.id } : row,
                ),
            });
        },
        reorderSnippets(ids: string[]) {
            const byId = new Map(state().snippets.map((s) => [s.id, s]));
            if (
                ids.length !== byId.size ||
                new Set(ids).size !== ids.length ||
                ids.some((id) => !byId.has(id))
            )
                throw Error("排序必须包含全部片段且不得重复");
            return commit({ snippets: ids.map((id) => byId.get(id)!) });
        },
        copySnippet(id: string) {
            return perform(async () => {
                const s = state().snippets.find((s) => s.id === id);
                if (!s) throw Error("片段不存在");
                await call("clipboard.write", {
                    text: s.content,
                    content: s.content,
                    type: "text",
                });
                report("已复制");
            });
        },
        importSnippets(json: string) {
            return perform(async () => {
                const data = parseSnippetImport(json);
                const folderIds = new Map<string, string>();
                const folders = [...state().folders];
                for (const f of data.folders) {
                    const id = randomUUID();
                    folderIds.set(f.id, id);
                    folders.push({ ...f, id, shortcut: undefined });
                }
                const snippets = data.snippets.map((s) => ({
                    ...s,
                    id: randomUUID(),
                    folderId: folderIds.get(s.folderId)!,
                    shortcut: undefined,
                }));
                await commit({
                    folders,
                    snippets: [...state().snippets, ...snippets],
                });
                report(`已导入 ${snippets.length} 个片段`);
            });
        },
        exportSnippets() {
            return JSON.stringify(
                {
                    version: 1,
                    folders: state().folders,
                    snippets: state().snippets,
                },
                null,
                2,
            );
        },
        saveSettings(input: Partial<Settings>) {
            return perform(async () => {
                const settings = cleanSettings({
                    ...state().settings,
                    ...input,
                });
                validateSettings(settings);
                for (const key of [
                    "searchShortcut",
                    "lookupShortcut",
                    "screenshotShortcut",
                ])
                    assertShortcutFree(settings[key] as string, key, [
                        ...bindings().filter(
                            (b) =>
                                ![
                                    "searchShortcut",
                                    "lookupShortcut",
                                    "screenshotShortcut",
                                ].includes(b.owner),
                        ),
                        ...[
                            "searchShortcut",
                            "lookupShortcut",
                            "screenshotShortcut",
                        ].map((k) => ({
                            owner: k,
                            chord: settings[k] as string,
                        })),
                    ]);
                const systemKeys = [
                    "excludedApps",
                    "ocrEnabled",
                    "syncEnabled",
                    "deviceName",
                    "port",
                    "relayEnabled",
                    "relayEndpoint",
                    "launchAtLogin",
                    "encryptHistory",
                    "searchShortcut",
                    "lookupShortcut",
                    "screenshotShortcut",
                ];
                if (
                    systemKeys.some((k) =>
                        Array.isArray(settings[k])
                            ? JSON.stringify(settings[k]) !==
                              JSON.stringify(state().settings[k])
                            : settings[k] !== state().settings[k],
                    )
                )
                    await call("system.configure", settings);
                await commit({
                    settings,
                    history: pruneHistory(state().history, settings, now()),
                });
                report("设置已保存");
            });
        },
        addNotification(row: PhoneNotification) {
            return commit({
                notifications: [
                    row,
                    ...state().notifications.filter((n) => n.id !== row.id),
                ].slice(0, 1000),
            });
        },
        removeNotifications(ids: string[]) {
            const remove = new Set(ids);
            return commit({
                notifications: state().notifications.filter(
                    (n) => !remove.has(n.id),
                ),
            });
        },
        deleteNotification(id: string) {
            return commit({
                notifications: state().notifications.filter((n) => n.id !== id),
            });
        },
        clearNotifications(deviceId?: string) {
            return commit({
                notifications: deviceId
                    ? state().notifications.filter(
                          (n) => n.deviceId !== deviceId,
                      )
                    : [],
            });
        },
        dismissNotification(id: string) {
            return perform(async () => {
                const row = state().notifications.find((n) => n.id === id);
                if (!row?.clearable) throw Error("此通知不能在手机上清除");
                await call("notification.dismiss", {
                    id,
                    deviceId: row.deviceId,
                });
                await commit({
                    notifications: state().notifications.filter(
                        (n) => n.id !== id,
                    ),
                });
            });
        },
        lookup(text = state().word) {
            return perform(async () => {
                const value = text.trim();
                if (!value || value.length > 500)
                    throw Error("查询内容必须为 1–500 字");
                const generation = ++requestGeneration;
                lookupAbort?.abort();
                lookupAbort = new AbortController();
                patch({
                    word: value,
                    busy: true,
                    wordResult: null,
                    message: "",
                });
                try {
                    const result = await lookupDictionary(
                        value,
                        lookupAbort.signal,
                    );
                    if (generation !== requestGeneration || closed) return;
                    const existing = state().words.find(
                        (w) => w.text.toLowerCase() === value.toLowerCase(),
                    );
                    const record: WordRecord = {
                        id: existing?.id || randomUUID(),
                        text: value,
                        definition:
                            typeof result === "string"
                                ? result
                                : result.definition || JSON.stringify(result),
                        familiar: existing?.familiar || false,
                        count: (existing?.count || 0) + 1,
                        date: now(),
                    };
                    patch({ wordResult: result });
                    if (!/^[A-Za-z]+(?:['-][A-Za-z]+)*$/.test(value)) return;
                    await commit({
                        words: [
                            record,
                            ...state().words.filter((w) => w.id !== record.id),
                        ].slice(0, 10000),
                    });
                } catch (error) {
                    if (generation !== requestGeneration || closed) return;
                    throw error;
                } finally {
                    if (generation === requestGeneration)
                        patch({ busy: false });
                }
            });
        },
        toggleFamiliar(id: string) {
            return commit({
                words: state().words.map((w) =>
                    w.id === id ? { ...w, familiar: !w.familiar } : w,
                ),
            });
        },
        deleteWord(id: string) {
            return commit({ words: state().words.filter((w) => w.id !== id) });
        },
        translate(text = state().word, target = "zh-CN") {
            return perform(async () => {
                if (!text.trim() || text.length > 10000)
                    throw Error("模型翻译支持 1–10,000 字");
                const generation = ++requestGeneration;
                patch({ busy: true, translation: "", message: "" });
                try {
                    const result = await call<any>("model.translate", {
                        text,
                        target,
                    });
                    if (generation === requestGeneration)
                        patch({
                            translation:
                                typeof result === "string"
                                    ? result
                                    : String(
                                          result.text ||
                                              result.translation ||
                                              "",
                                      ),
                        });
                } catch (error) {
                    if (generation !== requestGeneration || closed) return;
                    throw error;
                } finally {
                    if (generation === requestGeneration)
                        patch({ busy: false });
                }
            });
        },
        cancelLookup() {
            requestGeneration++;
            lookupAbort?.abort();
            patch({ busy: false });
            return call("model.cancel").catch(() => undefined);
        },
        configureModel(config: {
            endpoint: string;
            model: string;
            key?: string;
        }) {
            return perform(async () => {
                modelEndpoint(config.endpoint);
                if (!config.model.trim()) throw Error("请输入模型名称");
                const result = await call<any>("model.configure", config);
                report("模型配置已安全保存");
                return result;
            });
        },
        generatePassword(
            config: {
                length?: number;
                upper?: boolean;
                lower?: boolean;
                digits?: boolean;
                symbols?: boolean;
                excludeAmbiguous?: boolean;
            } = {},
        ) {
            return perform(async () => {
                const length = config.length ?? 20;
                if (!Number.isInteger(length) || length < 4 || length > 256)
                    throw Error("密码长度必须为 4–256");
                const groups = [
                    config.upper !== false ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "",
                    config.lower !== false ? "abcdefghijklmnopqrstuvwxyz" : "",
                    config.digits !== false ? "0123456789" : "",
                    config.symbols !== false ? "!@#$%^&*()-_=+[]{};:,.?" : "",
                ]
                    .map((g) =>
                        config.excludeAmbiguous === false
                            ? g
                            : g.replace(/[Il1|O0o]/g, ""),
                    )
                    .filter(Boolean);
                if (!groups.length) throw Error("请至少选择一种字符集");
                const alphabet = groups.join("");
                const chars = groups.map((g) => g[randomInt(g.length)]!);
                while (chars.length < length)
                    chars.push(alphabet[randomInt(alphabet.length)]!);
                for (let i = chars.length - 1; i > 0; i--) {
                    const j = randomInt(i + 1);
                    [chars[i], chars[j]] = [chars[j]!, chars[i]!];
                }
                const password = chars.join("");
                patch({
                    password,
                    passwordEntropy: Math.floor(
                        length * Math.log2(alphabet.length),
                    ),
                });
                return password;
            });
        },
        copyPassword() {
            return perform(async () => {
                if (!state().password) throw Error("请先生成密码");
                await call("clipboard.write", {
                    text: state().password,
                    content: state().password,
                    type: "text",
                    sensitive: true,
                });
                report("已复制密码");
            });
        },
        invoke(name: string, payload?: any) {
            return perform(async () => {
                const result = await call<any>(name, payload);
                if (name === "system.info")
                    patch({ hostAvailable: true, systemInfo: result });
                if (name === "relay.status" || name === "relay.refresh") {
                    patch({ relay: result });
                    if (Array.isArray(result?.peers))
                        patch({ devices: result.peers });
                }
                if (name === "capture.screen" && result?.path) {
                    patch({ capturePath: result.path });
                }
                return result;
            });
        },
        async ingest(event: { type: string; data: any }) {
            await ready;
            if (closed) return;
            if (event.type === "clipboard.changed" && event.data)
                return actions.addHistory(event.data);
            if (event.type === "notification.received")
                return actions.addNotification(event.data);
            if (event.type === "devices.changed")
                patch({ devices: event.data });
            if (event.type === "host.ready") patch({ hostAvailable: true });
        },
    };
    return {
        state,
        actions,
        ready,
        isStorageHealthy: () => storageWritable,
        filteredHistory: () => filterHistory(state().history, state().query),
        flush: () => persistQueue,
        dispose() {
            closed = true;
            requestGeneration++;
            lookupAbort?.abort();
            undo = null;
        },
    };
}
function validHistory(v: any): v is HistoryEntry {
    return (
        !!v &&
        typeof v.id === "string" &&
        ["text", "richText", "image", "file", "pdf"].includes(v.type) &&
        typeof v.content === "string" &&
        v.content.length <= 512 * 1024 &&
        typeof v.title === "string" &&
        typeof v.sourceApp === "string" &&
        typeof v.date === "number" &&
        Number.isFinite(v.date) &&
        typeof v.isPinned === "boolean"
    );
}

function cleanSettings(input: Record<string, unknown> = {}): Settings {
    const result = { ...DEFAULT_SETTINGS };
    for (const key of Object.keys(DEFAULT_SETTINGS)) {
        if (Object.prototype.hasOwnProperty.call(input, key)) {
            const value = input[key];
            const expected = DEFAULT_SETTINGS[key];
            if (key === "captureTranslationBackend" && !["system","model"].includes(String(value))) throw Error("翻译服务无效");
            if (Array.isArray(expected)) {
                if (key === "recentAnnotationColors" && (!Array.isArray(value) || value.length > 12 || value.some(v => typeof v !== "string" || !/^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(v)))) throw Error("最近颜色无效");
                if (
                    !Array.isArray(value) ||
                    value.length > 256 ||
                    value.some((v) => typeof v !== "string" || v.length > 512)
                )
                    throw Error("排除应用列表无效");
                result[key] = value.slice();
            } else {
                if (
                    typeof value !== typeof expected ||
                    (typeof value === "string" && value.length > 4096)
                )
                    throw Error(`设置字段 ${key} 无效`);
                result[key] = value;
            }
        }
    }
    return result;
}
