import { t as tr, locale } from "../ui/locale";
import {
    View,
    Text,
    Scroll,
    signal,
    computed,
    Image,
    Video,
    effect,
    cleanup,
    PanResponder,
} from "nsh";
import { DictionaryCard, WordBook } from "./WordsContent";
import { CapturePreferences } from "./CapturePreferences";
import { AlertDialog } from "nsh/base";
import { VideoEffects } from "./VideoEffects";
import { Onboarding } from "./Onboarding";
import { bindHistoryKeys, showHistoryMenu } from "../ui/historyActions";
import { Icon } from "../ui/Icon";
import { ImageEditor } from "../editor/ImageEditor";
import {
    Btn,
    Nav,
    Field,
    Setting,
    Empty,
    Header,
    Card,
    Chips,
    Label,
    cx,
    read,
    textOf,
    titleOf,
} from "../ui/primitives";

export type RootScreenProps = { model: any; actions?: any };
export function RootScreen(p: RootScreenProps) {
    const state = () => read(p.model?.state) || read(p.model) || {};
    const a = p.actions || p.model?.actions || {};
    const page = () => state().page || "history";
    const nav = async (id: string) => {
        try {
            await flushSnippetDraft();
        } catch {
            return;
        }
        a.navigate?.(id);
    };
    const editorPath = signal("");
    let mirroredEditorPath:unknown=undefined;effect(()=>{const incoming=state().editorPath;if(state().editorCapture){if(editorPath())editorPath.set("");mirroredEditorPath=incoming;return;}if(incoming!==mirroredEditorPath){mirroredEditorPath=incoming;if(typeof incoming==="string"&&incoming)editorPath.set(incoming);else if(incoming===null)editorPath.set("");}});
    const invoke = async (name: string, payload?: any) => {
        if (name === "capture.edit") {
            const result = await a.invoke?.("editor.open", {
                path: payload.path,
            });
            if (result?.path) editorPath.set(result.path);
            return result;
        }
        if (name === "capture.openImage") {
            const result = await a.invoke?.("capture.openImage");
            if (result?.path) {
                const lease = await a.invoke?.("editor.open", {
                    path: result.path,
                });
                if (lease?.path) editorPath.set(lease.path);
            }
            return result;
        }
        if (name === "permissions.request")
            return a.invoke?.(name, { kind: payload.permission });
        if (name === "history.clear") return a.invoke?.(name, payload);
        if (name === "snippets.delete") {
            try {
                await flushSnippetDraft();
            } catch {
                return;
            }
            selectedSnippet.set("");
            snippetTitle.set("");
            snippetBody.set("");
            return a.invoke?.(name, payload);
        }
        if (name === "snippets.saveFolder") {
            try {
                await flushSnippetDraft();
            } catch {
                return;
            }
            const row = await a.saveFolder?.({
                ...payload,
                id: payload.id || undefined,
            });
            if (row?.id) folder.set(row.id);
            return row;
        }
        if (name === "notifications.delete")
            return a.deleteNotification?.(payload.id);
        if (name === "notifications.clear") return a.invoke?.(name, payload);
        if (name === "notifications.dismissRemote")
            return a.invoke?.(name, payload);
        if (name === "words.familiar") return a.toggleFamiliar?.(payload.id);
        if (name === "clipboard.copy")
            return a.invoke?.("clipboard.write", {
                ...payload,
                content: payload.text,
                type: "text",
            });
        return a.invoke?.(name, payload);
    };
    const query = signal("");
    const type = signal("all");
    const period = signal("全部");
    const source = signal("");
    const category = signal("");
    const regex = signal(false);
    const historyShown = signal(100);
    const selected = signal("");
    const selectedSnippet = signal("");
    const folder = signal("");
    const editFolderId = signal("");
    const folderShortcut = signal("");
    const section = signal(String(state().settingsSection || "通用"));
    const device = signal("");
    const modal = signal("");
    const pendingManagers = signal<Record<string, boolean>>({});
    const memberID = (member: any) =>
        String(member.device || member.id || member.deviceId || "");
    const pendingKey = (request: any) =>
        String(
            request.device || request.pairingCode || request.name || "pending",
        );
    const isRelayManager = () =>
        (state().relay?.members || []).find(
            (member: any) => memberID(member) === state().relay?.device,
        )?.manager === true;
    const relayURL = signal(""),
        relayDevice = signal(""),
        relayToken = signal(""),
        relayJSON = signal(""),
        relayFormError = signal(""),
        relayAdvanced = signal(false);
    function openRelaySettings() {
        relayURL.set(
            state().relay?.url || state().settings?.relayEndpoint || "",
        );
        relayDevice.set(state().relay?.device || "");
        relayToken.set("");
        relayJSON.set("");
        relayFormError.set("");
        relayAdvanced.set(false);
        entry.set("");
        modal.set("relaySettings");
    }
    async function submitRelaySettings() {
        relayFormError.set("");
        let config: Record<string, unknown> | undefined;
        if (relayJSON().trim()) {
            if (new TextEncoder().encode(relayJSON()).length > 65536) {
                relayFormError.set(tr("接入配置不能超过 64 KiB"));
                return false;
            }
            try {
                const parsed = JSON.parse(relayJSON());
                if (
                    !parsed ||
                    typeof parsed !== "object" ||
                    Array.isArray(parsed)
                )
                    throw Error();
                config = parsed;
            } catch {
                relayFormError.set(tr("接入配置 JSON 无效，请检查格式。"));
                return false;
            }
        }
        const payload: Record<string, unknown> = { url: relayURL().trim() };
        if (entry()) payload.password = entry();
        if (relayDevice().trim()) payload.device = relayDevice().trim();
        if (relayToken()) payload.token = relayToken();
        if (config) payload.config = config;
        const result = await invoke("relay.configure", payload);
        if (!result) {
            relayFormError.set(tr("未能保存中继配置，请检查连接与认证信息。"));
            return false;
        }
        relayToken.set("");
        relayJSON.set("");
        entry.set("");
        return true;
    }
    const entry = signal("");
    effect(() => {
        if (
            state().relay?.authRejected &&
            [
                "createGroup",
                "joinGroup",
                "renameMember",
                "leaveGroup",
                "disbandGroup",
            ].includes(modal())
        ) {
            modal.set("");
            entry.set("");
        }
    });
    const port = signal("5566");
    const sendText = signal("");
    const snippetTitle = signal("");
    const snippetBody = signal("");
    const snippetShortcut = signal("");
    const wordInput = signal("");
    let lastWordPrefill: unknown = null;
    effect(() => {
        const version = state().wordPrefillVersion;
        if (version !== undefined && version !== lastWordPrefill) {
            lastWordPrefill = version;
            wordInput.set(state().wordPrefill || "");
            const book = state().wordBookRequestVersion;
            if (
                !(
                    typeof book === "number" &&
                    typeof version === "number" &&
                    book >= version
                )
            )
                section.set("单词查询");
        }
    });
    let lastWordBookRequest: unknown = null;
    effect(() => {
        const version = state().wordBookRequestVersion;
        if (
            page() === "words" &&
            version !== undefined &&
            version !== null &&
            version !== lastWordBookRequest
        ) {
            lastWordBookRequest = version;
            const queryVersion = state().wordPrefillVersion;
            if (
                typeof version === "number" &&
                typeof queryVersion === "number" &&
                version < queryVersion
            )
                return;
            section.set("单词表");
        }
    });
    let lastWordQueryRequest: unknown = null;
    effect(() => {
        const version = state().wordQueryRequestVersion;
        if (
            page() === "words" &&
            version !== undefined &&
            version !== null &&
            version !== lastWordQueryRequest
        ) {
            lastWordQueryRequest = version;
            const book = state().wordBookRequestVersion;
            if (
                typeof version === "number" &&
                typeof book === "number" &&
                book >= version
            )
                return;
            section.set("单词查询");
        }
    });
    const modelURL = signal("");
    const modelName = signal("");
    const modelFilter = signal("");
    const modelHasKey = signal(false);
    let modelSettingsActive = false,
        modelLoadVersion = 0,
        modelDraftTouched = false,
        modelDraftRevision = 0,
        lastConfigSignature = "",
        lastModelHasKey: unknown = undefined;
    function markModelDirty() {
        modelDraftTouched = true;
        modelDraftRevision++;
    }
    function hydrateModelConfig(config: any) {
        if (!config) return;
        if (lastModelHasKey !== !!config.hasKey) {
            lastModelHasKey = !!config.hasKey;
            modelHasKey.set(!!config.hasKey);
        }
        if (!modelDraftTouched) {
            modelURL.set(
                typeof config.endpoint === "string" ? config.endpoint : "",
            );
            modelName.set(typeof config.model === "string" ? config.model : "");
        }
    }
    effect(() => {
        const active = page() === "words" && section() === "API 设置",
            config = state().modelConfig;
        const signature = config
            ? JSON.stringify([
                  config.endpoint,
                  config.model,
                  !!config.hasKey,
                  state().modelConfigVersion ?? config.version ?? null,
              ])
            : "";
        if (active !== modelSettingsActive) {
            modelSettingsActive = active;
            const version = ++modelLoadVersion;
            if (!active) {
                entry.set("");
                return;
            }
            modelDraftTouched = false;
            modelDraftRevision++;
            lastConfigSignature = "";
            if (!config)
                void a.invoke?.("model.status").then((value: any) => {
                    if (
                        version === modelLoadVersion &&
                        modelSettingsActive &&
                        value &&
                        !state().modelConfig
                    )
                        hydrateModelConfig(value);
                });
        }
        if (active && config && signature !== lastConfigSignature) {
            lastConfigSignature = signature;
            hydrateModelConfig(config);
        }
    });
    async function saveModelSettings() {
        const revision = modelDraftRevision,
            version = modelLoadVersion;
        const payload = {
            endpoint: modelURL(),
            model: modelName(),
            key: entry(),
        };
        if (modelHasKey() && !payload.key) {
            const answer = await AlertDialog.show({
                title: tr("删除已存 API Key？"),
                description: tr(
                    "密钥输入为空。保存本次配置会删除已存密钥；可取消后填写密钥。",
                ),
                actions: [
                    { id: "cancel", label: tr("取消"), role: "cancel" },
                    {
                        id: "save",
                        label: tr("删除并保存"),
                        role: "destructive",
                    },
                ],
                closeOnEscape: true,
            });
            if (answer.action !== "save") return;
        }
        const result = await invoke("models.configure", payload);
        if (result === undefined || result === false) return;
        if (
            modelSettingsActive &&
            version === modelLoadVersion &&
            revision === modelDraftRevision
        ) {
            modelDraftTouched = false;
            entry.set("");
            hydrateModelConfig(
                state().modelConfig ||
                    (result.endpoint
                        ? result
                        : {
                              endpoint: payload.endpoint,
                              model: payload.model,
                              hasKey: !!payload.key,
                          }),
            );
        }
    }
    const videoIn = signal("0");
    const videoOut = signal("");
    const isGifResult = () =>
        state().videoExport?.format === "gif" ||
        String(state().videoExport?.path || "")
            .toLowerCase()
            .endsWith(".gif");
    const videoPreviewPath = () =>
        !isGifResult() && state().videoExport?.path
            ? state().videoExport.path
            : state().video?.path || state().videoPath;
    const videoRate = signal("1");
    const videoScale = signal("1"),
        videoQuality = signal("high");
    const pwLength = signal("20");
    const chars = signal({
        upper: true,
        lower: true,
        numbers: true,
        symbols: true,
        excludeAmbiguous: true,
    });
    const history = () => state().history || [];
    const notifications = () => state().notifications || [];
    const snippets = () => state().snippets || [];
    const folders = () => state().folders || [];
    const devices = () => state().devices || [];
    const invitation = () => state().invitation || state().relay?.invitation;
    const effectiveFolder = () =>
        folder() || state().selectedFolder || folders()[0]?.id || "";
    const filtered = computed(() =>
        history().filter((x: any) => {
            if (
                type() !== "all" &&
                !(type() === "pin"
                    ? x.isPinned || x.pinned
                    : (x.type || x.kind) === type())
            )
                return false;
            if (source() && (x.sourceApp || x.source) !== source())
                return false;
            if (period() !== "全部") {
                const start = new Date();
                start.setHours(0, 0, 0, 0);
                const age =
                    period() === "今天"
                        ? start.getTime()
                        : Date.now() -
                          (period() === "7 天" ? 7 : 30) * 86400000;
                if (x.date < age) return false;
            }
            const body = textOf(x);
            if (category() === "url" && !/https?:\/\//i.test(body))
                return false;
            if (
                category() === "email" &&
                !/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(body)
            )
                return false;
            if (
                category() === "code" &&
                !/(?:function|const |let |import |class |git |def |=>|[{};]\s*$)/m.test(
                    body,
                )
            )
                return false;
            if (category() === "json") {
                try {
                    JSON.parse(body);
                } catch {
                    return false;
                }
            }
            if (!query()) return true;
            const searchable = `${titleOf(x)} ${body} ${x.ocrText || ""} ${x.sourceApp || x.source || ""}`;
            if (regex()) {
                try {
                    return new RegExp(query(), "i").test(searchable);
                } catch {
                    return false;
                }
            }
            return searchable.toLowerCase().includes(query().toLowerCase());
        }),
    );
    effect(() => {
        query();
        type();
        period();
        source();
        category();
        regex();
        historyShown.set(100);
    });
    const current = () =>
        filtered().find(
            (x: any) => x.id === (selected() || state().selection),
        ) || filtered()[0];
    const mediaPreviewPhase = signal<"idle" | "loading" | "unavailable">(
        "idle",
    );
    let lastRequestedMediaId = "",
        lastRequestWasMedia = false,
        mediaRequestGeneration = 0,
        lastReadyMediaPath = "",
        mediaPreviewTimer: ReturnType<typeof setTimeout> | null = null;
    const historyIsVisible = () =>
        page() === "history" && !editorPath() && state().uiVisible !== false;
    const clearMediaPreviewTimer = () => {
        if (mediaPreviewTimer) {
            clearTimeout(mediaPreviewTimer);
            mediaPreviewTimer = null;
        }
    };
    function requestHistorySelection(row: any, explicit = false) {
        const managed = !!row.mediaId,
            key = managed ? `${row.id}:${row.mediaId}` : "",
            generation = ++mediaRequestGeneration;
        lastRequestedMediaId = key;
        lastRequestWasMedia = managed;
        lastReadyMediaPath = "";
        clearMediaPreviewTimer();
        mediaPreviewPhase.set(managed ? "loading" : "idle");
        if (explicit) selected.set(row.id);
        try {
            const result = a.selectHistory?.(row.id);
            if (managed) {
                mediaPreviewTimer = setTimeout(() => {
                    if (
                        generation === mediaRequestGeneration &&
                        historyIsVisible() &&
                        !current()?.mediaPath
                    )
                        mediaPreviewPhase.set("unavailable");
                }, 4000);
                if (result && typeof result.then === "function")
                    void Promise.resolve(result).then(
                        () => {
                            if (
                                generation === mediaRequestGeneration &&
                                historyIsVisible() &&
                                !current()?.mediaPath
                            )
                                mediaPreviewPhase.set("unavailable");
                        },
                        () => {
                            if (generation === mediaRequestGeneration)
                                mediaPreviewPhase.set("unavailable");
                        },
                    );
            }
        } catch {
            if (managed) mediaPreviewPhase.set("unavailable");
        }
    }
    effect(() => {
        if (!historyIsVisible()) {
            lastRequestedMediaId = "";
            lastRequestWasMedia = false;
            lastReadyMediaPath = "";
            mediaRequestGeneration++;
            clearMediaPreviewTimer();
            mediaPreviewPhase.set("idle");
            return;
        }
        const row = current();
        if (!row) return;
        if (!row.mediaId) {
            if (lastRequestWasMedia) requestHistorySelection(row);
            return;
        }
        const key = `${row.id}:${row.mediaId}`;
        if (key !== lastRequestedMediaId) requestHistorySelection(row);
    });
    effect(() => {
        const row = current(),
            path =
                historyIsVisible() && row?.mediaPath
                    ? `${row.id}:${row.mediaPath}`
                    : "";
        if (path && path !== lastReadyMediaPath) {
            lastReadyMediaPath = path;
            clearMediaPreviewTimer();
            mediaPreviewPhase.set("idle");
        } else if (!path) lastReadyMediaPath = "";
    });
    cleanup(() => {
        mediaRequestGeneration++;
        clearMediaPreviewTimer();
    });
    let historyScroll: any = null;
    const historyBounds = new Map<string, number>();
    let unbindHistory: (() => void) | undefined;
    effect(() => {
        const active = page() === "history" && !editorPath();
        unbindHistory?.();
        unbindHistory = active
            ? bindHistoryKeys({
                  rows: filtered,
                  current,
                  actions: a,
                  select: (row: any) => {
                      requestHistorySelection(row, true);
                      const index = filtered().findIndex(
                          (item: any) => item.id === row.id,
                      );
                      if (index >= historyShown())
                          historyShown.set(Math.ceil((index + 1) / 100) * 100);
                      const y = historyBounds.get(row.id);
                      if (y !== undefined)
                          historyScroll?.scrollTo({
                              y: Math.max(0, y - 180),
                              animated: false,
                          });
                  },
              })
            : undefined;
    });
    cleanup(() => unbindHistory?.());
    const currentDevice = () =>
        devices().find((x: any) => x.id === device()) || devices()[0];
    const select = (row: any) => requestHistorySelection(row, true);
    const copy = (x: any, plain = false) =>
        a.copyHistory
            ? a.copyHistory(x.id, plain, plain)
            : invoke("clipboard.copy", { entry: x, plain });
    const setting = (key: string, value: any) => {
        const aliases: Record<string, string> = {
            retentionDays: "historyRetentionDays",
            ocrHistory: "ocrEnabled",
            wordShortcut: "lookupShortcut",
            captureShortcut: "screenshotShortcut",
            captureAutoSave: "autoSave",
            showThumbnail: "thumbnailEnabled",
            imageFormat: "saveFormat",
            autoScroll: "scrollAutomatic",
            recordFps: "fps",
            recordSystemAudio: "systemAudio",
            recordMicrophone: "microphone",
            recordCamera: "camera",
            recordClicks: "highlightClicks",
            recordKeys: "showKeys",
            hideRecordingHud: "hideHUD",
            syncPort: "port",
            notificationSync: "notificationsEnabled",
            notificationKeywords: "keywords",
            notificationBlocked: "blockedKeywords",
        };
        return a.saveSettings?.({
            [aliases[key] || key]:
                key === "recordFps"
                    ? parseInt(value)
                    : key === "imageFormat"
                      ? String(value).toLowerCase()
                      : value,
        });
    };
    const settings = () => {
        const s = state().settings || {};
        return {
            ...s,
            retentionDays: s.historyRetentionDays,
            wordShortcut: s.lookupShortcut,
            captureShortcut: s.screenshotShortcut,
            ocrHistory: s.ocrEnabled,
            captureAutoSave: s.autoSave,
            showThumbnail: s.thumbnailEnabled,
            imageFormat: s.saveFormat,
            autoScroll: s.scrollAutomatic,
            recordFps: `${s.fps || 30} fps`,
            recordSystemAudio: s.systemAudio,
            recordMicrophone: s.microphone,
            recordCamera: s.camera,
            recordClicks: s.highlightClicks,
            recordKeys: s.showKeys,
            hideRecordingHud: s.hideHUD,
            syncPort: s.port,
            notificationSync: s.notificationsEnabled,
            notificationKeywords: s.keywords,
            notificationBlocked: s.blockedKeywords,
        };
    };
    let snippetDirty = false,
        snippetTimer: ReturnType<typeof setTimeout> | null = null,
        snippetQueue: Promise<void> = Promise.resolve(),
        draftRevision = 0;
    const failedDraftMap = new Map<string, { draft: any; revision: number }>();
    const failedIDs = new Set<string>();
    const failedDraftCount = signal(0);
    const draftStatus = signal("更改自动保存");
    const draftFailed = (error: unknown) => {
        draftStatus.set("保存失败，草稿已保留，请重试");
        failedDraftCount.set(failedIDs.size);
        return error instanceof Error
            ? error
            : Error("保存失败，草稿已保留，请重试");
    };
    function enqueueDraft(draft: any) {
        const revision = ++draftRevision;
        failedDraftMap.set(draft.id, { draft, revision });
        snippetQueue = snippetQueue
            .catch(() => {})
            .then(async () => {
                try {
                    const saved = await a.saveSnippet?.(draft);
                    if (!saved) throw Error("保存失败，草稿已保留，请重试");
                    if (failedDraftMap.get(draft.id)?.revision === revision) {
                        failedDraftMap.delete(draft.id);
                        failedIDs.delete(draft.id);
                    }
                    failedDraftCount.set(failedIDs.size);
                    if (!snippetDirty && selectedSnippet() === draft.id)
                        draftStatus.set("已自动保存");
                } catch (error) {
                    failedIDs.add(draft.id);
                    throw draftFailed(error);
                }
            });
        return snippetQueue;
    }
    async function flushSnippetDraft(): Promise<void> {
        if (snippetTimer) {
            clearTimeout(snippetTimer);
            snippetTimer = null;
        }
        if (
            snippetDirty &&
            (selectedSnippet() || snippetTitle().trim() || snippetBody())
        ) {
            if (!selectedSnippet()) selectedSnippet.set(crypto.randomUUID());
            const draft = {
                id: selectedSnippet(),
                title: snippetTitle().trim() || "新片段",
                content: snippetBody(),
                shortcut: snippetShortcut(),
                folderId:
                    folder() || state().selectedFolder || folders()[0]?.id,
            };
            snippetDirty = false;
            draftStatus.set("正在保存…");
            void enqueueDraft(draft).catch(() => {});
        }
        await snippetQueue;
        if (snippetDirty) return flushSnippetDraft();
        if (failedDraftMap.size)
            throw draftFailed(Error("仍有未保存草稿，请先重试保存"));
    }
    async function retryFailedDrafts() {
        const rows = [...failedDraftMap.values()].map((row) => row.draft);
        for (const draft of rows) void enqueueDraft(draft).catch(() => {});
        await snippetQueue;
        return flushSnippetDraft();
    }
    function editSnippet(key: "title" | "content", value: string) {
        if (key === "title") snippetTitle.set(value);
        else snippetBody.set(value);
        snippetDirty = true;
        draftStatus.set("更改自动保存");
        if (snippetTimer) clearTimeout(snippetTimer);
        snippetTimer = setTimeout(
            () => void flushSnippetDraft().catch(() => {}),
            300,
        );
    }
    async function openSnippet(row: any) {
        try {
            await flushSnippetDraft();
        } catch {
            return;
        }
        selectedSnippet.set(row.id);
        snippetTitle.set(titleOf(row));
        snippetBody.set(textOf(row));
        snippetShortcut.set(row.shortcut || "");
        snippetDirty = false;
        draftStatus.set("更改自动保存");
    }
    async function newSnippet() {
        try {
            await flushSnippetDraft();
        } catch {
            return;
        }
        selectedSnippet.set("");
        snippetTitle.set("");
        snippetBody.set("");
        snippetShortcut.set("");
        snippetDirty = false;
        draftStatus.set("更改自动保存");
    }
    async function selectSnippetFolder(id: string) {
        try {
            await flushSnippetDraft();
        } catch {
            return;
        }
        folder.set(id);
        a.selectFolder?.(id);
        selectedSnippet.set("");
        snippetTitle.set("");
        snippetBody.set("");
        snippetShortcut.set("");
    }
    a.flushDrafts = flushSnippetDraft;
    let previousPage = page();
    effect(() => {
        const next = page();
        if (previousPage === "snippets" && next !== "snippets")
            void flushSnippetDraft().catch(() => {});
        if (previousPage !== next) {
            query.set("");
            entry.set("");
            relayToken.set("");
            relayJSON.set("");
            if (editorPath()) {
                editorPath.set("");
                void a.invoke?.("editor.close");
            }
        }
        previousPage = next;
    });
    cleanup(() => {
        entry.set("");
        relayToken.set("");
        relayJSON.set("");
        void flushSnippetDraft().catch(() => {});
    });
    const saveSnippet = () =>
        void (
            failedDraftMap.size ? retryFailedDrafts() : flushSnippetDraft()
        ).catch(() => {});
    const dragSnippet = signal("");
    const dropSnippet = signal("");
    let snippetDragY = 0,
        snippetDragged = false;
    const visibleSnippets = () =>
        snippets().filter(
            (s: any) =>
                (!effectiveFolder() || s.folderId === effectiveFolder()) &&
                (!query() || `${s.title} ${s.content}`.includes(query())),
        );
    function startSnippetDrag(id: string, y: number) {
        if (query()) return;
        dragSnippet.set(id);
        dropSnippet.set(id);
        snippetDragY = y;
        snippetDragged = false;
    }
    function hoverSnippetDrag(id: string, y: number) {
        if (!dragSnippet() || query()) return;
        if (Math.abs(y - snippetDragY) > 6) snippetDragged = true;
        if (snippetDragged) dropSnippet.set(id);
    }
    function touchSnippetDrag(y: number) {
        if (!dragSnippet() || query()) return;
        const rows = visibleSnippets();
        const index = rows.findIndex((s: any) => s.id === dragSnippet());
        const offset = Math.round((y - snippetDragY) / 60);
        if (offset) snippetDragged = true;
        const target =
            rows[Math.max(0, Math.min(rows.length - 1, index + offset))];
        if (target) dropSnippet.set(target.id);
    }
    const dragFolder = signal("");
    const dropFolder = signal("");
    function folderPan(id: string) {
        return PanResponder.create({
            onStartShouldSetPanResponder: () => false,
            onMoveShouldSetPanResponderCapture: (_e, g) => Math.abs(g.dy) > 6,
            onPanResponderGrant: () => {
                dragFolder.set(id);
                dropFolder.set(id);
            },
            onPanResponderMove: (_e, g) => {
                const i = folders().findIndex((f: any) => f.id === id);
                const to =
                    folders()[
                        Math.max(
                            0,
                            Math.min(
                                folders().length - 1,
                                i + Math.round(g.dy / 35),
                            ),
                        )
                    ];
                if (to) dropFolder.set(to.id);
            },
            onPanResponderRelease: () => {
                const from = dragFolder(),
                    to = dropFolder();
                dragFolder.set("");
                dropFolder.set("");
                if (!from || from === to) return;
                const rows = [...folders()];
                const i = rows.findIndex((f) => f.id === from),
                    j = rows.findIndex((f) => f.id === to);
                if (i < 0 || j < 0) return;
                const [row] = rows.splice(i, 1);
                rows.splice(j, 0, row);
                void flushSnippetDraft().catch(() => {});
                void a.reorderFolders?.(rows.map((f) => f.id));
            },
            onPanResponderTerminate: () => {
                dragFolder.set("");
                dropFolder.set("");
            },
        }).panHandlers;
    }
    function snippetPan(id: string) {
        return PanResponder.create({
            onStartShouldSetPanResponder: () => false,
            onMoveShouldSetPanResponder: (_e, g) =>
                !query() && Math.abs(g.dy) > 6,
            onPanResponderGrant: () => startSnippetDrag(id, 0),
            onPanResponderMove: (_e, g) => touchSnippetDrag(g.dy),
            onPanResponderRelease: endSnippetDrag,
            onPanResponderTerminate: () => {
                dragSnippet.set("");
                dropSnippet.set("");
            },
        }).panHandlers;
    }
    function endSnippetDrag() {
        const from = dragSnippet(),
            to = dropSnippet();
        dragSnippet.set("");
        dropSnippet.set("");
        if (!snippetDragged || !from || from === to) return;
        const rows = [...snippets()];
        const i = rows.findIndex((s) => s.id === from),
            j = rows.findIndex((s) => s.id === to);
        if (i < 0 || j < 0) return;
        const [row] = rows.splice(i, 1);
        rows.splice(j, 0, row);
        void flushSnippetDraft().catch(() => {});
        void a.reorderSnippets?.(rows.map((s) => s.id));
    }

    const tabs = [
        { id: "history", label: "历史", icon: "◷" },
        { id: "snippets", label: "片段", icon: "▤" },
        { id: "devices", label: "设备", icon: "▣" },
        { id: "notifications", label: "通知", icon: "◉" },
    ];
    const title = () =>
        ({
            history: "剪贴板历史",
            snippets: "片段库",
            devices: "我的设备",
            notifications: "手机通知",
            settings: "偏好设置",
            words: "查词与单词表",
            tools: "工具",
            relay: "公网设备组",
            capture: "截图",
            recording: "录屏",
            video: "视频编辑器",
            onboarding: "欢迎使用 Clipy",
            panel: "Clipy",
        })[page() as string] || "Clipy";
    return (
        <View class="flex-1 bg-background">
            <If when={editorPath()}>
                <ImageEditor
                    path={editorPath()}
                    actions={a}
                    defaults={state().settings}
                    pressure={state().editorPressure}
                    onClose={() => {
                        editorPath.set("");
                        void a.invoke?.("editor.close");
                    }}
                />
            </If>
            <If when={!editorPath()}>
                <If when={page() === "panel"}>
                    <CompactPanel state={state} actions={a} />
                </If>
                <If when={page() === "onboarding"}>
                    <Onboarding state={state} actions={a} />
                </If>
                <If when={page() !== "panel" && page() !== "onboarding"}>
                    <View class="flex-1 flex-row min-h-0">
                        <View class={cx.side}>
                            <View class="flex-row bg-secondary rounded-lg p-1 mb-3 gap-1">
                                <Each of={tabs}>
                                    {(t) => (
                                        <View
                                            role="button"
                                            accessibilityLabel={tr(t().label)}
                                            onPress={() => nav(t().id)}
                                            class={`flex-1 items-center py-[5px] rounded-md ${page() === t().id ? "bg-background" : ""}`}
                                        >
                                            <Text
                                                class={`text-[11px] ${page() === t().id ? "text-blue-500 font-semibold" : "text-muted-foreground"}`}
                                            >
                                                {locale() === "en"
                                                    ? (
                                                          {
                                                              snippets: "Snips",
                                                              notifications:
                                                                  "Alerts",
                                                          } as Record<
                                                              string,
                                                              string
                                                          >
                                                      )[t().id] || tr(t().label)
                                                    : tr(t().label)}
                                            </Text>
                                        </View>
                                    )}
                                </Each>
                            </View>
                            <If
                                when={
                                    page() === "history" || page() === "panel"
                                }
                            >
                                <Nav
                                    icon="◷"
                                    label={tr("全部历史")}
                                    count={history().length}
                                    active={type() === "all"}
                                    onPress={() => {
                                        type.set("all");
                                        category.set("");
                                    }}
                                />
                                <Nav
                                    icon="⌖"
                                    label={tr("已置顶")}
                                    active={type() === "pin"}
                                    onPress={() => type.set("pin")}
                                />
                                <Label>{tr("类型")}</Label>
                                <Each
                                    of={[
                                        {
                                            id: "text",
                                            label: "文本",
                                            icon: "T",
                                        },
                                        {
                                            id: "richText",
                                            label: "富文本",
                                            icon: "▤",
                                        },
                                        {
                                            id: "image",
                                            label: "图片",
                                            icon: "▧",
                                        },
                                        {
                                            id: "file",
                                            label: "文件",
                                            icon: "▱",
                                        },
                                    ]}
                                >
                                    {(t) => (
                                        <Nav
                                            {...t()}
                                            active={type() === t().id}
                                            onPress={() => type.set(t().id)}
                                        />
                                    )}
                                </Each>
                                <Label>{tr("分类")}</Label>
                                <Each
                                    of={[
                                        { id: "url", label: "URL" },
                                        { id: "email", label: "邮箱" },
                                        { id: "code", label: "代码" },
                                        { id: "json", label: "JSON" },
                                    ]}
                                >
                                    {(t) => (
                                        <Nav
                                            label={tr(t().label)}
                                            icon="◇"
                                            active={category() === t().id}
                                            onPress={() =>
                                                category.set(
                                                    category() === t().id
                                                        ? ""
                                                        : t().id,
                                                )
                                            }
                                        />
                                    )}
                                </Each>
                            </If>
                            <If when={page() === "snippets"}>
                                <View class="flex-row items-center px-2">
                                    <Label>{tr("文件夹")}</Label>
                                    <View class="flex-1" />
                                    <Btn
                                        label="＋"
                                        onPress={() => {
                                            editFolderId.set("");
                                            folderShortcut.set("");
                                            entry.set("");
                                            modal.set("folder");
                                        }}
                                    />
                                </View>
                                <Each of={folders()}>
                                    {(f: any) => (
                                        <View
                                            {...folderPan(f().id)}
                                            class={`${dragFolder() === f().id ? "opacity-60" : ""} ${dropFolder() === f().id && dragFolder() !== f().id ? "border-t-2 border-blue-500" : ""}`}
                                        >
                                            <Nav
                                                translateLabel={false}
                                                label={f().name || f().title}
                                                icon="▱"
                                                active={
                                                    effectiveFolder() === f().id
                                                }
                                                count={
                                                    snippets().filter(
                                                        (s: any) =>
                                                            s.folderId ===
                                                            f().id,
                                                    ).length
                                                }
                                                onPress={() =>
                                                    void selectSnippetFolder(
                                                        f().id,
                                                    )
                                                }
                                            />
                                        </View>
                                    )}
                                </Each>
                                <If when={!folders().length}>
                                    <Text class="p-2 text-[12px] text-muted-foreground">
                                        {tr("添加文件夹，整理常用片段。")}
                                    </Text>
                                </If>
                            </If>
                            <If
                                when={
                                    page() === "devices" || page() === "relay"
                                }
                            >
                                <Nav
                                    label={tr("我的设备")}
                                    icon="▣"
                                    active={page() === "devices"}
                                    count={devices().length}
                                    onPress={() => nav("devices")}
                                />
                                <Nav
                                    label={tr("局域网设置")}
                                    icon="⌁"
                                    onPress={() => {
                                        section.set("局域网设备");
                                        nav("settings");
                                    }}
                                />
                                <Nav
                                    label={tr("公网设备组")}
                                    icon="◎"
                                    active={page() === "relay"}
                                    onPress={() => nav("relay")}
                                />
                                <Nav
                                    label={tr("手机通知")}
                                    icon="◉"
                                    onPress={() => nav("notifications")}
                                />
                                <Label>{tr("维护")}</Label>
                                <Nav
                                    label={tr("同步诊断")}
                                    icon="⌁"
                                    onPress={() => invoke("sync.diagnostics")}
                                />
                                <Nav
                                    label={tr("手机控制 Mac")}
                                    icon="▣"
                                    onPress={() => {
                                        section.set("手机控制 Mac");
                                        nav("settings");
                                    }}
                                />
                            </If>
                            <If when={page() === "notifications"}>
                                <Nav
                                    label={tr("手机通知")}
                                    icon="◉"
                                    count={notifications().length}
                                    active
                                />
                                <Label>{tr("应用")}</Label>
                                <Each
                                    of={[
                                        ...new Set<string>(
                                            notifications().map((n: any) =>
                                                String(
                                                    n.appName ||
                                                        n.app ||
                                                        n.source ||
                                                        "其他",
                                                ),
                                            ),
                                        ),
                                    ]}
                                >
                                    {(n) => (
                                        <Nav
                                            label={n()}
                                            onPress={() => query.set(n())}
                                        />
                                    )}
                                </Each>
                            </If>
                            <If when={page() === "settings"}>
                                <Each
                                    of={[
                                        "通用",
                                        "历史记录",
                                        "快捷键",
                                        "截图",
                                        "录屏",
                                        "输出与预览",
                                        "滚动与标注",
                                        "美化与特效",
                                        "局域网设备",
                                        "权限",
                                        "关于与诊断",
                                    ]}
                                >
                                    {(s) => (
                                        <Nav
                                            label={s()}
                                            active={section() === s()}
                                            onPress={() => section.set(s())}
                                        />
                                    )}
                                </Each>
                            </If>
                            <If when={page() === "words"}>
                                <Nav
                                    label={tr("单词查询")}
                                    active={
                                        section() !== "单词表" &&
                                        section() !== "API 设置"
                                    }
                                    onPress={() => section.set("单词查询")}
                                />
                                <Nav
                                    label={tr("单词表")}
                                    active={section() === "单词表"}
                                    onPress={() => section.set("单词表")}
                                />
                                <Nav
                                    label={tr("API 设置")}
                                    active={section() === "API 设置"}
                                    onPress={() => section.set("API 设置")}
                                />
                            </If>
                            <If
                                when={[
                                    "tools",
                                    "capture",
                                    "recording",
                                    "video",
                                    "onboarding",
                                ].includes(page())}
                            >
                                <Nav
                                    label={tr("截图")}
                                    icon="⌗"
                                    onPress={() => nav("capture")}
                                />
                                <Nav
                                    label={tr("查词")}
                                    icon={tr("文")}
                                    onPress={() => nav("words")}
                                />
                                <Nav
                                    label={tr("单词本")}
                                    icon="▤"
                                    onPress={() => nav("wordbook")}
                                />
                                <Nav
                                    label={tr("生成密码")}
                                    icon="⚿"
                                    onPress={() => nav("tools")}
                                />
                                <Nav
                                    label={tr("录屏")}
                                    icon="●"
                                    onPress={() => nav("recording")}
                                />
                            </If>
                            <View class="flex-1" />
                            <View class="border-t border-border pt-2 gap-1">
                                <Nav
                                    label={tr("工具")}
                                    icon="▦"
                                    active={page() === "tools"}
                                    onPress={() => nav("tools")}
                                />
                                <Nav
                                    label={tr("偏好设置…")}
                                    icon="⚙"
                                    active={page() === "settings"}
                                    onPress={() => nav("settings")}
                                />
                                <Text class="text-[10px] text-muted-foreground px-3 pt-2">
                                    {state().version || "Clipy · NSH"}
                                </Text>
                            </View>
                        </View>
                        <View class="flex-1 min-w-0">
                            <If
                                when={
                                    page() === "history" || page() === "panel"
                                }
                            >
                                <View class="flex-1 flex-row min-w-0">
                                    <View class="w-[350px] border-r border-border min-h-0">
                                        <View class="h-[56px] px-3 flex-row gap-2 items-center border-b border-border">
                                            <Field
                                                label={tr(
                                                    "搜索内容、路径或来源应用",
                                                )}
                                                placeholder={tr(
                                                    "搜索剪贴板历史",
                                                )}
                                                value={query()}
                                                class="flex-1"
                                                onChange={(v: string) => {
                                                    query.set(v);
                                                    a.setQuery?.(v);
                                                }}
                                            />
                                            <Btn
                                                label={tr(
                                                    regex() ? "正则 ✓" : "正则",
                                                )}
                                                onPress={() =>
                                                    regex.set(!regex())
                                                }
                                            />
                                            <Btn
                                                label={tr("清空")}
                                                onPress={() =>
                                                    invoke("history.clear")
                                                }
                                            />
                                        </View>
                                        <View class="px-3 py-3">
                                            <Chips
                                                items={[
                                                    "全部",
                                                    "今天",
                                                    "7 天",
                                                    "30 天",
                                                ]}
                                                value={period()}
                                                onChange={(v: string) => {
                                                    period.set(v);
                                                }}
                                            />
                                        </View>
                                        <View class="px-3 pb-2">
                                            <Chips
                                                translateLabels={false}
                                                items={[
                                                    {
                                                        id: "",
                                                        label: tr("全部来源"),
                                                    },
                                                    ...[
                                                        ...new Set<string>(
                                                            history().map(
                                                                (h: any) =>
                                                                    String(
                                                                        h.sourceApp ||
                                                                            h.source ||
                                                                            "本机",
                                                                    ),
                                                            ),
                                                        ),
                                                    ]
                                                        .slice(0, 6)
                                                        .map((s) => ({
                                                            id: s,
                                                            label: s,
                                                        })),
                                                ]}
                                                value={source()}
                                                onChange={(v: string) =>
                                                    source.set(v)
                                                }
                                            />
                                        </View>
                                        <Scroll
                                            ref={(ref) => {
                                                historyScroll = ref;
                                            }}
                                            class="flex-1 px-2"
                                        >
                                            <Each
                                                of={filtered().slice(
                                                    0,
                                                    historyShown(),
                                                )}
                                                key={(x: any) => x.id}
                                            >
                                                {(get: any) => (
                                                    <View
                                                        role="button"
                                                        accessibilityLabel={titleOf(
                                                            get(),
                                                        )}
                                                        onPress={() =>
                                                            select(get())
                                                        }
                                                        onLayout={(event) =>
                                                            historyBounds.set(
                                                                get().id,
                                                                event.bounds
                                                                    .origin.y,
                                                            )
                                                        }
                                                        onContextMenu={(
                                                            event,
                                                        ) => {
                                                            select(get());
                                                            void showHistoryMenu(
                                                                get(),
                                                                a,
                                                                event.pagePosition,
                                                            );
                                                        }}
                                                        class={`p-3 rounded-xl gap-[5px] mb-1 ${current()?.id === get().id ? "bg-blue-500/15" : "hover:bg-secondary"}`}
                                                    >
                                                        <View class="flex-row gap-2">
                                                            <Text class="text-[16px] text-blue-500">
                                                                {get().type ===
                                                                "image"
                                                                    ? "▧"
                                                                    : get()
                                                                            .type ===
                                                                        "file"
                                                                      ? "▱"
                                                                      : "▤"}
                                                            </Text>
                                                            <Text
                                                                class="text-[13px] text-foreground flex-1 leading-[19px]"
                                                                style={{
                                                                    numberOfLines: 2,
                                                                }}
                                                            >
                                                                {titleOf(get())}
                                                            </Text>
                                                            <If
                                                                when={
                                                                    get()
                                                                        .isPinned ||
                                                                    get().pinned
                                                                }
                                                            >
                                                                <Text class="text-[12px] text-orange-500">
                                                                    ⌖
                                                                </Text>
                                                            </If>
                                                        </View>
                                                        <Text class="text-[11px] text-muted-foreground pl-6">
                                                            {get().sourceApp ||
                                                                get().source ||
                                                                tr("本机")}{" "}
                                                            ·{" "}
                                                            {tr(
                                                                get().date
                                                                    ? new Date(
                                                                          get().date,
                                                                      ).toLocaleString()
                                                                    : "刚刚",
                                                            )}
                                                        </Text>
                                                    </View>
                                                )}
                                            </Each>
                                            <If
                                                when={
                                                    filtered().length >
                                                    historyShown()
                                                }
                                            >
                                                <View class="p-3">
                                                    <Btn
                                                        label={tr(
                                                            "加载更多历史（已显示 {0} / {1}）",
                                                            {
                                                                "0": historyShown(),
                                                                "1": filtered()
                                                                    .length,
                                                            },
                                                        )}
                                                        onPress={() =>
                                                            historyShown.set(
                                                                historyShown() +
                                                                    100,
                                                            )
                                                        }
                                                    />
                                                </View>
                                            </If>
                                            <If when={!filtered().length}>
                                                <Empty
                                                    title={tr("暂无历史记录")}
                                                    description={tr(
                                                        query()
                                                            ? "没有找到匹配内容，试试其他关键词。"
                                                            : "复制的内容会出现在这里。",
                                                    )}
                                                />
                                            </If>
                                        </Scroll>
                                        <Text class="h-[30px] px-3 py-2 border-t border-border text-[10px] text-muted-foreground">
                                            {tr(
                                                "↩ 粘贴 · ⌘P 置顶 · ⌫ 删除 · ⌘Z 撤销",
                                            )}
                                        </Text>
                                    </View>
                                    <View class="flex-1 min-w-0 bg-secondary/30">
                                        <If
                                            when={current()}
                                            else={
                                                <Empty
                                                    title={tr(
                                                        "你的剪贴板，井井有条",
                                                    )}
                                                    description={tr(
                                                        "选择一条历史，预览和管理复制过的内容。",
                                                    )}
                                                />
                                            }
                                        >
                                            {() => (
                                                <View class="flex-1">
                                                    <View class="h-[56px] flex-row items-center gap-2 px-5">
                                                        <Text class="text-[12px] text-muted-foreground flex-1">
                                                            {[
                                                                "image",
                                                                "pdf",
                                                            ].includes(
                                                                current()?.type,
                                                            )
                                                                ? tr(
                                                                      current()
                                                                          ?.type ===
                                                                          "pdf"
                                                                          ? "PDF 文档"
                                                                          : "图片预览",
                                                                  )
                                                                : `${tr(current()?.type || "文本")} · ${textOf(current()).length} ${tr("个字符")}`}
                                                        </Text>
                                                        <Btn
                                                            label={tr(
                                                                current()
                                                                    ?.isPinned
                                                                    ? "取消置顶"
                                                                    : "置顶",
                                                            )}
                                                            onPress={() =>
                                                                a.pinHistory?.(
                                                                    current()
                                                                        ?.id,
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "存为片段",
                                                            )}
                                                            onPress={() =>
                                                                a.saveSnippet?.(
                                                                    {
                                                                        title: titleOf(
                                                                            current(),
                                                                        ),
                                                                        content:
                                                                            textOf(
                                                                                current(),
                                                                            ),
                                                                    },
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr("删除")}
                                                            onPress={() =>
                                                                a.deleteHistory?.(
                                                                    current()
                                                                        ?.id,
                                                                )
                                                            }
                                                        />
                                                    </View>
                                                    <Scroll class="flex-1 mx-5 p-6 bg-card border border-border rounded-xl">
                                                        <Text class="text-[18px] font-semibold text-foreground mb-4">
                                                            {titleOf(current())}
                                                        </Text>
                                                        <If
                                                            when={
                                                                current()
                                                                    ?.type ===
                                                                    "image" ||
                                                                current()
                                                                    ?.type ===
                                                                    "pdf"
                                                            }
                                                            else={
                                                                <Text class="text-[14px] leading-[24px] text-foreground">
                                                                    {textOf(
                                                                        current(),
                                                                    )}
                                                                </Text>
                                                            }
                                                        >
                                                            <If
                                                                when={
                                                                    current()
                                                                        ?.type ===
                                                                        "image" &&
                                                                    current()
                                                                        ?.mediaPath &&
                                                                    mediaPreviewPhase() !==
                                                                        "unavailable"
                                                                }
                                                                else={
                                                                    <Empty
                                                                        title={
                                                                            current()
                                                                                ?.type ===
                                                                                "pdf" &&
                                                                            current()
                                                                                ?.mediaPath
                                                                                ? tr(
                                                                                      "PDF 文档",
                                                                                  )
                                                                                : tr(
                                                                                      mediaPreviewPhase() ===
                                                                                          "loading"
                                                                                          ? "正在加载媒体预览…"
                                                                                          : "无法预览媒体",
                                                                                  )
                                                                        }
                                                                        description={
                                                                            current()
                                                                                ?.type ===
                                                                                "pdf" &&
                                                                            current()
                                                                                ?.mediaPath
                                                                                ? tr(
                                                                                      "PDF 已准备好，可通过下方访达入口查看。",
                                                                                  )
                                                                                : tr(
                                                                                      "重新选择此条记录以重试。",
                                                                                  )
                                                                        }
                                                                    />
                                                                }
                                                            >
                                                                <If
                                                                    when={
                                                                        mediaPreviewPhase() ===
                                                                        "loading"
                                                                    }
                                                                >
                                                                    <Text
                                                                        class={
                                                                            cx.muted
                                                                        }
                                                                    >
                                                                        {tr(
                                                                            "正在加载媒体预览…",
                                                                        )}
                                                                    </Text>
                                                                </If>
                                                                <Image
                                                                    testID="history-media-image"
                                                                    accessibilityLabel={tr(
                                                                        "图片预览",
                                                                    )}
                                                                    src={
                                                                        current()
                                                                            ?.mediaPath
                                                                    }
                                                                    class="w-full h-[300px]"
                                                                    style={{
                                                                        objectFit:
                                                                            "contain",
                                                                    }}
                                                                    onLoadStart={() =>
                                                                        mediaPreviewPhase.set(
                                                                            "loading",
                                                                        )
                                                                    }
                                                                    onLoad={() =>
                                                                        mediaPreviewPhase.set(
                                                                            "idle",
                                                                        )
                                                                    }
                                                                    onError={() =>
                                                                        mediaPreviewPhase.set(
                                                                            "unavailable",
                                                                        )
                                                                    }
                                                                />
                                                            </If>
                                                        </If>
                                                    </Scroll>
                                                    <View class="flex-row mx-5 mt-4 rounded-lg border border-border bg-card p-3 gap-6">
                                                        <View class="flex-1 gap-1">
                                                            <Text
                                                                class={cx.muted}
                                                            >
                                                                {tr("来源")}
                                                            </Text>
                                                            <Text
                                                                class={cx.text}
                                                            >
                                                                {current()
                                                                    ?.sourceApp ||
                                                                    current()
                                                                        ?.source ||
                                                                    tr("本机")}
                                                            </Text>
                                                        </View>
                                                        <View class="flex-1 gap-1">
                                                            <Text
                                                                class={cx.muted}
                                                            >
                                                                {tr("类型")}
                                                            </Text>
                                                            <Text
                                                                class={cx.text}
                                                            >
                                                                {current()
                                                                    ?.type ||
                                                                    "text"}
                                                            </Text>
                                                        </View>
                                                        <View class="flex-1 gap-1">
                                                            <Text
                                                                class={cx.muted}
                                                            >
                                                                {tr("使用次数")}
                                                            </Text>
                                                            <Text
                                                                class={cx.text}
                                                            >
                                                                {current()
                                                                    ?.useCount ||
                                                                    0}
                                                            </Text>
                                                        </View>
                                                    </View>
                                                    <View class="flex-row p-5 gap-2">
                                                        <Btn
                                                            label={tr(
                                                                "复制内容",
                                                            )}
                                                            primary
                                                            onPress={() =>
                                                                copy(current())
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "粘贴为纯文本",
                                                            )}
                                                            onPress={() =>
                                                                copy(
                                                                    current(),
                                                                    true,
                                                                )
                                                            }
                                                        />
                                                        <If
                                                            when={
                                                                current()
                                                                    ?.mediaPath
                                                            }
                                                        >
                                                            <Btn
                                                                label={tr(
                                                                    "在 Finder 中显示",
                                                                )}
                                                                onPress={() =>
                                                                    invoke(
                                                                        "files.reveal",
                                                                        {
                                                                            path: current()
                                                                                ?.mediaPath,
                                                                        },
                                                                    )
                                                                }
                                                            />
                                                        </If>
                                                        <View class="flex-1" />
                                                        <Btn
                                                            label={tr(
                                                                "撤销删除",
                                                            )}
                                                            onPress={() =>
                                                                a.undoDelete?.()
                                                            }
                                                        />
                                                    </View>
                                                </View>
                                            )}
                                        </If>
                                    </View>
                                </View>
                            </If>
                            <If when={page() === "snippets"}>
                                <Header title={tr("片段库")}>
                                    <Btn
                                        label={tr("导入")}
                                        onPress={() =>
                                            invoke("snippets.import")
                                        }
                                    />
                                    <Btn
                                        label={tr("导出")}
                                        onPress={() =>
                                            invoke("snippets.export")
                                        }
                                    />
                                    <Btn
                                        label={tr("新片段")}
                                        primary
                                        onPress={newSnippet}
                                    />
                                </Header>
                                <View class="flex-1 flex-row">
                                    <View class="w-[260px] border-r border-border">
                                        <View class="p-3 gap-2">
                                            <Text class="text-[15px] font-semibold text-foreground">
                                                {folders().find(
                                                    (f: any) =>
                                                        f.id ===
                                                        effectiveFolder(),
                                                )?.name || tr("全部片段")}
                                            </Text>
                                            <Field
                                                placeholder={tr("搜索此文件夹")}
                                                value={query()}
                                                onChange={(v: string) =>
                                                    query.set(v)
                                                }
                                            />
                                        </View>
                                        <Scroll class="flex-1 p-2">
                                            <Each of={visibleSnippets()}>
                                                {(s: any) => (
                                                    <View
                                                        role="button"
                                                        accessibilityLabel={titleOf(
                                                            s(),
                                                        )}
                                                        onPress={() => {
                                                            if (!snippetDragged)
                                                                openSnippet(
                                                                    s(),
                                                                );
                                                            snippetDragged = false;
                                                        }}
                                                        {...snippetPan(s().id)}
                                                        class={`p-3 gap-1 rounded-lg mb-1 ${dropSnippet() === s().id && snippetDragged ? "border-t-2 border-blue-500" : ""} ${dragSnippet() === s().id ? "opacity-60" : ""} ${selectedSnippet() === s().id ? "bg-blue-500" : "hover:bg-secondary"}`}
                                                    >
                                                        <Text
                                                            class={`text-[13px] font-semibold ${selectedSnippet() === s().id ? "text-white" : "text-foreground"}`}
                                                        >
                                                            {titleOf(s())}
                                                        </Text>
                                                        <Text
                                                            class={`text-[12px] ${selectedSnippet() === s().id ? "text-white/80" : "text-muted-foreground"}`}
                                                            style={{
                                                                numberOfLines: 1,
                                                            }}
                                                        >
                                                            {textOf(s())}
                                                        </Text>
                                                    </View>
                                                )}
                                            </Each>
                                        </Scroll>
                                        <View class="p-3 border-t border-border">
                                            <Btn
                                                label={tr("文件夹设置")}
                                                onPress={() => {
                                                    editFolderId.set(
                                                        effectiveFolder(),
                                                    );
                                                    folderShortcut.set(
                                                        folders().find(
                                                            (f: any) =>
                                                                f.id ===
                                                                effectiveFolder(),
                                                        )?.shortcut || "",
                                                    );
                                                    entry.set(
                                                        folders().find(
                                                            (f: any) =>
                                                                f.id ===
                                                                effectiveFolder(),
                                                        )?.name || "",
                                                    );
                                                    modal.set("folder");
                                                }}
                                            />
                                        </View>
                                    </View>
                                    <View class="flex-1 p-7 gap-4">
                                        <View class="flex-row items-center">
                                            <Text class="text-[12px] text-muted-foreground flex-1">
                                                {tr(
                                                    selectedSnippet()
                                                        ? "编辑片段"
                                                        : "新建片段",
                                                )}
                                            </Text>
                                            <Btn
                                                label={tr("复制")}
                                                onPress={() =>
                                                    invoke("clipboard.copy", {
                                                        text: snippetBody(),
                                                    })
                                                }
                                            />
                                            <Btn
                                                label={tr("删除")}
                                                danger
                                                onPress={() =>
                                                    invoke("snippets.delete", {
                                                        id: selectedSnippet(),
                                                    })
                                                }
                                            />
                                        </View>
                                        <View class={cx.row}>
                                            <Text class="text-[11px] text-muted-foreground flex-1">
                                                {tr("片段快捷键")}
                                            </Text>
                                            <Btn
                                                label={
                                                    snippetShortcut() ||
                                                    tr("录入快捷键")
                                                }
                                                disabled={
                                                    !snippetTitle().trim() &&
                                                    !snippetBody()
                                                }
                                                onPress={async () => {
                                                    const result =
                                                        await invoke(
                                                            "shortcuts.capture",
                                                        );
                                                    if (
                                                        result &&
                                                        !result.cancelled &&
                                                        typeof result.shortcut ===
                                                            "string"
                                                    ) {
                                                        snippetShortcut.set(
                                                            result.shortcut,
                                                        );
                                                        snippetDirty = true;
                                                        void flushSnippetDraft().catch(
                                                            () => {},
                                                        );
                                                    }
                                                }}
                                            />
                                            <Btn
                                                label={tr("清除快捷键")}
                                                disabled={!snippetShortcut()}
                                                onPress={() => {
                                                    snippetShortcut.set("");
                                                    snippetDirty = true;
                                                    void flushSnippetDraft().catch(
                                                        () => {},
                                                    );
                                                }}
                                            />
                                        </View>
                                        <Field
                                            placeholder={tr("片段标题")}
                                            value={snippetTitle()}
                                            class="text-[24px] font-semibold"
                                            onChange={(v: string) =>
                                                editSnippet("title", v)
                                            }
                                        />
                                        <Text class="text-[11px] text-muted-foreground border-b border-border pb-3">
                                            {tr("内容")}
                                        </Text>
                                        <Field
                                            placeholder={tr("写下常用内容…")}
                                            multiline
                                            class="flex-1 leading-[25px]"
                                            value={snippetBody()}
                                            onChange={(v: string) =>
                                                editSnippet("content", v)
                                            }
                                        />
                                        <View class="flex-row items-center gap-3">
                                            <Text class="text-[11px] text-muted-foreground flex-1">
                                                {tr(draftStatus())} ·{" "}
                                                {snippetBody().length}
                                                {tr("个字符")}
                                            </Text>
                                            <Btn
                                                label={tr("立即保存")}
                                                primary
                                                onPress={saveSnippet}
                                            />
                                        </View>
                                    </View>
                                </View>
                            </If>
                            <If when={page() === "devices"}>
                                <Header title={tr("我的设备")}>
                                    <Btn
                                        label={tr("刷新设备")}
                                        onPress={() => invoke("sync.refresh")}
                                    />
                                    <Btn
                                        label={tr("手动添加设备")}
                                        primary
                                        onPress={() => {
                                            entry.set("");
                                            modal.set("device");
                                        }}
                                    />
                                </Header>
                                <View class="flex-1 flex-row">
                                    <View class="w-[270px] border-r border-border p-3">
                                        <Text class="text-[11px] text-muted-foreground p-2">
                                            {tr(
                                                "同一网段自动发现 · 跨子网可手动添加",
                                            )}
                                        </Text>
                                        <Scroll class="flex-1">
                                            <Each of={devices()}>
                                                {(d: any) => (
                                                    <View
                                                        role="button"
                                                        accessibilityLabel={
                                                            d().name || d().id
                                                        }
                                                        onPress={() =>
                                                            device.set(d().id)
                                                        }
                                                        class={`p-3 rounded-xl mb-1 gap-2 ${currentDevice()?.id === d().id ? "bg-blue-500/15" : "hover:bg-secondary"}`}
                                                    >
                                                        <Text class="text-[14px] font-medium text-foreground">
                                                            ▣{" "}
                                                            {d().name || d().id}
                                                        </Text>
                                                        <Text class="text-[11px] text-muted-foreground">
                                                            {tr(
                                                                d().online
                                                                    ? "● 在线"
                                                                    : "○ 离线",
                                                            )}{" "}
                                                            ·{" "}
                                                            {tr(
                                                                d().address ||
                                                                    d()
                                                                        .endpoint ||
                                                                    "公网中继",
                                                            )}
                                                        </Text>
                                                    </View>
                                                )}
                                            </Each>
                                            <If when={!devices().length}>
                                                <Empty
                                                    title={tr("连接你的设备")}
                                                    description={tr(
                                                        "打开另一台设备上的 Clipy，或加入公网设备组。",
                                                    )}
                                                    action={tr("公网设备组")}
                                                    onPress={() => nav("relay")}
                                                />
                                            </If>
                                        </Scroll>
                                    </View>
                                    <Scroll class="flex-1 p-6">
                                        <If when={currentDevice()}>
                                            {() => (
                                                <View class="gap-5">
                                                    <Text class="text-[24px] font-semibold text-foreground">
                                                        {currentDevice()
                                                            ?.name ||
                                                            currentDevice()?.id}
                                                    </Text>
                                                    <Text class={cx.muted}>
                                                        {tr(
                                                            currentDevice()
                                                                ?.online
                                                                ? "在线"
                                                                : "离线",
                                                        )}{" "}
                                                        ·{" "}
                                                        {tr(
                                                            currentDevice()
                                                                ?.address ||
                                                                "公网中继",
                                                        )}
                                                    </Text>
                                                    <Card title={tr("同步")}>
                                                        <Setting
                                                            label={tr(
                                                                "同步剪贴板",
                                                            )}
                                                            description={tr(
                                                                "向该设备推送剪贴板历史；对方无需勾选即可接收",
                                                            )}
                                                            value={
                                                                currentDevice()
                                                                    ?.syncClipboard
                                                            }
                                                            onChange={(
                                                                v: boolean,
                                                            ) =>
                                                                invoke(
                                                                    "sync.peerSettings",
                                                                    {
                                                                        id: currentDevice()
                                                                            ?.id,
                                                                        syncClipboard:
                                                                            v,
                                                                    },
                                                                )
                                                            }
                                                        />
                                                        <Setting
                                                            label={tr(
                                                                "同步通知",
                                                            )}
                                                            description={tr(
                                                                "向该设备推送通知",
                                                            )}
                                                            value={
                                                                currentDevice()
                                                                    ?.syncNotifications
                                                            }
                                                            onChange={(
                                                                v: boolean,
                                                            ) =>
                                                                invoke(
                                                                    "sync.peerSettings",
                                                                    {
                                                                        id: currentDevice()
                                                                            ?.id,
                                                                        syncNotifications:
                                                                            v,
                                                                    },
                                                                )
                                                            }
                                                        />
                                                    </Card>
                                                    <Card
                                                        title={tr(
                                                            "发送到 {0}",
                                                            {
                                                                "0":
                                                                    currentDevice()
                                                                        ?.name ||
                                                                    "设备",
                                                            },
                                                        )}
                                                    >
                                                        <View
                                                            onFileDrop={(
                                                                event,
                                                            ) =>
                                                                invoke(
                                                                    "sync.sendPaths",
                                                                    {
                                                                        peerId: currentDevice()
                                                                            ?.id,
                                                                        paths: (
                                                                            (
                                                                                event as any
                                                                            )
                                                                                .files ||
                                                                            event.uris
                                                                        )
                                                                            .map(
                                                                                (
                                                                                    item: any,
                                                                                ) =>
                                                                                    typeof item ===
                                                                                    "string"
                                                                                        ? item
                                                                                        : item.path ||
                                                                                          item.uri ||
                                                                                          item.url,
                                                                            )
                                                                            .filter(
                                                                                (
                                                                                    path: any,
                                                                                ) =>
                                                                                    typeof path ===
                                                                                    "string",
                                                                            ),
                                                                    },
                                                                )
                                                            }
                                                            class="border border-dashed border-border rounded-lg items-center p-8 gap-3"
                                                        >
                                                            <Text class="text-[28px] text-muted-foreground">
                                                                ⇧
                                                            </Text>
                                                            <Text
                                                                class={cx.text}
                                                            >
                                                                {tr(
                                                                    "选择文件或文件夹",
                                                                )}
                                                            </Text>
                                                            <Text
                                                                class={cx.muted}
                                                            >
                                                                {tr(
                                                                    "文件夹 ≤ 512 MiB · 10,000 项",
                                                                )}
                                                            </Text>
                                                            <View
                                                                class={cx.row}
                                                            >
                                                                <Btn
                                                                    label={tr(
                                                                        "发送文本…",
                                                                    )}
                                                                    onPress={() => {
                                                                        sendText.set(
                                                                            "",
                                                                        );
                                                                        modal.set(
                                                                            "send",
                                                                        );
                                                                    }}
                                                                />
                                                                <Btn
                                                                    label={tr(
                                                                        "发送文件或文件夹…",
                                                                    )}
                                                                    primary
                                                                    onPress={() =>
                                                                        invoke(
                                                                            "sync.sendFiles",
                                                                            {
                                                                                peerId: currentDevice()
                                                                                    ?.id,
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                            </View>
                                                        </View>
                                                    </Card>
                                                    <Card
                                                        title={tr("连接状态")}
                                                    >
                                                        <Text class={cx.muted}>
                                                            {tr("设备 ID")}{" "}
                                                            {
                                                                currentDevice()
                                                                    ?.id
                                                            }
                                                        </Text>
                                                        <Text class={cx.muted}>
                                                            {tr("待发送")}{" "}
                                                            {currentDevice()
                                                                ?.pending || 0}
                                                        </Text>
                                                        <Btn
                                                            label={tr(
                                                                "同步诊断",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "sync.diagnostics",
                                                                    {
                                                                        peerId: currentDevice()
                                                                            ?.id,
                                                                    },
                                                                )
                                                            }
                                                        />
                                                    </Card>
                                                    <Card title={tr("接收")}>
                                                        <Text class={cx.muted}>
                                                            {tr(
                                                                "接收目录：{0}",
                                                                {
                                                                    "0":
                                                                        state()
                                                                            .systemInfo
                                                                            ?.receivedDirectory ||
                                                                        tr(
                                                                            "尚未获取",
                                                                        ),
                                                                },
                                                            )}
                                                        </Text>
                                                        <Btn
                                                            label={tr(
                                                                "在访达中显示",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "files.revealReceived",
                                                                )
                                                            }
                                                        />
                                                    </Card>
                                                </View>
                                            )}
                                        </If>
                                    </Scroll>
                                </View>
                            </If>
                            <If when={page() === "notifications"}>
                                <Header title={tr("手机通知")}>
                                    <Field
                                        placeholder={tr("搜索应用或内容")}
                                        value={query()}
                                        onChange={(v: string) => query.set(v)}
                                    />
                                    <Btn
                                        label={tr("通知设置")}
                                        onPress={() =>
                                            modal.set("notifications")
                                        }
                                    />
                                    <Btn
                                        label={tr("清空通知")}
                                        onPress={() =>
                                            invoke("notifications.clear")
                                        }
                                    />
                                </Header>
                                <Scroll class="flex-1 p-5">
                                    <Each
                                        of={notifications().filter((n: any) =>
                                            `${n.appName || n.app || n.source || ""} ${titleOf(n)} ${textOf(n)}`.includes(
                                                query(),
                                            ),
                                        )}
                                    >
                                        {(n: any) => (
                                            <View class="bg-card border border-border rounded-xl p-5 mb-3 gap-3">
                                                <View class={cx.row}>
                                                    <Text class="text-[15px] font-semibold text-foreground flex-1">
                                                        {n().appName ||
                                                            n().app ||
                                                            n().source ||
                                                            tr("手机通知")}
                                                    </Text>
                                                    <Text class={cx.muted}>
                                                        {n().date
                                                            ? new Date(
                                                                  n().date,
                                                              ).toLocaleString()
                                                            : ""}
                                                    </Text>
                                                </View>
                                                <Text class="text-[14px] font-medium text-foreground">
                                                    {titleOf(n())}
                                                </Text>
                                                <Text class="text-[13px] leading-[21px] text-foreground">
                                                    {textOf(n())}
                                                </Text>
                                                <View class={cx.row}>
                                                    <Btn
                                                        label={tr("复制内容")}
                                                        onPress={() =>
                                                            invoke(
                                                                "clipboard.copy",
                                                                {
                                                                    text: textOf(
                                                                        n(),
                                                                    ),
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Btn
                                                        label={tr(
                                                            "在手机上清除",
                                                        )}
                                                        onPress={() =>
                                                            invoke(
                                                                "notifications.dismissRemote",
                                                                {
                                                                    id: n().id,
                                                                    peerId: n()
                                                                        .peerId,
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <View class="flex-1" />
                                                    <Btn
                                                        label={tr("删除")}
                                                        onPress={() =>
                                                            invoke(
                                                                "notifications.delete",
                                                                { id: n().id },
                                                            )
                                                        }
                                                    />
                                                </View>
                                            </View>
                                        )}
                                    </Each>
                                    <If when={!notifications().length}>
                                        <Empty
                                            title={tr("暂无通知")}
                                            description={tr(
                                                "连接 Android 设备并开启通知同步，手机通知会出现在这里。",
                                            )}
                                        />
                                    </If>
                                </Scroll>
                            </If>
                            <If when={page() === "settings"}>
                                <Header title={tr("偏好设置")} />
                                <Scroll class="flex-1 p-7">
                                    <View class="max-w-[720px] gap-5">
                                        <Text class="text-[24px] font-semibold text-foreground">
                                            {tr(section())}
                                        </Text>
                                        <If when={section() === "通用"}>
                                            <Card>
                                                <Setting
                                                    label={tr("登录时启动")}
                                                    value={
                                                        settings().launchAtLogin
                                                    }
                                                    onChange={(v: boolean) => {
                                                        setting(
                                                            "launchAtLogin",
                                                            v,
                                                        );
                                                    }}
                                                />
                                                <Setting
                                                    label={tr(
                                                        "显示隐藏的菜单栏图标",
                                                    )}
                                                    description={tr(
                                                        "不移动原图标；原图不可用时显示应用图标。",
                                                    )}
                                                    value={
                                                        settings()
                                                            .showHiddenIcons
                                                    }
                                                    onChange={(v: boolean) =>
                                                        setting(
                                                            "showHiddenIcons",
                                                            v,
                                                        )
                                                    }
                                                />
                                                <Btn
                                                    label={tr("刷新隐藏图标")}
                                                    onPress={() =>
                                                        invoke(
                                                            "menubar.refresh",
                                                        )
                                                    }
                                                />
                                                <View class={cx.row}>
                                                    <Text class="text-[13px] text-foreground flex-1">
                                                        {tr("语言")}
                                                    </Text>
                                                    <Chips
                                                        value={
                                                            settings()
                                                                .language ||
                                                            "zh-CN"
                                                        }
                                                        items={[
                                                            {
                                                                id: "zh-CN",
                                                                label: "中文",
                                                            },
                                                            {
                                                                id: "en",
                                                                label: "English",
                                                            },
                                                        ]}
                                                        onChange={(v: string) =>
                                                            setting(
                                                                "language",
                                                                v,
                                                            )
                                                        }
                                                    />
                                                </View>
                                            </Card>
                                        </If>
                                        <If when={section() === "历史记录"}>
                                            <Card title={tr("历史记录")}>
                                                <Field
                                                    label={tr("历史数量")}
                                                    value={String(
                                                        settings()
                                                            .historyLimit ||
                                                            1000,
                                                    )}
                                                    onChange={(v: string) =>
                                                        setting(
                                                            "historyLimit",
                                                            Number(v) || 1000,
                                                        )
                                                    }
                                                />
                                                <Chips
                                                    value={String(
                                                        settings()
                                                            .retentionDays || 0,
                                                    )}
                                                    items={[
                                                        {
                                                            id: "0",
                                                            label: "永久",
                                                        },
                                                        {
                                                            id: "7",
                                                            label: "7 天",
                                                        },
                                                        {
                                                            id: "30",
                                                            label: "30 天",
                                                        },
                                                        {
                                                            id: "90",
                                                            label: "90 天",
                                                        },
                                                    ]}
                                                    onChange={(v: string) =>
                                                        setting(
                                                            "retentionDays",
                                                            Number(v),
                                                        )
                                                    }
                                                />
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "超出数量或保留时长的未置顶记录会自动删除。",
                                                    )}
                                                </Text>
                                            </Card>
                                            <Card title={tr("安全与搜索")}>
                                                <Setting
                                                    label={tr("加密本地历史")}
                                                    description={tr(
                                                        "本机专用密钥保存在系统钥匙串中。",
                                                    )}
                                                    value={
                                                        settings()
                                                            .encryptHistory
                                                    }
                                                    onChange={(v: boolean) =>
                                                        setting(
                                                            "encryptHistory",
                                                            v,
                                                        )
                                                    }
                                                />
                                                <Setting
                                                    label={tr(
                                                        "历史图片文字识别",
                                                    )}
                                                    description={tr(
                                                        "让历史搜索能搜到图片中的文字。",
                                                    )}
                                                    value={
                                                        settings().ocrHistory
                                                    }
                                                    onChange={(v: boolean) =>
                                                        setting("ocrHistory", v)
                                                    }
                                                />
                                                <Btn
                                                    label={tr("管理排除应用")}
                                                    onPress={() =>
                                                        invoke(
                                                            "settings.excludedApps",
                                                        )
                                                    }
                                                />
                                            </Card>
                                        </If>
                                        <If when={section() === "快捷键"}>
                                            <Card>
                                                <Each
                                                    of={[
                                                        {
                                                            key: "searchShortcut",
                                                            label: "全局搜索快捷键",
                                                            default: "⇧⌘F",
                                                        },
                                                        {
                                                            key: "wordShortcut",
                                                            label: "单词查询快捷键",
                                                            default: "⌃⌥D",
                                                        },
                                                        {
                                                            key: "captureShortcut",
                                                            label: "全局截图快捷键",
                                                            default: "⇧⌘5",
                                                        },
                                                    ]}
                                                >
                                                    {(s) => (
                                                        <View class={cx.row}>
                                                            <Text class="text-[13px] text-foreground flex-1">
                                                                {tr(s().label)}
                                                            </Text>
                                                            <Btn
                                                                label={
                                                                    settings()[
                                                                        s().key
                                                                    ] ||
                                                                    s().default
                                                                }
                                                                onPress={() =>
                                                                    invoke(
                                                                        "shortcuts.record",
                                                                        {
                                                                            key: s()
                                                                                .key,
                                                                        },
                                                                    )
                                                                }
                                                            />
                                                        </View>
                                                    )}
                                                </Each>
                                            </Card>
                                        </If>
                                        <If
                                            when={[
                                                "截图",
                                                "输出与预览",
                                                "滚动与标注",
                                                "美化与特效",
                                            ].includes(section())}
                                        >
                                            <CapturePreferences
                                                section={section()}
                                                settings={settings()}
                                                save={setting}
                                                invoke={invoke}
                                            />
                                        </If>
                                        <If when={section() === "录屏"}>
                                            <Card>
                                                <Each
                                                    of={[
                                                        {
                                                            key: "recordSystemAudio",
                                                            label: "录制系统音频",
                                                        },
                                                        {
                                                            key: "recordMicrophone",
                                                            label: "录制麦克风",
                                                        },
                                                        {
                                                            key: "recordCamera",
                                                            label: "摄像头悬浮窗",
                                                        },
                                                        {
                                                            key: "recordClicks",
                                                            label: "鼠标点击高亮",
                                                        },
                                                        {
                                                            key: "recordKeys",
                                                            label: "按键显示",
                                                        },
                                                        {
                                                            key: "hideRecordingHud",
                                                            label: "隐藏录制计时 HUD",
                                                        },
                                                    ]}
                                                >
                                                    {(s) => (
                                                        <Setting
                                                            disabled={
                                                                ![
                                                                    "recordSystemAudio",
                                                                    "recordMicrophone",
                                                                    "recordCamera",
                                                                    "recordClicks",
                                                                    "recordKeys",
                                                                    "hideRecordingHud",
                                                                ].includes(
                                                                    s().key,
                                                                )
                                                            }
                                                            label={tr(
                                                                s().label,
                                                            )}
                                                            value={
                                                                settings()[
                                                                    s().key
                                                                ]
                                                            }
                                                            onChange={(
                                                                v: boolean,
                                                            ) =>
                                                                setting(
                                                                    s().key,
                                                                    v,
                                                                )
                                                            }
                                                        />
                                                    )}
                                                </Each>
                                                <If
                                                    when={settings().recordKeys}
                                                >
                                                    <Chips
                                                        items={[
                                                            {
                                                                id: "shortcuts",
                                                                label: "仅快捷键",
                                                            },
                                                            {
                                                                id: "all",
                                                                label: "所有按键",
                                                            },
                                                        ]}
                                                        value={
                                                            settings()
                                                                .keyMode ||
                                                            "shortcuts"
                                                        }
                                                        onChange={(v: string) =>
                                                            setting(
                                                                "keyMode",
                                                                v,
                                                            )
                                                        }
                                                    />
                                                </If>
                                                <Chips
                                                    items={["30 fps", "60 fps"]}
                                                    value={
                                                        settings().recordFps ||
                                                        "30 fps"
                                                    }
                                                    onChange={(v: string) =>
                                                        setting("recordFps", v)
                                                    }
                                                />
                                            </Card>
                                        </If>
                                        <If when={section() === "局域网设备"}>
                                            <Card title={tr("本机配置")}>
                                                <Field
                                                    label={tr("设备名称")}
                                                    value={
                                                        settings().deviceName ||
                                                        ""
                                                    }
                                                    onChange={(v: string) =>
                                                        setting("deviceName", v)
                                                    }
                                                />
                                                <Setting
                                                    label={tr("启用局域网同步")}
                                                    value={
                                                        settings().syncEnabled
                                                    }
                                                    onChange={(v: boolean) =>
                                                        setting(
                                                            "syncEnabled",
                                                            v,
                                                        )
                                                    }
                                                />
                                                <Field
                                                    label={tr("同步端口")}
                                                    value={String(
                                                        settings().syncPort ||
                                                            5566,
                                                    )}
                                                    onChange={(v: string) =>
                                                        setting(
                                                            "syncPort",
                                                            Number(v),
                                                        )
                                                    }
                                                />
                                                <Btn
                                                    label={tr("保存连接设置")}
                                                    primary
                                                    onPress={() =>
                                                        invoke(
                                                            "sync.configure",
                                                            settings(),
                                                        )
                                                    }
                                                />
                                            </Card>
                                            <Card
                                                title={tr("不在同一个网络？")}
                                            >
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "通过公网设备组连接异地设备。局域网无需配置中继。",
                                                    )}
                                                </Text>
                                                <Btn
                                                    label={tr("管理公网设备组")}
                                                    onPress={() => nav("relay")}
                                                />
                                            </Card>
                                        </If>
                                        <If when={section() === "手机控制 Mac"}>
                                            <Card
                                                title={tr("手机控制 Mac 屏幕")}
                                            >
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "仅支持当前已登录账户的锁屏，不支持开机 FileVault、注销或切换用户。",
                                                    )}
                                                </Text>
                                                <Field
                                                    label={tr(
                                                        "当前 Mac 登录密码",
                                                    )}
                                                    masked
                                                    value={entry()}
                                                    onChange={(v: string) =>
                                                        entry.set(v)
                                                    }
                                                />
                                                <Btn
                                                    label={tr("验证并保存")}
                                                    primary
                                                    onPress={() => {
                                                        invoke(
                                                            "screenControl.configure",
                                                            {
                                                                password:
                                                                    entry(),
                                                            },
                                                        );
                                                        entry.set("");
                                                    }}
                                                />
                                                <Btn
                                                    label={tr("关闭并删除密码")}
                                                    danger
                                                    onPress={() =>
                                                        invoke(
                                                            "screenControl.disable",
                                                        )
                                                    }
                                                />
                                            </Card>
                                        </If>
                                        <If when={section() === "权限"}>
                                            <Card title={tr("系统权限")}>
                                                <Each
                                                    of={[
                                                        {
                                                            id: "screen",
                                                            label: "屏幕录制",
                                                            hint: "截图 / 录屏必需",
                                                        },
                                                        {
                                                            id: "accessibility",
                                                            label: "辅助功能",
                                                            hint: "自动粘贴、元素吸附",
                                                        },
                                                        {
                                                            id: "input",
                                                            label: "输入监控",
                                                            hint: "录屏按键显示",
                                                        },
                                                        {
                                                            id: "microphone",
                                                            label: "麦克风",
                                                            hint: "录制人声",
                                                        },
                                                        {
                                                            id: "camera",
                                                            label: "摄像头",
                                                            hint: "摄像头悬浮窗",
                                                        },
                                                        {
                                                            id: "notifications",
                                                            label: "通知",
                                                            hint: "文件接收和手机通知提醒",
                                                        },
                                                    ]}
                                                >
                                                    {(s) => (
                                                        <View class={cx.row}>
                                                            <View class="flex-1 gap-1">
                                                                <Text
                                                                    class={
                                                                        cx.text
                                                                    }
                                                                >
                                                                    {tr(
                                                                        s()
                                                                            .label,
                                                                    )}
                                                                </Text>
                                                                <Text
                                                                    class={
                                                                        cx.muted
                                                                    }
                                                                >
                                                                    {tr(
                                                                        s()
                                                                            .hint,
                                                                    )}
                                                                </Text>
                                                            </View>
                                                            <Btn
                                                                label={tr(
                                                                    "查看 / 请求权限",
                                                                )}
                                                                onPress={() =>
                                                                    invoke(
                                                                        "permissions.request",
                                                                        {
                                                                            permission:
                                                                                s()
                                                                                    .id,
                                                                        },
                                                                    )
                                                                }
                                                            />
                                                        </View>
                                                    )}
                                                </Each>
                                            </Card>
                                        </If>
                                        <If when={section() === "关于与诊断"}>
                                            <Card title="Clipy">
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        state().version ||
                                                            "NSH macOS 客户端",
                                                    )}
                                                </Text>
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "NSH 运行时 + TSX · 本地数据与系统原生能力",
                                                    )}
                                                </Text>
                                            </Card>
                                            <Card title={tr("诊断")}>
                                                <Btn
                                                    label={tr("显示日志…")}
                                                    onPress={() =>
                                                        invoke("logs.show")
                                                    }
                                                />
                                                <Btn
                                                    label={tr("打开日志文件夹")}
                                                    onPress={() =>
                                                        invoke("logs.reveal")
                                                    }
                                                />
                                                <Btn
                                                    label={tr(
                                                        "查看首次使用引导",
                                                    )}
                                                    onPress={() =>
                                                        nav("onboarding")
                                                    }
                                                />
                                                <Btn
                                                    label={tr("构建与存储信息")}
                                                    onPress={() =>
                                                        invoke(
                                                            "system.diagnostics",
                                                        )
                                                    }
                                                />
                                            </Card>
                                        </If>
                                    </View>
                                </Scroll>
                            </If>
                            <If when={page() === "words"}>
                                <Header title={tr("查词与单词表")}>
                                    <Btn
                                        label={tr("API 设置")}
                                        onPress={() => section.set("API 设置")}
                                    />
                                </Header>
                                <Scroll class="flex-1 p-7">
                                    <View class="max-w-[780px] gap-5">
                                        <If
                                            when={
                                                section() !== "单词表" &&
                                                section() !== "API 设置"
                                            }
                                        >
                                            <View class="flex-row items-center gap-2">
                                                <Field
                                                    class="flex-1"
                                                    placeholder={tr(
                                                        "输入单词或需要翻译的句子",
                                                    )}
                                                    value={wordInput()}
                                                    onChange={(v: string) =>
                                                        wordInput.set(v)
                                                    }
                                                    onSubmit={() =>
                                                        a.lookup?.(wordInput())
                                                    }
                                                />
                                                <Btn
                                                    label={tr("查询")}
                                                    primary
                                                    onPress={() =>
                                                        a.lookup?.(wordInput())
                                                    }
                                                />
                                                <Btn
                                                    label={tr("模型翻译")}
                                                    onPress={() =>
                                                        a.translate?.(
                                                            wordInput(),
                                                        )
                                                    }
                                                />
                                            </View>
                                            <Text class={cx.muted}>
                                                {tr(
                                                    "提交后才联网查询；词条可保存到单词表，模型译文不保存。",
                                                )}
                                            </Text>
                                            <If when={state().wordResult}>
                                                <DictionaryCard
                                                    result={() =>
                                                        state().wordResult
                                                    }
                                                    onSpeak={(text: string) =>
                                                        invoke("speech.speak", {
                                                            text,
                                                            language: "en-US",
                                                        })
                                                    }
                                                    onBook={() =>
                                                        nav("wordbook")
                                                    }
                                                />
                                            </If>
                                            <If when={state().translation}>
                                                <Card title={tr("模型翻译")}>
                                                    <Text class="text-[14px] leading-[24px] text-foreground">
                                                        {typeof state()
                                                            .translation ===
                                                        "string"
                                                            ? state()
                                                                  .translation
                                                            : state()
                                                                  .translation
                                                                  ?.text || ""}
                                                    </Text>
                                                    <Btn
                                                        label={tr("复制译文")}
                                                        onPress={() =>
                                                            invoke(
                                                                "clipboard.copy",
                                                                {
                                                                    text: state()
                                                                        .translation,
                                                                },
                                                            )
                                                        }
                                                    />
                                                </Card>
                                            </If>
                                            <If
                                                when={
                                                    !state().wordResult &&
                                                    !state().translation
                                                }
                                            >
                                                <Empty
                                                    title={tr("遇见一个新单词")}
                                                    description={tr(
                                                        "输入英文单词查词义、发音与例句，或使用模型翻译句子。",
                                                    )}
                                                    icon={tr("文")}
                                                />
                                            </If>
                                        </If>
                                        <If when={section() === "单词表"}>
                                            <WordBook
                                                words={() =>
                                                    state().words || []
                                                }
                                                onQuery={(word: string) => {
                                                    wordInput.set(word);
                                                    section.set("单词查询");
                                                    a.lookup?.(word);
                                                }}
                                                onFamiliar={(id: string) =>
                                                    invoke("words.familiar", {
                                                        id,
                                                    })
                                                }
                                            />
                                        </If>
                                        <If when={section() === "API 设置"}>
                                            <Card title={tr("模型翻译设置")}>
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "支持 Chat Completions 兼容接口。HTTP 仅限本机回环地址。",
                                                    )}
                                                </Text>
                                                <Field
                                                    label={tr("接口地址")}
                                                    value={modelURL()}
                                                    onChange={(v: string) => {
                                                        markModelDirty();
                                                        modelURL.set(v);
                                                    }}
                                                />
                                                <Field
                                                    label="API Key"
                                                    masked
                                                    value={entry()}
                                                    onChange={(v: string) => {
                                                        markModelDirty();
                                                        entry.set(v);
                                                    }}
                                                />
                                                <Text class={cx.muted}>
                                                    {modelHasKey()
                                                        ? tr(
                                                              "API Key 已保存（不显示密钥）",
                                                          )
                                                        : tr(
                                                              "尚未保存 API Key",
                                                          )}
                                                </Text>
                                                <If when={modelHasKey()}>
                                                    <Text class="text-[12px] text-orange-500">
                                                        {tr(
                                                            "留空保存将删除已存密钥。",
                                                        )}
                                                    </Text>
                                                </If>
                                                <Field
                                                    label={tr("模型名称")}
                                                    value={modelName()}
                                                    onChange={(v: string) => {
                                                        markModelDirty();
                                                        modelName.set(v);
                                                    }}
                                                />
                                                <View class={cx.row}>
                                                    <Btn
                                                        label={tr("获取模型")}
                                                        onPress={() =>
                                                            invoke(
                                                                "models.list",
                                                                {
                                                                    endpoint:
                                                                        modelURL(),
                                                                    ...(entry()
                                                                        ? {
                                                                              key: entry(),
                                                                          }
                                                                        : {}),
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Btn
                                                        label={tr("保存")}
                                                        primary
                                                        onPress={
                                                            saveModelSettings
                                                        }
                                                    />
                                                </View>
                                                <Field
                                                    placeholder={tr("筛选模型")}
                                                    value={modelFilter()}
                                                    onChange={(value: string) =>
                                                        modelFilter.set(value)
                                                    }
                                                />
                                                <Each
                                                    of={(
                                                        state().models || []
                                                    ).filter((model: any) =>
                                                        String(
                                                            typeof model ===
                                                                "string"
                                                                ? model
                                                                : model.id,
                                                        )
                                                            .toLowerCase()
                                                            .includes(
                                                                modelFilter().toLowerCase(),
                                                            ),
                                                    )}
                                                >
                                                    {(m: any) => (
                                                        <Btn
                                                            label={
                                                                typeof m() ===
                                                                "string"
                                                                    ? m()
                                                                    : m().id
                                                            }
                                                            onPress={() => {
                                                                markModelDirty();
                                                                modelName.set(
                                                                    typeof m() ===
                                                                        "string"
                                                                        ? m()
                                                                        : m()
                                                                              .id,
                                                                );
                                                            }}
                                                        />
                                                    )}
                                                </Each>
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "密钥保存在系统钥匙串。仅提交翻译时发送文本。",
                                                    )}
                                                </Text>
                                            </Card>
                                        </If>
                                    </View>
                                </Scroll>
                            </If>
                            <If when={page() === "tools"}>
                                <Header title={tr("工具")} />
                                <Scroll class="flex-1 p-7">
                                    <View class="max-w-[720px] gap-5">
                                        <Card title={tr("生成密码")}>
                                            <View class="p-5 rounded-lg bg-secondary">
                                                <Text class="text-[22px] font-mono text-foreground">
                                                    {tr(
                                                        state().password ||
                                                            "点击重新生成",
                                                    )}
                                                </Text>
                                            </View>
                                            <View class={cx.row}>
                                                <Text class="flex-1 text-[13px] text-foreground">
                                                    {tr("长度")}
                                                </Text>
                                                <Field
                                                    label={tr("密码长度")}
                                                    value={pwLength()}
                                                    onChange={(v: string) =>
                                                        pwLength.set(v)
                                                    }
                                                />
                                            </View>
                                            <Each
                                                of={[
                                                    {
                                                        id: "upper",
                                                        label: "大写字母 A-Z",
                                                    },
                                                    {
                                                        id: "lower",
                                                        label: "小写字母 a-z",
                                                    },
                                                    {
                                                        id: "numbers",
                                                        label: "数字 0-9",
                                                    },
                                                    {
                                                        id: "symbols",
                                                        label: "符号 !@#$%",
                                                    },
                                                    {
                                                        id: "excludeAmbiguous",
                                                        label: "排除易混淆字符",
                                                    },
                                                ]}
                                            >
                                                {(c) => (
                                                    <Setting
                                                        label={tr(c().label)}
                                                        value={
                                                            (chars() as any)[
                                                                c().id
                                                            ]
                                                        }
                                                        onChange={(
                                                            v: boolean,
                                                        ) =>
                                                            chars.set({
                                                                ...chars(),
                                                                [c().id]: v,
                                                            })
                                                        }
                                                    />
                                                )}
                                            </Each>
                                            <View class={cx.row}>
                                                <Btn
                                                    label={tr("重新生成")}
                                                    onPress={() =>
                                                        a.generatePassword?.({
                                                            length: Number(
                                                                pwLength(),
                                                            ),
                                                            ...chars(),
                                                            digits: chars()
                                                                .numbers,
                                                        })
                                                    }
                                                />
                                                <Btn
                                                    label={tr("复制密码")}
                                                    primary
                                                    disabled={!state().password}
                                                    onPress={() =>
                                                        invoke(
                                                            "clipboard.copy",
                                                            {
                                                                text: state()
                                                                    .password,
                                                            },
                                                        )
                                                    }
                                                />
                                            </View>
                                        </Card>
                                        <Card title={tr("保持唤醒")}>
                                            <Setting
                                                label={tr(
                                                    "阻止闲置时屏幕关闭和 Mac 睡眠",
                                                )}
                                                description={tr(
                                                    "合盖或手动睡眠仍有效；退出 Clipy 时自动关闭。",
                                                )}
                                                value={state().keepAwake}
                                                onChange={(v: boolean) => {
                                                    invoke("system.keepAwake", {
                                                        enabled: v,
                                                    });
                                                }}
                                            />
                                        </Card>
                                        <Card title={tr("常用功能")}>
                                            <View class={cx.row}>
                                                <Btn
                                                    label={tr("截图")}
                                                    onPress={() =>
                                                        nav("capture")
                                                    }
                                                />
                                                <Btn
                                                    label={tr("查词")}
                                                    onPress={() => nav("words")}
                                                />
                                                <Btn
                                                    label={tr("单词本")}
                                                    onPress={() =>
                                                        nav("wordbook")
                                                    }
                                                />
                                                <Btn
                                                    label={tr("录屏")}
                                                    onPress={() =>
                                                        nav("recording")
                                                    }
                                                />
                                            </View>
                                        </Card>
                                    </View>
                                </Scroll>
                            </If>
                            <If when={page() === "relay"}>
                                <Header title={tr("公网设备组")}>
                                    <Btn
                                        label={tr("刷新")}
                                        onPress={() => invoke("relay.refresh")}
                                    />
                                    <Btn
                                        label={tr("中继设置")}
                                        onPress={openRelaySettings}
                                    />
                                </Header>
                                <Scroll class="flex-1 p-7">
                                    <View class="max-w-[780px] gap-5">
                                        <If when={state().relay?.authRejected}>
                                            <Card title={tr("中继认证未通过")}>
                                                <Text class="text-[13px] text-muted-foreground leading-[22px]">
                                                    {tr(
                                                        "认证未通过，组信息暂时隐藏，身份与局域网配置保留。",
                                                    )}
                                                </Text>
                                                <Btn
                                                    label={tr("检查中继设置")}
                                                    primary
                                                    onPress={openRelaySettings}
                                                />
                                            </Card>
                                        </If>
                                        <If when={!state().relay?.authRejected}>
                                            <Text class="text-[24px] font-semibold text-foreground">
                                                {tr(
                                                    "在不同网络之间连接你的设备",
                                                )}
                                            </Text>
                                            <Text class={cx.muted}>
                                                {tr(
                                                    "使用 common-relay · 端到端加密 · 身份保存在本机",
                                                )}
                                            </Text>
                                            <If when={!state().relay?.group}>
                                                <Card>
                                                    <View class={cx.row}>
                                                        <Btn
                                                            label={tr(
                                                                "加入已有组",
                                                            )}
                                                            onPress={() => {
                                                                entry.set("");
                                                                modal.set(
                                                                    "joinGroup",
                                                                );
                                                            }}
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "创建新组",
                                                            )}
                                                            primary
                                                            onPress={() => {
                                                                entry.set("");
                                                                modal.set(
                                                                    "createGroup",
                                                                );
                                                            }}
                                                        />
                                                    </View>
                                                </Card>
                                            </If>
                                            <If
                                                when={
                                                    state().relay?.joinPending
                                                }
                                            >
                                                <Card
                                                    title={tr("等待加入设备组")}
                                                >
                                                    <Text class="text-[24px] font-mono text-foreground">
                                                        {state().relay
                                                            ?.pairingCode ||
                                                            tr("正在等待授权")}
                                                    </Text>
                                                    <Text class={cx.muted}>
                                                        {tr(
                                                            "在邀请设备上核对配对码；批准或自动授权完成后会自动加入。",
                                                        )}
                                                    </Text>
                                                    <Btn
                                                        label={tr(
                                                            "放弃本次申请",
                                                        )}
                                                        danger
                                                        onPress={() =>
                                                            invoke(
                                                                "relay.cancelJoin",
                                                            )
                                                        }
                                                    />
                                                </Card>
                                            </If>
                                            <If when={state().relay?.error}>
                                                <Card
                                                    title={tr("中继连接异常")}
                                                >
                                                    <Text class="text-[13px] text-red-500">
                                                        {state().relay?.error}
                                                    </Text>
                                                    <Btn
                                                        label={tr(
                                                            "检查中继设置",
                                                        )}
                                                        onPress={
                                                            openRelaySettings
                                                        }
                                                    />
                                                </Card>
                                            </If>
                                            <If when={state().relay?.group}>
                                                <Card
                                                    translateTitle={false}
                                                    title={
                                                        state().relay?.group
                                                            ?.name ||
                                                        tr("我的设备组")
                                                    }
                                                >
                                                    <Each
                                                        of={
                                                            state().relay
                                                                ?.members || []
                                                        }
                                                    >
                                                        {(m: any) => (
                                                            <View
                                                                class={cx.row}
                                                            >
                                                                <View class="flex-1 gap-1">
                                                                    <Text
                                                                        class={
                                                                            cx.text
                                                                        }
                                                                    >
                                                                        {m()
                                                                            .name ||
                                                                            memberID(
                                                                                m(),
                                                                            )}
                                                                    </Text>
                                                                    <Text class="text-[10px] text-muted-foreground">
                                                                        {memberID(
                                                                            m(),
                                                                        )}
                                                                        {memberID(
                                                                            m(),
                                                                        ) ===
                                                                        state()
                                                                            .relay
                                                                            ?.device
                                                                            ? ` · ${tr("本机")}`
                                                                            : ""}
                                                                    </Text>
                                                                    <Text
                                                                        class={
                                                                            cx.muted
                                                                        }
                                                                    >
                                                                        {tr(
                                                                            m()
                                                                                .online ===
                                                                                true
                                                                                ? "在线"
                                                                                : m()
                                                                                        .online ===
                                                                                    false
                                                                                  ? "离线"
                                                                                  : "状态未知",
                                                                        )}{" "}
                                                                        ·{" "}
                                                                        {tr(
                                                                            m()
                                                                                .manager
                                                                                ? "管理员"
                                                                                : "成员",
                                                                        )}
                                                                    </Text>
                                                                </View>
                                                                <Btn
                                                                    label={tr(
                                                                        "改名",
                                                                    )}
                                                                    onPress={() => {
                                                                        device.set(
                                                                            memberID(
                                                                                m(),
                                                                            ),
                                                                        );
                                                                        entry.set(
                                                                            m()
                                                                                .name ||
                                                                                "",
                                                                        );
                                                                        modal.set(
                                                                            "renameMember",
                                                                        );
                                                                    }}
                                                                />
                                                                <Btn
                                                                    label={tr(
                                                                        "移除",
                                                                    )}
                                                                    danger
                                                                    onPress={() =>
                                                                        invoke(
                                                                            "relay.remove",
                                                                            {
                                                                                device: memberID(
                                                                                    m(),
                                                                                ),
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                            </View>
                                                        )}
                                                    </Each>
                                                    <Btn
                                                        label={tr("添加设备")}
                                                        disabled={
                                                            !isRelayManager()
                                                        }
                                                        primary
                                                        onPress={() =>
                                                            invoke(
                                                                "relay.invite",
                                                                {
                                                                    auto:
                                                                        settings()
                                                                            .autoInvite !==
                                                                        false,
                                                                    mode:
                                                                        settings()
                                                                            .autoInvite ===
                                                                        false
                                                                            ? "manual"
                                                                            : "auto",
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Setting
                                                        label={tr(
                                                            "扫码后自动加入",
                                                        )}
                                                        description={tr(
                                                            "关闭后需核对配对码并手动批准。",
                                                        )}
                                                        value={
                                                            settings()
                                                                .autoInvite !==
                                                            false
                                                        }
                                                        onChange={(
                                                            v: boolean,
                                                        ) =>
                                                            setting(
                                                                "autoInvite",
                                                                v,
                                                            )
                                                        }
                                                    />
                                                    <If when={invitation()}>
                                                        <If
                                                            when={
                                                                invitation()
                                                                    ?.qrImage
                                                            }
                                                        >
                                                            <View class="w-[314px] h-[314px] bg-white rounded-xl p-8 self-center">
                                                                <Image
                                                                    testID="relay-invite-qr"
                                                                    accessibilityLabel={tr(
                                                                        "设备组邀请二维码",
                                                                    )}
                                                                    src={
                                                                        invitation()
                                                                            .qrImage
                                                                    }
                                                                    style={{
                                                                        width: 250,
                                                                        height: 250,
                                                                        objectFit:
                                                                            "contain",
                                                                    }}
                                                                />
                                                            </View>
                                                        </If>
                                                        <Field
                                                            label={tr(
                                                                "邀请链接",
                                                            )}
                                                            readonly
                                                            multiline
                                                            value={
                                                                invitation()
                                                                    ?.short_link ||
                                                                invitation()
                                                                    ?.link ||
                                                                String(
                                                                    invitation(),
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "复制邀请链接",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "clipboard.copy",
                                                                    {
                                                                        sensitive: true,
                                                                        text:
                                                                            invitation()
                                                                                ?.short_link ||
                                                                            invitation()
                                                                                ?.link,
                                                                    },
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "取消邀请",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "relay.cancel",
                                                                )
                                                            }
                                                        />
                                                    </If>
                                                    <Each
                                                        of={
                                                            state().relay
                                                                ?.pending || []
                                                        }
                                                    >
                                                        {(r: any) => (
                                                            <Card
                                                                title={tr(
                                                                    "加入申请：{0}",
                                                                    {
                                                                        "0":
                                                                            r()
                                                                                .name ||
                                                                            r()
                                                                                .id,
                                                                    },
                                                                )}
                                                            >
                                                                <Text
                                                                    class={
                                                                        cx.text
                                                                    }
                                                                >
                                                                    {tr(
                                                                        r()
                                                                            .pairingCode ||
                                                                            r()
                                                                                .code ||
                                                                            r()
                                                                                .fingerprint ||
                                                                            "请在对端核对配对码",
                                                                    )}
                                                                </Text>
                                                                <Setting
                                                                    label={tr(
                                                                        "允许此设备邀请和移除组成员",
                                                                    )}
                                                                    value={
                                                                        !!pendingManagers()[
                                                                            pendingKey(
                                                                                r(),
                                                                            )
                                                                        ]
                                                                    }
                                                                    onChange={(
                                                                        value: boolean,
                                                                    ) =>
                                                                        pendingManagers.set(
                                                                            {
                                                                                ...pendingManagers(),
                                                                                [pendingKey(
                                                                                    r(),
                                                                                )]:
                                                                                    value,
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                                <Btn
                                                                    label={tr(
                                                                        "配对码一致，批准加入",
                                                                    )}
                                                                    primary
                                                                    onPress={() =>
                                                                        invoke(
                                                                            "relay.approve",
                                                                            {
                                                                                request:
                                                                                    r()
                                                                                        .request ||
                                                                                    r(),
                                                                                manager:
                                                                                    !!pendingManagers()[
                                                                                        pendingKey(
                                                                                            r(),
                                                                                        )
                                                                                    ],
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                            </Card>
                                                        )}
                                                    </Each>
                                                </Card>
                                                <Card>
                                                    <Text class={cx.muted}>
                                                        {tr(
                                                            "退出仅影响本机；解散会撤销整个组的公网访问权限。",
                                                        )}
                                                    </Text>
                                                    <View class={cx.row}>
                                                        <Btn
                                                            label={tr(
                                                                "退出当前组",
                                                            )}
                                                            danger
                                                            onPress={() =>
                                                                modal.set(
                                                                    "leaveGroup",
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "解散设备组",
                                                            )}
                                                            danger
                                                            onPress={() =>
                                                                modal.set(
                                                                    "disbandGroup",
                                                                )
                                                            }
                                                        />
                                                    </View>
                                                </Card>
                                            </If>
                                        </If>
                                    </View>
                                </Scroll>
                            </If>
                            <If
                                when={
                                    page() === "capture" ||
                                    page() === "recording" ||
                                    page() === "video"
                                }
                            >
                                <Header title={tr(title())}>
                                    <Btn
                                        label={tr("截图设置")}
                                        onPress={() => {
                                            section.set(
                                                page() === "recording"
                                                    ? "录屏"
                                                    : "截图",
                                            );
                                            nav("settings");
                                        }}
                                    />
                                </Header>
                                <Scroll class="flex-1 p-7">
                                    <View class="max-w-[800px] gap-5">
                                        <If when={page() === "capture"}>
                                            <Text class="text-[24px] font-semibold text-foreground">
                                                {tr("捕捉值得留下的瞬间")}
                                            </Text>
                                            <Text class={cx.muted}>
                                                {tr(
                                                    "区域、窗口、全屏 · 原生分辨率",
                                                )}
                                            </Text>
                                            <Card>
                                                <View class={cx.row}>
                                                    <Btn
                                                        label={tr("区域截图")}
                                                        primary
                                                        onPress={() =>
                                                            invoke(
                                                                "capture.start",
                                                                {
                                                                    mode: "region",
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Btn
                                                        label={tr("窗口截图")}
                                                        onPress={() =>
                                                            invoke(
                                                                "capture.start",
                                                                {
                                                                    mode: "window",
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Btn
                                                        label={tr("全屏截图")}
                                                        onPress={() =>
                                                            invoke(
                                                                "capture.start",
                                                                {
                                                                    mode: "screen",
                                                                },
                                                            )
                                                        }
                                                    />
                                                    <Btn
                                                        label={tr("滚动截图")}
                                                        onPress={() =>
                                                            invoke(
                                                                "capture.start",
                                                                {
                                                                    mode: "scroll",
                                                                },
                                                            )
                                                        }
                                                    />
                                                </View>
                                            </Card>
                                            <If
                                                when={
                                                    state().capturePath ||
                                                    state().capture?.path
                                                }
                                            >
                                                <Card title={tr("截图结果")}>
                                                    <Image
                                                        src={
                                                            state()
                                                                .capturePath ||
                                                            state().capture
                                                                ?.path
                                                        }
                                                        class="w-full h-[300px]"
                                                    />
                                                    <View class="flex-row flex-wrap gap-2">
                                                        <Each
                                                            of={[
                                                                {
                                                                    id: "copy",
                                                                    label: "复制",
                                                                },
                                                                {
                                                                    id: "save",
                                                                    label: "保存",
                                                                },
                                                                {
                                                                    id: "pin",
                                                                    label: "贴图",
                                                                },
                                                                {
                                                                    id: "ocr",
                                                                    label: "识别文字与二维码",
                                                                },
                                                                {
                                                                    id: "translate",
                                                                    label: "翻译",
                                                                },
                                                                {
                                                                    id: "edit",
                                                                    label: "标注编辑",
                                                                },
                                                                {
                                                                    id: "share",
                                                                    label: "分享",
                                                                },
                                                            ]}
                                                        >
                                                            {(t) => (
                                                                <Btn
                                                                    label={tr(
                                                                        t()
                                                                            .label,
                                                                    )}
                                                                    onPress={() =>
                                                                        invoke(
                                                                            `capture.${t().id}`,
                                                                            {
                                                                                path:
                                                                                    state()
                                                                                        .capturePath ||
                                                                                    state()
                                                                                        .capture
                                                                                        ?.path,
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                            )}
                                                        </Each>
                                                    </View>
                                                </Card>
                                            </If>
                                            <Card title={tr("图片编辑")}>
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "打开本机图片，进行标注、美化和文字识别。",
                                                    )}
                                                </Text>
                                                <Btn
                                                    label={tr("打开图片…")}
                                                    onPress={() =>
                                                        invoke(
                                                            "capture.openImage",
                                                        )
                                                    }
                                                />
                                            </Card>
                                        </If>
                                        <If when={page() === "recording"}>
                                            <Text class="text-[24px] font-semibold text-foreground">
                                                {tr("录下画面，也留住声音")}
                                            </Text>
                                            <Card>
                                                <Each
                                                    of={[
                                                        {
                                                            id: "recordSystemAudio",
                                                            label: "系统声音",
                                                        },
                                                        {
                                                            id: "recordMicrophone",
                                                            label: "麦克风",
                                                        },
                                                        {
                                                            id: "recordCamera",
                                                            label: "摄像头",
                                                        },
                                                        {
                                                            id: "recordClicks",
                                                            label: "鼠标点击高亮",
                                                        },
                                                        {
                                                            id: "recordKeys",
                                                            label: "按键显示",
                                                        },
                                                    ]}
                                                >
                                                    {(s) => (
                                                        <Setting
                                                            disabled={
                                                                ![
                                                                    "recordSystemAudio",
                                                                    "recordMicrophone",
                                                                    "recordCamera",
                                                                    "recordClicks",
                                                                    "recordKeys",
                                                                    "hideRecordingHud",
                                                                ].includes(
                                                                    s().id,
                                                                )
                                                            }
                                                            label={tr(
                                                                s().label,
                                                            )}
                                                            value={
                                                                settings()[
                                                                    s().id
                                                                ]
                                                            }
                                                            onChange={(
                                                                v: boolean,
                                                            ) =>
                                                                setting(
                                                                    s().id,
                                                                    v,
                                                                )
                                                            }
                                                        />
                                                    )}
                                                </Each>
                                                <View class={cx.row}>
                                                    <Btn
                                                        label={tr(
                                                            state().recording
                                                                ?.active
                                                                ? "结束录制"
                                                                : "选择区域并开始录制",
                                                        )}
                                                        primary
                                                        onPress={() =>
                                                            invoke(
                                                                state()
                                                                    .recording
                                                                    ?.active
                                                                    ? "recording.stop"
                                                                    : "recording.start",
                                                                settings(),
                                                            )
                                                        }
                                                    />
                                                    <If
                                                        when={
                                                            state().recording
                                                                ?.path
                                                        }
                                                    >
                                                        <Btn
                                                            label={tr(
                                                                "打开视频编辑器",
                                                            )}
                                                            onPress={() =>
                                                                nav("video")
                                                            }
                                                        />
                                                    </If>
                                                </View>
                                            </Card>
                                        </If>
                                        <If when={page() === "video"}>
                                            <Card title={tr("视频编辑器")}>
                                                <Text class={cx.muted}>
                                                    {tr(
                                                        "打开视频后可预览与导出。处理进度和结果由系统任务提供。",
                                                    )}
                                                </Text>
                                                <Btn
                                                    label={tr("打开视频…")}
                                                    primary
                                                    onPress={() =>
                                                        invoke("video.open")
                                                    }
                                                />
                                                <If
                                                    when={
                                                        state().video?.path ||
                                                        state().videoPath
                                                    }
                                                >
                                                    <Video
                                                        src={videoPreviewPath()}
                                                        controls
                                                        class="w-full h-[320px] bg-black rounded-lg"
                                                    />
                                                    <Text class={cx.text}>
                                                        {state().video?.path ||
                                                            state().videoPath}
                                                    </Text>
                                                    <If when={isGifResult()}>
                                                        <Text class={cx.muted}>
                                                            {tr(
                                                                "GIF 已导出，预览继续播放原视频。",
                                                            )}
                                                        </Text>
                                                    </If>
                                                    <View class={cx.row}>
                                                        <Field
                                                            label={tr(
                                                                "入点（秒）",
                                                            )}
                                                            value={videoIn()}
                                                            onChange={(
                                                                v: string,
                                                            ) => videoIn.set(v)}
                                                        />
                                                        <Field
                                                            label={tr(
                                                                "出点（秒，留空至结束）",
                                                            )}
                                                            value={videoOut()}
                                                            onChange={(
                                                                v: string,
                                                            ) =>
                                                                videoOut.set(v)
                                                            }
                                                        />
                                                        <Field
                                                            label={tr("倍速")}
                                                            value={videoRate()}
                                                            onChange={(
                                                                v: string,
                                                            ) =>
                                                                videoRate.set(v)
                                                            }
                                                        />
                                                    </View>
                                                    <View class="flex-row gap-2 flex-wrap">
                                                        <Each
                                                            of={[
                                                                "剪切",
                                                                "缩放",
                                                                "遮挡",
                                                                "文字",
                                                                "变速",
                                                                "定格",
                                                            ]}
                                                        >
                                                            {(t) => (
                                                                <Btn
                                                                    label={t()}
                                                                    onPress={() =>
                                                                        invoke(
                                                                            "video.addEffect",
                                                                            {
                                                                                type: t(),
                                                                                start:
                                                                                    Number(
                                                                                        videoIn(),
                                                                                    ) ||
                                                                                    0,
                                                                                end: videoOut()
                                                                                    ? Number(
                                                                                          videoOut(),
                                                                                      )
                                                                                    : state()
                                                                                          .videoInfo
                                                                                          ?.duration ||
                                                                                      1,
                                                                                speed: 2,
                                                                                duration: 1,
                                                                                zoom: 2,
                                                                                x: 0.25,
                                                                                y: 0.25,
                                                                                width: 0.5,
                                                                                height: 0.5,
                                                                                mode: "mosaic",
                                                                                text: "文字",
                                                                                fontSize: 24,
                                                                            },
                                                                        )
                                                                    }
                                                                />
                                                            )}
                                                        </Each>
                                                    </View>
                                                    <Card
                                                        title={tr("导出参数")}
                                                    >
                                                        <Text class={cx.muted}>
                                                            {tr("输出尺寸")}
                                                        </Text>
                                                        <Chips
                                                            items={[
                                                                {
                                                                    id: "1",
                                                                    label: tr(
                                                                        "原始尺寸",
                                                                    ),
                                                                },
                                                                {
                                                                    id: "0.75",
                                                                    label: "75%",
                                                                },
                                                                {
                                                                    id: "0.5",
                                                                    label: "50%",
                                                                },
                                                                {
                                                                    id: "0.33",
                                                                    label: "33%",
                                                                },
                                                                {
                                                                    id: "0.25",
                                                                    label: "25%",
                                                                },
                                                            ]}
                                                            value={videoScale()}
                                                            onChange={(
                                                                value: string,
                                                            ) =>
                                                                videoScale.set(
                                                                    value,
                                                                )
                                                            }
                                                        />
                                                        <Text class={cx.muted}>
                                                            {tr("导出质量")}
                                                        </Text>
                                                        <Chips
                                                            items={[
                                                                {
                                                                    id: "high",
                                                                    label: tr(
                                                                        "quality.high",
                                                                    ),
                                                                },
                                                                {
                                                                    id: "medium",
                                                                    label: tr(
                                                                        "quality.medium",
                                                                    ),
                                                                },
                                                                {
                                                                    id: "low",
                                                                    label: tr(
                                                                        "quality.low",
                                                                    ),
                                                                },
                                                            ]}
                                                            value={videoQuality()}
                                                            onChange={(
                                                                value: string,
                                                            ) =>
                                                                videoQuality.set(
                                                                    value,
                                                                )
                                                            }
                                                        />
                                                    </Card>
                                                    <VideoEffects
                                                        items={() =>
                                                            state()
                                                                .videoEffects ||
                                                            []
                                                        }
                                                        actions={a}
                                                        start={() =>
                                                            Number(videoIn()) ||
                                                            0
                                                        }
                                                        end={() =>
                                                            videoOut()
                                                                ? Number(
                                                                      videoOut(),
                                                                  )
                                                                : state()
                                                                      .videoInfo
                                                                      ?.duration ||
                                                                  1
                                                        }
                                                    />
                                                    <View class={cx.row}>
                                                        <Btn
                                                            label={tr(
                                                                "导出 MP4",
                                                            )}
                                                            primary
                                                            onPress={() =>
                                                                invoke(
                                                                    "video.export",
                                                                    {
                                                                        path:
                                                                            state()
                                                                                .video
                                                                                ?.path ||
                                                                            state()
                                                                                .videoPath,
                                                                        format: "mp4",
                                                                        start: Number(
                                                                            videoIn(),
                                                                        ),
                                                                        end: videoOut()
                                                                            ? Number(
                                                                                  videoOut(),
                                                                              )
                                                                            : undefined,
                                                                        speed: Number(
                                                                            videoRate(),
                                                                        ),
                                                                        scale: Number(
                                                                            videoScale(),
                                                                        ),
                                                                        quality:
                                                                            videoQuality(),
                                                                    },
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr(
                                                                "导出 GIF",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "video.export",
                                                                    {
                                                                        path:
                                                                            state()
                                                                                .video
                                                                                ?.path ||
                                                                            state()
                                                                                .videoPath,
                                                                        format: "gif",
                                                                        start: Number(
                                                                            videoIn(),
                                                                        ),
                                                                        end: videoOut()
                                                                            ? Number(
                                                                                  videoOut(),
                                                                              )
                                                                            : undefined,
                                                                        speed: Number(
                                                                            videoRate(),
                                                                        ),
                                                                        scale: Number(
                                                                            videoScale(),
                                                                        ),
                                                                        quality:
                                                                            videoQuality(),
                                                                    },
                                                                )
                                                            }
                                                        />
                                                        <Btn
                                                            label={tr("取消")}
                                                            onPress={() =>
                                                                invoke(
                                                                    "video.cancel",
                                                                )
                                                            }
                                                        />
                                                    </View>
                                                    <If
                                                        when={
                                                            state().videoExport
                                                                ?.path
                                                        }
                                                    >
                                                        <Card
                                                            title={tr(
                                                                "上次导出结果",
                                                            )}
                                                        >
                                                            <Field
                                                                label={tr(
                                                                    "输出文件",
                                                                )}
                                                                readonly
                                                                value={
                                                                    state()
                                                                        .videoExport
                                                                        ?.path ||
                                                                    ""
                                                                }
                                                            />
                                                            <View
                                                                class={cx.row}
                                                            >
                                                                <Field
                                                                    label={tr(
                                                                        "实际输出尺寸",
                                                                    )}
                                                                    readonly
                                                                    value={
                                                                        state()
                                                                            .videoExport
                                                                            ?.width &&
                                                                        state()
                                                                            .videoExport
                                                                            ?.height
                                                                            ? `${state().videoExport.width} × ${state().videoExport.height}`
                                                                            : tr(
                                                                                  "等待元数据",
                                                                              )
                                                                    }
                                                                />
                                                                <Field
                                                                    label={tr(
                                                                        "实际时长",
                                                                    )}
                                                                    readonly
                                                                    value={
                                                                        Number.isFinite(
                                                                            state()
                                                                                .videoExport
                                                                                ?.duration,
                                                                        )
                                                                            ? `${Number(state().videoExport.duration).toFixed(2)} s`
                                                                            : tr(
                                                                                  "等待元数据",
                                                                              )
                                                                    }
                                                                />
                                                            </View>
                                                            <Field
                                                                label={tr(
                                                                    "实际帧率",
                                                                )}
                                                                readonly
                                                                value={
                                                                    Number.isFinite(
                                                                        state()
                                                                            .videoExport
                                                                            ?.fps,
                                                                    )
                                                                        ? `${Number(state().videoExport.fps).toFixed(2)} fps`
                                                                        : tr(
                                                                              "等待元数据",
                                                                          )
                                                                }
                                                            />
                                                            <Field
                                                                label={tr(
                                                                    "文件大小",
                                                                )}
                                                                readonly
                                                                value={
                                                                    Number.isFinite(
                                                                        state()
                                                                            .videoExport
                                                                            ?.bytes ??
                                                                            state()
                                                                                .videoExport
                                                                                ?.fileSize,
                                                                    )
                                                                        ? `${(Number(state().videoExport.bytes ?? state().videoExport.fileSize) / 1048576).toFixed(2)} MiB`
                                                                        : tr(
                                                                              "等待元数据",
                                                                          )
                                                                }
                                                            />
                                                        </Card>
                                                        <Btn
                                                            label={tr(
                                                                "在 Finder 中显示导出文件",
                                                            )}
                                                            onPress={() =>
                                                                invoke(
                                                                    "files.reveal",
                                                                    {
                                                                        path: state()
                                                                            .videoExport
                                                                            .path,
                                                                    },
                                                                )
                                                            }
                                                        />
                                                    </If>
                                                    <If
                                                        when={
                                                            state()
                                                                .videoProgress !==
                                                            undefined
                                                        }
                                                    >
                                                        <Text class={cx.muted}>
                                                            {tr("导出进度")}{" "}
                                                            {Math.round(
                                                                state()
                                                                    .videoProgress *
                                                                    100,
                                                            )}
                                                            %
                                                        </Text>
                                                    </If>
                                                </If>
                                            </Card>
                                        </If>
                                    </View>
                                </Scroll>
                            </If>
                            <If when={page() === "onboarding"}>
                                <View class="flex-1 items-center justify-center p-10 gap-6">
                                    <Text class="text-[40px] text-blue-500">
                                        ▤
                                    </Text>
                                    <Text class="text-[28px] font-semibold text-foreground">
                                        {tr("欢迎使用 Clipy")}
                                    </Text>
                                    <Text class="text-[14px] text-muted-foreground text-center leading-[24px]">
                                        {tr(
                                            "复制过的内容随手可取，常用文字一键输入，\\n手机和 Mac 之间自由流转。",
                                        )}
                                    </Text>
                                    <View class="gap-3">
                                        <Btn
                                            label={tr("设置权限")}
                                            onPress={() => {
                                                section.set("权限");
                                                nav("settings");
                                            }}
                                        />
                                        <Btn
                                            label={tr("连接你的设备")}
                                            onPress={() => nav("devices")}
                                        />
                                        <Btn
                                            label={tr("开始使用")}
                                            primary
                                            onPress={() => {
                                                setting(
                                                    "onboardingComplete",
                                                    true,
                                                );
                                                nav("history");
                                            }}
                                        />
                                    </View>
                                </View>
                            </If>
                        </View>
                    </View>
                </If>
                <If when={failedDraftCount() > 0}>
                    <View class="flex-row items-center gap-3 bg-red-500/10 border-t border-red-500/30 px-5 py-3">
                        <Text class="text-[12px] text-red-500 flex-1">
                            {tr("未保存草稿已保留（{0}），关闭前请重试。", {
                                "0": failedDraftCount(),
                            })}
                        </Text>
                        <Btn
                            label={tr("重试保存草稿")}
                            onPress={() =>
                                void retryFailedDrafts().catch(() => {})
                            }
                        />
                    </View>
                </If>
                <If when={tr(state().message)}>
                    <View class="flex-row items-center bg-blue-500/10 border-t border-border px-5 py-2">
                        <Text class="text-[12px] text-foreground flex-1">
                            {tr(state().message)}
                        </Text>
                        <If when={state().busy}>
                            <Text class={cx.muted}>{tr("正在处理…")}</Text>
                        </If>
                    </View>
                </If>
                <If when={modal()}>
                    <View class="absolute inset-0 bg-black/20 items-center justify-center">
                        <View class="w-[430px] bg-card rounded-2xl p-6 gap-4 border border-border">
                            <Text class="text-[18px] font-semibold text-foreground">
                                {tr(
                                    {
                                        device: "手动添加设备",
                                        folder: "文件夹设置",
                                        send: "发送文本",
                                        createGroup: "创建你的设备组",
                                        joinGroup: "加入已有设备组",
                                        renameMember: "修改设备名称",
                                        relaySettings: "中继设置",
                                        leaveGroup: "退出当前组？",
                                        disbandGroup: "解散整个设备组？",
                                        notifications: "通知设置",
                                    }[modal()] || "设置",
                                )}
                            </Text>
                            <If when={modal() === "device"}>
                                <Field
                                    placeholder={tr(
                                        "IPv4 地址，例如 192.168.1.20",
                                    )}
                                    value={entry()}
                                    onChange={(v: string) => entry.set(v)}
                                />
                                <Field
                                    label={tr("端口")}
                                    value={port()}
                                    onChange={(v: string) => port.set(v)}
                                />
                                <Text class={cx.muted}>
                                    {tr(
                                        "跨频段或跨子网时，可输入对方 IP 尝试连接。",
                                    )}
                                </Text>
                            </If>
                            <If
                                when={[
                                    "folder",
                                    "createGroup",
                                    "renameMember",
                                ].includes(modal())}
                            >
                                <Field
                                    label={tr(
                                        modal() === "folder"
                                            ? "文件夹名称"
                                            : modal() === "createGroup"
                                              ? "设备组名称"
                                              : "设备名称",
                                    )}
                                    value={entry()}
                                    onChange={(v: string) => entry.set(v)}
                                />
                            </If>
                            <If when={modal() === "folder"}>
                                <View class={cx.row}>
                                    <Text class="text-[12px] text-muted-foreground flex-1">
                                        {tr("文件夹快捷键")}
                                    </Text>
                                    <Btn
                                        label={
                                            folderShortcut() || tr("录入快捷键")
                                        }
                                        onPress={async () => {
                                            const result =
                                                await invoke(
                                                    "shortcuts.capture",
                                                );
                                            if (
                                                result &&
                                                !result.cancelled &&
                                                typeof result.shortcut ===
                                                    "string"
                                            )
                                                folderShortcut.set(
                                                    result.shortcut,
                                                );
                                        }}
                                    />
                                    <Btn
                                        label={tr("清除快捷键")}
                                        disabled={!folderShortcut()}
                                        onPress={() => folderShortcut.set("")}
                                    />
                                </View>
                            </If>
                            <If when={modal() === "send"}>
                                <Field
                                    placeholder={tr(
                                        "文本将发送到对方设备并写入剪贴板",
                                    )}
                                    multiline
                                    class="h-[160px]"
                                    value={sendText()}
                                    onChange={(v: string) => sendText.set(v)}
                                />
                            </If>
                            <If when={modal() === "joinGroup"}>
                                <Field
                                    placeholder={tr(
                                        "粘贴 common-relay 邀请链接",
                                    )}
                                    multiline
                                    value={entry()}
                                    onChange={(v: string) => entry.set(v)}
                                />
                                <Btn
                                    label={tr("从二维码图片读取")}
                                    onPress={() => invoke("relay.readQR")}
                                />
                            </If>
                            <If when={modal() === "relaySettings"}>
                                <Field
                                    label={tr("中继地址")}
                                    value={relayURL()}
                                    onChange={(value: string) =>
                                        relayURL.set(value)
                                    }
                                />
                                <Field
                                    label={tr("访问密码")}
                                    masked
                                    value={entry()}
                                    onChange={(value: string) =>
                                        entry.set(value)
                                    }
                                />
                                <Text class={cx.muted}>
                                    {tr(
                                        "同一服务器留空保持访问密码；切换服务器时请重新输入。",
                                    )}
                                </Text>
                                <Btn
                                    label={
                                        relayAdvanced()
                                            ? tr("收起高级接入配置")
                                            : tr("高级接入配置")
                                    }
                                    onPress={() =>
                                        relayAdvanced.set(!relayAdvanced())
                                    }
                                />
                                <If when={relayAdvanced()}>
                                    <Field
                                        label={tr("设备 ID")}
                                        value={relayDevice()}
                                        onChange={(value: string) =>
                                            relayDevice.set(value)
                                        }
                                    />
                                    <Field
                                        label={tr("公网 Key（留空保持）")}
                                        masked
                                        value={relayToken()}
                                        onChange={(value: string) =>
                                            relayToken.set(value)
                                        }
                                    />
                                    <Field
                                        label={tr(
                                            "接入配置 JSON（隐藏输入，最多 64 KiB）",
                                        )}
                                        masked
                                        maxLength={65536}
                                        value={relayJSON()}
                                        onChange={(value: string) =>
                                            relayJSON.set(value)
                                        }
                                    />
                                    <Text class="text-[11px] text-muted-foreground">
                                        {tr(
                                            "接入配置可能包含私钥，仅安全传给本机中继 SDK，不写入日志。",
                                        )}
                                    </Text>
                                </If>
                                <If when={relayFormError()}>
                                    <Text class="text-[12px] text-red-500">
                                        {relayFormError()}
                                    </Text>
                                </If>
                            </If>
                            <If when={modal() === "notifications"}>
                                <Setting
                                    label={tr("启用通知同步")}
                                    value={settings().notificationSync}
                                    onChange={(v: boolean) =>
                                        setting("notificationSync", v)
                                    }
                                />
                                <Setting
                                    label={tr("弹出 Mac 横幅")}
                                    value={settings().notificationBanner}
                                    onChange={(v: boolean) =>
                                        setting("notificationBanner", v)
                                    }
                                />
                                <Setting
                                    label={tr("通知声音")}
                                    value={settings().notificationSound}
                                    onChange={(v: boolean) =>
                                        setting("notificationSound", v)
                                    }
                                />
                                <Field
                                    label={tr("关键字（逗号分隔）")}
                                    value={
                                        settings().notificationKeywords || ""
                                    }
                                    onChange={(v: string) =>
                                        setting("notificationKeywords", v)
                                    }
                                />
                                <Field
                                    label={tr("屏蔽关键字")}
                                    value={settings().notificationBlocked || ""}
                                    onChange={(v: string) =>
                                        setting("notificationBlocked", v)
                                    }
                                />
                            </If>
                            <If
                                when={
                                    modal() === "leaveGroup" ||
                                    modal() === "disbandGroup"
                                }
                            >
                                <Text class="text-[13px] text-muted-foreground leading-[22px]">
                                    {tr(
                                        modal() === "disbandGroup"
                                            ? "所有设备将失去本组公网访问权限，未使用的邀请会失效。此操作不可撤销。"
                                            : "本机将退出设备组，其他设备不受影响。",
                                    )}
                                    {tr("本机历史记录和局域网配置会保留。")}
                                </Text>
                            </If>
                            <View class="flex-row justify-end gap-2">
                                <Btn
                                    label={tr("取消")}
                                    onPress={() => {
                                        modal.set("");
                                        relayToken.set("");
                                        relayJSON.set("");
                                        entry.set("");
                                    }}
                                />
                                <Btn
                                    label={tr(
                                        ["leaveGroup", "disbandGroup"].includes(
                                            modal(),
                                        )
                                            ? "确认"
                                            : "保存",
                                    )}
                                    primary
                                    onPress={async () => {
                                        const m = modal();
                                        if (m === "relaySettings") {
                                            if (await submitRelaySettings())
                                                modal.set("");
                                            return;
                                        }
                                        if (m === "device")
                                            invoke("sync.addPeer", {
                                                host: entry(),
                                                port: Number(port()),
                                            });
                                        if (m === "folder")
                                            invoke("snippets.saveFolder", {
                                                id: editFolderId(),
                                                name: entry(),
                                                shortcut: folderShortcut(),
                                            });
                                        if (m === "send")
                                            invoke("sync.sendText", {
                                                peerId: currentDevice()?.id,
                                                text: sendText(),
                                            });
                                        if (m === "createGroup")
                                            invoke("relay.create", {
                                                name: entry(),
                                            });
                                        if (m === "joinGroup")
                                            invoke("relay.join", {
                                                link: entry(),
                                            });
                                        if (m === "renameMember")
                                            invoke("relay.rename", {
                                                id: device(),
                                                name: entry(),
                                            });

                                        if (m === "leaveGroup")
                                            invoke("relay.leave");
                                        if (m === "disbandGroup")
                                            invoke("relay.disband");
                                        entry.set("");
                                        modal.set("");
                                    }}
                                />
                            </View>
                        </View>
                    </View>
                </If>
            </If>
        </View>
    );
}

function CompactPanel(p: any) {
    const tab = signal("剪贴板");
    const q = signal("");
    const kind = signal("全部");
    const st = () => p.state();
    const act = p.actions;
    if (st().settings?.showHiddenIcons) void act.invoke?.("menubar.refresh");
    const copy = (row: any) => act.copyHistory?.(row.id, true, false);

    const items = () =>
        (st().history || []).filter(
            (r: any) =>
                (!q() ||
                    `${titleOf(r)} ${textOf(r)}`
                        .toLowerCase()
                        .includes(q().toLowerCase())) &&
                (kind() === "全部" ||
                    r.type ===
                        (
                            {
                                文本: "text",
                                图片: "image",
                                文件: "file",
                                富文本: "richText",
                            } as any
                        )[kind()]),
        );
    const selectedRow = signal("");
    let unbindPanel: (() => void) | undefined;
    effect(() => {
        const active = tab() === "剪贴板";
        unbindPanel?.();
        unbindPanel = active
            ? bindHistoryKeys({
                  rows: items,
                  current: () =>
                      items().find((row: any) => row.id === selectedRow()) ||
                      items()[0],
                  select: (row: any) => selectedRow.set(row.id),
                  actions: act,
              })
            : undefined;
    });
    cleanup(() => unbindPanel?.());
    return (
        <View class="flex-1 bg-background p-3 gap-3">
            <Field
                placeholder={tr("搜索剪贴板与功能")}
                value={q()}
                onChange={(v: string) => q.set(v)}
                class="h-[35px]"
            />
            <View class="flex-row p-1 bg-secondary rounded-lg">
                <Each
                    of={[
                        { id: "剪贴板", icon: "clipboard" },
                        { id: "片段", icon: "snippets" },
                        { id: "设备", icon: "devices" },
                        { id: "工具", icon: "tools" },
                    ]}
                >
                    {(t) => (
                        <View
                            role="button"
                            accessibilityLabel={t().id}
                            onPress={() => tab.set(t().id)}
                            class={`flex-1 flex-row items-center justify-center gap-1 py-[6px] rounded-md ${tab() === t().id ? "bg-background" : ""}`}
                        >
                            <Icon
                                name={t().icon}
                                size={14}
                                color={tab() === t().id ? "#087BFF" : "#808088"}
                            />
                            <Text
                                class={`text-[12px] ${tab() === t().id ? "text-blue-500 font-medium" : "text-muted-foreground"}`}
                            >
                                {t().id}
                            </Text>
                        </View>
                    )}
                </Each>
            </View>
            <If when={st().settings?.showHiddenIcons}>
                <View class="gap-2">
                    <View class="flex-row items-center">
                        <Text class="text-[10px] text-muted-foreground flex-1">
                            {tr("隐藏的菜单栏图标")}
                        </Text>
                        <Btn
                            label={tr("刷新")}
                            onPress={() => act.invoke?.("menubar.refresh")}
                        />
                    </View>
                    <Scroll horizontal class="h-[30px]">
                        <View class="flex-row gap-2">
                            <Each of={st().hiddenIcons || []}>
                                {(item: any) => (
                                    <Btn
                                        translateLabel={false}
                                        label={
                                            item().title ||
                                            item().bundleId ||
                                            tr("菜单栏项目")
                                        }
                                        onPress={() =>
                                            act.invoke?.("menubar.open", {
                                                id: item().id,
                                            })
                                        }
                                    />
                                )}
                            </Each>
                        </View>
                    </Scroll>
                </View>
            </If>
            <View class="h-px bg-border" />
            <Scroll class="flex-1 min-h-0">
                <If when={tab() === "剪贴板"}>
                    <View class="gap-2">
                        <Chips
                            items={["全部", "文本", "图片", "文件", "富文本"]}
                            value={kind()}
                            onChange={(v: string) => kind.set(v)}
                        />
                        <Each of={items().slice(0, 30)}>
                            {(r: any) => (
                                <View
                                    onContextMenu={(event) => {
                                        selectedRow.set(r().id);
                                        void showHistoryMenu(
                                            r(),
                                            act,
                                            event.pagePosition,
                                        );
                                    }}
                                    class="flex-row items-center gap-3 p-3 rounded-lg hover:bg-secondary"
                                >
                                    <View
                                        role="button"
                                        accessibilityLabel={titleOf(r())}
                                        onPress={() => copy(r())}
                                        onContextMenu={(event) => {
                                            selectedRow.set(r().id);
                                            void showHistoryMenu(
                                                r(),
                                                act,
                                                event.pagePosition,
                                            );
                                        }}
                                        class="flex-1 gap-1"
                                    >
                                        <Text
                                            class="text-[13px] text-foreground"
                                            style={{ numberOfLines: 2 }}
                                        >
                                            {titleOf(r())}
                                        </Text>
                                        <Text class="text-[10px] text-muted-foreground">
                                            {r().sourceApp || tr("本机")}
                                        </Text>
                                    </View>
                                    <Btn
                                        label={tr("复制")}
                                        onPress={() =>
                                            act.copyHistory?.(
                                                r().id,
                                                false,
                                                false,
                                            )
                                        }
                                    />
                                </View>
                            )}
                        </Each>
                        <If when={!items().length}>
                            <Empty
                                title={tr("暂无历史记录")}
                                description={tr("复制的内容会出现在这里。")}
                            />
                        </If>
                    </View>
                </If>
                <If when={tab() === "片段"}>
                    <Each of={st().snippets || []}>
                        {(s: any) => (
                            <View
                                role="button"
                                onPress={() => act.copySnippet?.(s().id)}
                                accessibilityLabel={titleOf(s())}
                                class="p-3 gap-1 rounded-lg hover:bg-secondary"
                            >
                                <Text class="text-[13px] font-medium text-foreground">
                                    {titleOf(s())}
                                </Text>
                                <Text
                                    class="text-[11px] text-muted-foreground"
                                    style={{ numberOfLines: 1 }}
                                >
                                    {textOf(s())}
                                </Text>
                            </View>
                        )}
                    </Each>
                    <If when={!(st().snippets || []).length}>
                        <Empty
                            title={tr("还没有片段")}
                            description={tr("将常用内容保存到片段库。")}
                            action={tr("管理片段")}
                            onPress={() => act.navigate?.("snippets")}
                        />
                    </If>
                </If>
                <If when={tab() === "设备"}>
                    <Each of={st().devices || []}>
                        {(d: any) => (
                            <View class="p-3 gap-2">
                                <Text class="text-[14px] font-medium text-foreground">
                                    ▣ {d().name || d().id}
                                </Text>
                                <Text class={cx.muted}>
                                    {tr(d().online ? "在线" : "离线")} ·{" "}
                                    {tr(d().address || "公网中继")}
                                </Text>
                                <Btn
                                    label={tr("管理设备与发送文件")}
                                    onPress={() => act.navigate?.("devices")}
                                />
                            </View>
                        )}
                    </Each>
                    <If when={!(st().devices || []).length}>
                        <Empty
                            title={tr("连接你的设备")}
                            description={tr("跨设备同步剪贴板与文件。")}
                            action={tr("管理设备")}
                            onPress={() => act.navigate?.("devices")}
                        />
                    </If>
                </If>
                <If when={tab() === "工具"}>
                    <View class="gap-4 p-2">
                        <Text class="text-[18px] font-semibold text-foreground">
                            {tr("工具")}
                        </Text>
                        <Text class={cx.muted}>{tr("常用功能，触手可及")}</Text>
                        <Each
                            of={[
                                {
                                    id: "capture",
                                    label: "截图",
                                    hint: "区域、窗口、全屏与标注",
                                },
                                {
                                    id: "words",
                                    label: "查词",
                                    hint: "词义、发音与中英翻译",
                                },
                                {
                                    id: "tools",
                                    label: "生成密码",
                                    hint: "选择长度与字符类型",
                                },
                            ]}
                        >
                            {(t) => (
                                <View
                                    role="button"
                                    accessibilityLabel={tr(t().label)}
                                    onPress={() => act.navigate?.(t().id)}
                                    class="p-3 rounded-xl bg-secondary gap-1"
                                >
                                    <Text class="text-[14px] font-medium text-foreground">
                                        {tr(t().label)}
                                    </Text>
                                    <Text class={cx.muted}>{tr(t().hint)}</Text>
                                </View>
                            )}
                        </Each>
                    </View>
                </If>
            </Scroll>
            <If when={tab() !== "工具"}>
                <Btn
                    label={tr(
                        tab() === "剪贴板"
                            ? "查看全部历史"
                            : tab() === "片段"
                              ? "管理片段"
                              : "连接与同步设置",
                    )}
                    onPress={() =>
                        act.navigate?.(
                            tab() === "剪贴板"
                                ? "history"
                                : tab() === "片段"
                                  ? "snippets"
                                  : "devices",
                        )
                    }
                />
            </If>
            <View class="flex-row items-center gap-2 border-t border-border pt-2">
                <Btn
                    label={tr(
                        st().keepAwake ? "保持唤醒 · 已开启" : "保持唤醒",
                    )}
                    onPress={() =>
                        act.invoke?.("system.keepAwake", {
                            enabled: !st().keepAwake,
                        })
                    }
                />
                <View class="flex-1" />
                <Btn
                    label={tr("通知 {0}", {
                        "0": (st().notifications || []).length,
                    })}
                    onPress={() => act.navigate?.("notifications")}
                />
                <Btn label="⚙" onPress={() => act.navigate?.("settings")} />
            </View>
        </View>
    );
}
