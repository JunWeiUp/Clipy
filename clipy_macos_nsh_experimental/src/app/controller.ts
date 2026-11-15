import { signal, Storage, Notifications, effect, setColorScheme } from "nsh";
import { AlertDialog } from "nsh/base";
import {
    createAppModel,
    notificationMatches,
    modelEndpoint,
    type AppState,
} from "../core/model";
import { NativeBridge } from "../native/bridge";
import { Window } from "nsh/desktop";
import process from "process";
import { randomUUID } from "crypto";
import { createNativeStorage } from "../core/native-storage";
import type { StorageAdapter, HistoryEntry } from "../core/types";
import { setLocale, t } from "../ui/locale";
import { openExcludedApps } from "./excluded-apps";
import metadata from "../../nsh.json";

type Service = Pick<NativeBridge, "call" | "on" | "close">;
export function createController(
    options: {
        bridge?: Service;
        storage?: StorageAdapter;
        confirm?: (title: string) => Promise<boolean>;
    } = {},
) {
    const bridge = options.bridge || new NativeBridge();
    let desktopConfigure: ((next: any, old: any) => Promise<void>) | undefined;
    const useNativeStorage = !options.storage && !!process.env.CLIPY_NSH_HELPER;
    const nativeStorage = createNativeStorage(bridge);
    const stateStorage: StorageAdapter =
        options.storage ||
        (useNativeStorage
            ? {
                  ...nativeStorage,
                  async getItem(key) {
                      const value = await nativeStorage.getItem(key);
                      if (value !== null) return value;
                      const legacy = await Storage.getItem(key);
                      if (legacy !== null) {
                          await nativeStorage.setItem(key, legacy);
                          if ((await nativeStorage.getItem(key)) === legacy)
                              await Storage.removeItem(key);
                      }
                      return legacy;
                  },
              }
            : Storage);
    let previewLease: { id: string; path: string; leaseId: string } | null =
        null;
    let previewGeneration = 0;
    let captureLease: { id: string; path: string; leaseId: string } | null =
        null;
    const stampLeases = new Map<string,{id:string,leaseId:string,path:string,bytes:number}>();
    let stampImporting = false, appendCapturing = false, editorEpoch = 0;
    function requireEditor(epoch:number) {
        if (disposed || epoch !== editorEpoch || !extra().editorActive)
            throw Object.assign(Error("标注编辑器已关闭"),{code:"CANCELLED"});
    }
    async function releaseDocument(source:{id:string,leaseId:string}|null) {
        if (!source) return;
        await bridge.call("media.release",{leaseId:source.leaseId}).catch(()=>{});
        await bridge.call("media.abandonImport",{id:source.id}).catch(()=>{});
    }
    const editorVersions: {id:string,path:string,leaseId:string}[] = [];
    async function releaseEditorVersions() {
        for (const source of editorVersions.splice(0)) {
            await bridge.call("media.release",{leaseId:source.leaseId}).catch(()=>{});
            await bridge.call("media.abandonImport",{id:source.id}).catch(()=>{});
        }
    }
    async function releaseStampSources(token?:string) {
        const sources = token ? [stampLeases.get(token)].filter(Boolean) : [...stampLeases.values()];
        for (const source of sources) {
            stampLeases.delete(source!.leaseId);
            await bridge.call("media.release",{leaseId:source!.leaseId}).catch(()=>{});
            await bridge.call("media.abandonImport",{id:source!.id}).catch(()=>{});
        }
    }
    async function releaseCapture() {
        const previous = captureLease;
        captureLease = null;
        if (previous)
            await bridge.call("media.release", { leaseId: previous.leaseId });
    }
    let editorLease: { leaseId: string; path: string; id: string } | null =
        null;
    let disposed = false;
    const generatedPasswords = new Set<string>();
    let pressureWatching = false;
    let helperLocale = "",
        helperTheme = "";
    let modelsGeneration = 0;
    let prefillGeneration = 0,
        wordRouteVersion = 0;
    const peerSettingQueues = new Map<string, Promise<any>>();
    let relayPoll: ReturnType<typeof setInterval> | undefined,
        relayPolling = false,
        relayGeneration = 0;
    const extra = signal<Record<string, any>>({
        version: `${metadata.name} · ${metadata.version} (${metadata.build})`,
    });
    const patch = (fields: Record<string, any>) =>
        extra.set({ ...extra(), ...fields });
    const base = createAppModel({
        storage: stateStorage,
        host: {
            call: async <T = unknown>(
                name: string,
                payload?: unknown,
            ): Promise<T> => {
                if (name !== "system.configure")
                    return bridge.call<T>(name, payload);
                const next = payload as any,
                    old = base.state().settings;
                if (next.ocrEnabled === false && old.ocrEnabled !== false)
                    await bridge.call("history.cancelOCR");
                if (
                    JSON.stringify(next.excludedApps) !==
                    JSON.stringify(old.excludedApps)
                )
                    await bridge.call("clipboard.watch", {
                        enabled: true,
                        excludedApps: next.excludedApps,
                    });
                await desktopConfigure?.(next, old);
                for (const key of ["encryptHistory", "launchAtLogin"])
                    if (next[key] !== old[key])
                        await bridge.call(
                            key === "launchAtLogin"
                                ? "system.loginItem"
                                : "storage.configure",
                            key === "launchAtLogin"
                                ? { enabled: next[key] }
                                : { encrypted: next[key] },
                        );
                if (next.relayEnabled !== old.relayEnabled) {
                    if (next.relayEnabled) {
                        const status = await bridge.call<any>("relay.status");
                        if (!status.connected && !status.joinPending)
                            await bridge.call("relay.connect");
                    } else await bridge.call("relay.disconnect");
                }
                if (
                    next.syncEnabled !== old.syncEnabled ||
                    next.port !== old.port ||
                    next.deviceName !== old.deviceName
                ) {
                    if (next.syncEnabled)
                        await bridge.call("lan.start", {
                            port: next.port,
                            deviceName: next.deviceName,
                        });
                    else await bridge.call("lan.stop");
                }
                return true as T;
            },
        },
    });
    let lastHistoryInput: HistoryEntry[] | undefined,
        lastPreviewToken = "",
        historyView: HistoryEntry[] = [];
    const displayHistory = () => {
        const rows = base.state().history,
            token = previewLease?.leaseId || "";
        if (rows === lastHistoryInput && token === lastPreviewToken)
            return historyView;
        lastHistoryInput = rows;
        lastPreviewToken = token;
        historyView = rows.map((row) =>
            row.mediaId
                ? {
                      ...row,
                      mediaPath:
                          previewLease?.id === row.mediaId
                              ? previewLease.path
                              : undefined,
                  }
                : row,
        );
        return historyView;
    };
    const model = {
        ...base,
        state: (): AppState & Record<string, any> => ({
            ...base.state(),
            ...extra(),
            devices: (extra().devices || base.state().devices).map(
                (device: any) => ({
                    ...device,
                    ...extra().peerSettings?.[device.id],
                }),
            ),
            history: displayHistory(),
            settings: {
                ...base.state().settings,
                encryptHistory:
                    extra().storageEncrypted ??
                    base.state().settings.encryptHistory,
            },
            message: extra().message || base.state().message,
        }),
    };
    effect(() => {
        setColorScheme(base.state().settings.theme);
        setLocale(base.state().settings.language);
    });
    const report = (error: unknown) => {
        if (disposed) return;
        patch({
            message: error instanceof Error ? error.message : String(error),
        });
    };
    const native = async (name: string, payload: any = {}) => {
        if (disposed && name !== "media.release") throw Error("客户端已关闭");
        const result = await bridge.call<any>(
            name,
            payload,
            name === "capture.scroll"
                ? 600000
                : name === "video.export"
                  ? 1800000
                  : name === "lan.sendFile"
                    ? 1800000
                    : name.startsWith("capture.") || name === "lan.scan"
                      ? 120000
                      : 30000,
        );
        if (result === false) throw Error("系统未完成该操作");
        return result;
    };
    async function releasePreview() {
        previewGeneration++;
        const current = previewLease;
        previewLease = null;
        if (current)
            await native("media.release", { leaseId: current.leaseId });
    }
    async function preview(id: string) {
        const generation = ++previewGeneration;
        const row = base.state().history.find((r) => r.id === id);
        if (!row?.mediaId) {
            const previous = previewLease;
            previewLease = null;
            if (previous)
                await native("media.release", { leaseId: previous.leaseId });
            patch({ previewVersion: Date.now() });
            return;
        }
        if (previewLease?.id === row.mediaId) return;
        const previous = previewLease;
        previewLease = null;
        if (previous)
            await native("media.release", { leaseId: previous.leaseId });
        const lease = await native("media.lease", { id: row.mediaId });
        if (generation !== previewGeneration) {
            await native("media.release", { leaseId: lease.leaseId });
            return;
        }
        previewLease = { id: row.mediaId, ...lease };
        patch({ previewVersion: Date.now() });
    }
    async function storeEntry(
        input: Partial<HistoryEntry> & { content: string },
    ) {
        if (disposed) throw Error("客户端已关闭");
        const entry = { ...input, id: input.id || randomUUID() };
        if (
            (input.sourceBundleId || input.sourceApp) &&
            base
                .state()
                .settings.excludedApps.includes(
                    input.sourceBundleId || input.sourceApp!,
                )
        )
            return entry;
        const path = input.mediaPath;
        if (
            useNativeStorage &&
            path &&
            ["image", "pdf", "richText"].includes(input.type || "")
        ) {
            const media = await native("media.import", { path });
            if (disposed) throw Error("客户端已关闭");
            entry.mediaId = media.id;
            entry.mediaPath = undefined;
            if (input.type === "image" || input.content === path)
                entry.content = `media:${media.id}`;
            await base.actions.addHistory(entry);
            await base.flush();
            try {
                await native("media.consumeSource", { path, id: media.id });
            } catch {}
            if (input.type === "image" && base.state().settings.ocrEnabled)
                void native("history.ocr", { id: media.id })
                    .then((result) =>
                        disposed
                            ? undefined
                            : base.actions.updateHistory(entry.id!, {
                                  ocrText: result.text,
                              }),
                    )
                    .catch(() => {});
        } else await base.actions.addHistory(entry);
        return entry;
    }
    effect(() => {
        const { language, theme } = base.state().settings;
        if (useNativeStorage && language !== helperLocale) {
            helperLocale = language;
            void native("system.locale", { language }).catch(() => {});
        }
        if (useNativeStorage && theme !== helperTheme) {
            helperTheme = theme;
            void native("system.appearance", { theme }).catch(() => {});
        }
    });
    async function captureWithHiddenWindow(name: string, payload: any) {
        if (!useNativeStorage) return native(name, payload);
        const main = Window.get("main"), overlay = Window.get("clipy-capture-editor"),
            panel = Window.get("clipy-panel");
        const captureEpoch=editorEpoch;
        const restoreOverlay = overlay?.state()?.visible === true;
        const restoreMain = main?.state()?.visible !== false;
        if (!payload.selectionOnly) patch({ captureRestoreMain: restoreMain });
        main?.hide();overlay?.hide();
        panel?.close();
        await new Promise<void>((resolve) => setTimeout(resolve, 80));
        let result: any;
        try {
            result = await native(name, payload);
            return result;
        } finally {
            if (!disposed && restoreOverlay && (!payload.selectionOnly || captureEpoch===editorEpoch)) overlay?.focus();
            else if (!disposed && (!payload.selectionOnly || captureEpoch===editorEpoch) && restoreMain && !["annotate", "scroll", "recording"].includes(result?.action || base.state().settings.captureAction)) main?.focus();
        }
    }
    const confirm =
        options.confirm ||
        (async (title: string) =>
            (
                await AlertDialog.show({
                    title: t(title),
                    description: t("此操作会删除本地记录。"),
                    actions: [
                        { id: "cancel", label: t("取消"), role: "cancel" },
                        { id: "yes", label: t("删除"), role: "destructive" },
                    ],
                    closeOnEscape: true,
                })
            ).action === "yes");
    async function invoke(name: string, p: any = {}): Promise<any> {
        patch({ message: "" });
        base.state.set({ ...base.state(), message: "" });
        try {
            switch (name) {
                case "editor.open": {
                    const epoch=++editorEpoch;
                    await actions.flushDrafts?.();
                    if(disposed||epoch!==editorEpoch)throw Object.assign(Error("标注文档已切换"),{code:"CANCELLED"});
                    patch({editorActive:false});
                    const previous=editorLease;editorLease=null;
                    await Promise.all([releaseStampSources(),releaseEditorVersions(),releaseDocument(previous)]);
                    const valid=()=>{if(disposed||epoch!==editorEpoch)throw Object.assign(Error("标注文档已切换"),{code:"CANCELLED"});};
                    valid();
                    if(!useNativeStorage){patch({editorActive:true});return p;}
                    let media:any,lease:any,adopted=false;
                    try {
                        media=await native("media.import",{path:p.path});valid();
                        lease=await native("media.lease",{id:media.id});valid();
                        try{await native("media.consumeSource",{path:p.path,id:media.id});}catch{}
                        valid();editorLease={id:media.id,...lease};adopted=true;
                        patch({editorActive:true});return lease;
                    } finally {
                        if(!adopted){if(lease)await bridge.call("media.release",{leaseId:lease.leaseId}).catch(()=>{});if(media)await bridge.call("media.abandonImport",{id:media.id}).catch(()=>{});}
                    }
                }
                case "image.commit": {
                    const entry = await storeEntry({
                        type: "image", content: p.path, mediaPath: p.path,
                        title: "标注截图", sourceApp: "Clipy TSX",
                    });
                    await bridge.call("image.releaseOutput",{path:p.path}).catch(()=>{});
                    return { committed: true, id: entry.id };
                }
                case "editor.appendCapture": {
                    if (appendCapturing) throw Error("正在添加截图");
                    if (editorVersions.length>=4) throw Error("每份画布最多追加4次截图");
                    const epoch=editorEpoch;requireEditor(epoch);
                    appendCapturing = true;
                    let rendered:any,capture:any,composed:any,imported:any,leased:any,adopted=false;
                    try {
                        const scene=p.scene || {};
                        rendered=await native("image.render",scene);requireEditor(epoch);
                        const settings=base.state().settings;
                        capture=await captureWithHiddenWindow("capture.screen",{
                            mode:"region",selectionOnly:true,magnifier:settings.captureMagnifier,
                            snapping:settings.captureSnapping,captureCursor:settings.captureCursor,
                        });
                        requireEditor(epoch);
                        if (capture?.cancelled) return {cancelled:true};
                        composed=await native("image.compose",{paths:[rendered.path,capture.path],axis:p.axis||"vertical",gap:p.gap||0});
                        requireEditor(epoch);
                        if (!useNativeStorage) return composed;
                        imported=await native("media.import",{path:composed.path});requireEditor(epoch);
                        const lease=leased=await native("media.lease",{id:imported.id});
                        requireEditor(epoch);
                        await native("media.consumeSource",{path:composed.path,id:imported.id});
                        requireEditor(epoch);
                        if (editorLease) editorVersions.push(editorLease);
                        editorLease={...lease,id:imported.id};adopted=true;
                        return {...lease,width:composed.width,height:composed.height};
                    } finally {
                        for (const output of [rendered,composed]) if(output?.path) await bridge.call("image.releaseOutput",{path:output.path}).catch(()=>{});
                        if(capture?.path&&useNativeStorage) try {
                            const media=await bridge.call<any>("media.import",{path:capture.path});
                            await bridge.call("media.consumeSource",{path:capture.path,id:media.id});
                            await bridge.call("media.abandonImport",{id:media.id});
                        } catch {}
                        if(capture?.path)await bridge.call("files.discardCaptureSource",{path:capture.path}).catch(()=>{});
                        if(!adopted&&leased) await bridge.call("media.release",{leaseId:leased.leaseId}).catch(()=>{});
                        if(imported&&!adopted) await bridge.call("media.abandonImport",{id:imported.id}).catch(()=>{});
                        appendCapturing=false;
                    }
                }
                case "editor.importStamp": {
                    const epoch=editorEpoch;requireEditor(epoch);
                    if(stampImporting)throw Error("图片图章正在导入");
                    if(stampLeases.size>=8)throw Error("每份标注最多导入8张图片图章");
                    stampImporting=true;
                    let staged:any,imported:any,lease:any,adopted=false,consumed=false;
                    try {
                        const paths=await native("files.pick",{multiple:false});requireEditor(epoch);
                        if(!paths?.[0])return {cancelled:true};
                        staged=await native("files.stageMedia",{path:paths[0]});requireEditor(epoch);
                        const info=await native("image.info",{path:staged.path});requireEditor(epoch);
                        const used=[...stampLeases.values()].reduce((n,s)=>n+s.bytes,0);
                        if(!info.width||!info.height||!Number.isFinite(info.bytes)||info.bytes+used>32*1024*1024)throw Error("图片图章总输入不得超过32 MiB");
                        imported=await native("media.import",{path:staged.path});requireEditor(epoch);
                        lease=await native("media.lease",{id:imported.id});requireEditor(epoch);
                        await native("media.consumeSource",{path:staged.path,id:imported.id});consumed=true;requireEditor(epoch);
                        stampLeases.set(lease.leaseId,{...lease,id:imported.id,bytes:info.bytes});adopted=true;
                        return {...lease,width:info.width,height:info.height,bytes:info.bytes};
                    } finally {
                        if(staged&&!consumed)try{imported=imported||await bridge.call("media.import",{path:staged.path});await bridge.call("media.consumeSource",{path:staged.path,id:imported.id});}catch{}
                        if(staged&&!consumed)await bridge.call("files.discardStagedMedia",{path:staged.path}).catch(()=>{});
                        if(!adopted){if(lease)await bridge.call("media.release",{leaseId:lease.leaseId}).catch(()=>{});if(imported)await bridge.call("media.abandonImport",{id:imported.id}).catch(()=>{});}
                        stampImporting=false;
                    }
                }
                case "editor.releaseStamp": await releaseStampSources(p.leaseId);return true;
                case "editor.close": {
                    ++editorEpoch;
                    patch({editorActive:false,editorPath:null,editorCapture:null});
                    const previous=editorLease;editorLease=null;
                    await Promise.all([native("image.closePreviews"),releaseStampSources(),releaseEditorVersions(),releaseDocument(previous)]);
                    return;
                }
                case "shortcuts.capture":
                    return native("shortcuts.record");
                case "shortcuts.record": {
                    const result = await native("shortcuts.record");
                    if (result.cancelled) return;
                    const aliases: Record<string, string> = {
                        wordShortcut: "lookupShortcut",
                        captureShortcut: "screenshotShortcut",
                    };
                    return base.actions.saveSettings({
                        [aliases[p.key] || p.key]: result.shortcut,
                    });
                }
                case "lifecycle.hide":
                    const hideEpoch=++editorEpoch,hideLease=editorLease;editorLease=null;
                    patch({editorActive:false,editorPath:null,editorCapture:null});
                    await Promise.all([native("image.closePreviews"),releaseStampSources(),releaseEditorVersions(),releaseDocument(hideLease)]);
                    if(hideEpoch!==editorEpoch)return {cancelled:true};
                    await base.actions.cancelLookup();
                    base.state.set({
                        ...base.state(),
                        word: "",
                        wordResult: null,
                        translation: "",
                        busy: false,
                    });
                    await native("speech.stop");
                    await releasePreview();
                    await releaseCapture();
                    if(hideEpoch!==editorEpoch)return {cancelled:true};
                    patch({
                        uiVisible: false,
                        capturePath: null,
                        capture: null,
                    });
                    return;
                case "settings.excludedApps":
                    return openExcludedApps(model, actions);
                case "history.clear":
                    if (await confirm("清空未置顶的历史？"))
                        await base.actions.clearHistory();
                    return;
                case "history.period":
                    patch({ period: p });
                    return;
                case "clipboard.copy": {
                    const text = p.text ?? p.entry?.content ?? "";
                    return native("clipboard.write", {
                        text,
                        paste: p.paste,
                        plain: p.plain,
                        sensitive:
                            p.sensitive || /^common-relay:\/\//i.test(text),
                    });
                }
                case "snippets.delete":
                    if (p.id && (await confirm("删除这个片段？")))
                        return base.actions.deleteSnippet(p.id);
                    return;
                case "snippets.saveFolder":
                    return base.actions.saveFolder(p);
                case "snippets.import": {
                    const paths = await native("files.pick", {
                        multiple: false,
                    });
                    if (!paths?.[0]) return;
                    const text = await native("files.readText", {
                        path: paths[0],
                        maxBytes: 3 * 1024 * 1024,
                    });
                    return base.actions.importSnippets(
                        typeof text === "string" ? text : text.content,
                    );
                }
                case "snippets.export":
                    return native("files.writeText", {
                        content: base.actions.exportSnippets(),
                        name: "clipy-snippets.json",
                    });
                case "notifications.clear":
                    if (await confirm("清空所有通知记录？"))
                        return base.actions.clearNotifications();
                    return;
                case "notifications.delete":
                    return base.actions.deleteNotification(p.id);
                case "notifications.dismissRemote": {
                    const row = base
                        .state()
                        .notifications.find((n) => n.id === p.id);
                    if (!row?.clearable) throw Error("此通知不能在手机上清除");
                    return native("lan.notification", {
                        peerId: row.deviceId,
                        type: "notif.dismiss",
                        payload: {
                            packageName: row.packageName,
                            notificationKey: row.notificationKey,
                            groupKey: row.groupKey,
                        },
                    });
                }
                case "words.familiar":
                    return base.actions.toggleFamiliar(p.id);
                case "words.save":
                    return base.actions.lookup(p.text);
                case "models.configure": {
                    const saved = await base.actions.configureModel({
                        endpoint: p.endpoint || p.baseUrl,
                        model: p.model,
                        key: p.key,
                    });
                    if (!saved) return;
                    const status = await native("model.status");
                    patch({
                        modelConfig: status,
                        modelConfigVersion: Date.now(),
                    });
                    return { ...status, saved: true };
                }
                case "models.list": {
                    const generation = ++modelsGeneration;
                    const request = { ...p };
                    if (!request.key) {
                        let same = false;
                        try {
                            same =
                                !!request.endpoint &&
                                !!extra().modelConfig?.endpoint &&
                                modelEndpoint(request.endpoint) ===
                                    modelEndpoint(extra().modelConfig.endpoint);
                        } catch {}
                        if (same || !request.endpoint) delete request.key;
                        else request.key = "";
                    }
                    if (!request.endpoint) delete request.endpoint;
                    try {
                        const result = await native("model.models", request);
                        if (generation !== modelsGeneration || disposed) return;
                        patch({ models: result });
                        return result;
                    } catch (error) {
                        if (generation !== modelsGeneration || disposed) return;
                        throw error;
                    }
                }
                case "menubar.refresh": {
                    const rows = await native("system.hiddenIcons");
                    patch({ hiddenIcons: rows });
                    return rows;
                }
                case "menubar.open":
                    return native("system.openHiddenIcon", p);
                case "system.launchAtLogin":
                    return native("system.loginItem", p);
                case "system.keepAwake": {
                    const result = await native("awake.set", {
                        enabled: p.enabled ?? !extra().awake,
                    });
                    patch({ awake: result.enabled, keepAwake: result.enabled });
                    return result;
                }
                case "permissions.request": {
                    const result = await bridge.call("permissions.request", {
                        kind: p.permission || p.kind,
                    });
                    patch({ permissions: await native("permissions.status") });
                    return result;
                }
                case "capture.start": {
                    if (extra().editorActive) throw Error("请先完成或关闭当前标注编辑器");
                    const settings = base.state().settings;
                    let result = await captureWithHiddenWindow(
                        p.mode === "scroll"
                            ? "capture.scroll"
                            : "capture.screen",
                        {
                            mode: p.mode === "screen" ? "fullscreen" : p.mode,
                            magnifier: settings.captureMagnifier,
                            snapping: settings.captureSnapping,
                            captureCursor: settings.captureCursor,
                            maxHeight: settings.scrollMaxHeight,
                            freezeHeader: settings.scrollFreezeHeader,
                            autoScroll: settings.scrollAutomatic,
                            scrollSpeed: settings.scrollSpeed,
                        },
                    );
                    if (result.cancelled) return;
                    const restoreCaptureMain = extra().captureRestoreMain;
                    if (result.action === "recording") {
                        const rect = result.selectionRect, display = result.displayFrame;
                        const recording = await invoke("recording.start", { ...settings,
                            displayId:result.displayId, rect:{x:rect.x-display.x,y:rect.y-display.y,width:rect.width,height:rect.height} });
                        if (recording && !recording.cancelled) await base.actions.navigate("recording");
                        patch({captureRestoreMain:restoreCaptureMain});
                        if (restoreCaptureMain) Window.get("main")?.focus();
                        return recording;
                    }
                    if (result.action === "scroll") {
                        try { result = await captureWithHiddenWindow("capture.scroll", {
                            rect: result.selectionRect, maxHeight:settings.scrollMaxHeight,
                            freezeHeader:settings.scrollFreezeHeader,autoScroll:settings.scrollAutomatic,
                            scrollSpeed:settings.scrollSpeed,
                        }); } finally {
                            patch({captureRestoreMain:restoreCaptureMain});
                            if (restoreCaptureMain) Window.get("main")?.focus();
                        }
                        if (!result || result.cancelled) return result;
                    }
                    // An explicit overlay action takes precedence over the quick-capture preference.
                    const captureAction = result.action || settings.captureAction;
                    if (captureAction === "editor" || captureAction === "annotate") {
                        // Editing is a draft. Never persist/OCR the unredacted source
                        // as a history item; final output is committed by the editor.
                        const lease = await invoke("editor.open", { path: result.path });
                        if(lease?.cancelled)return lease;
                        if (!lease?.path) throw Error("无法打开截图编辑器");
                        const rect = result.selectionRect, display = result.displayFrame;
                        const overlay = captureAction === "annotate" && rect && display &&
                            rect.x >= display.x && rect.y >= display.y &&
                            rect.x+rect.width <= display.x+display.width &&
                            rect.y+rect.height <= display.y+display.height;
                        // A complete window spanning displays must remain fully editable.
                        patch({ editorPath: lease.path, editorCapture: overlay ? result : null, uiVisible:true });
                        if (!overlay) Window.get("main")?.focus();
                        return { ...result, path: lease.path };
                    }
                    const rawPath = result.path;
                    const generated = [rawPath];
                    if (
                        settings.downscaleRetina &&
                        Number(result.backingScaleFactor || 1) > 1
                    ) {
                        const resized = await native("image.resize", {
                            path: result.path,
                            scale: 1 / Number(result.backingScaleFactor),
                        });
                        Object.assign(result, resized);
                        result.backingScaleFactor = 1;
                        generated.push(result.path);
                    }
                    if (
                        settings.beautify ||
                        settings.brightness !== 0 ||
                        settings.contrast !== 1 ||
                        settings.saturation !== 1 ||
                        settings.sharpness !== 0
                    ) {
                        const processed = await native("image.render", {
                            imagePath: result.path,
                            annotations: [],
                            effects: {
                                beautify: settings.beautify,
                                padding: settings.beautifyPadding,
                                radius: settings.beautifyRadius,
                                shadow: settings.beautifyShadow,
                                brightness: settings.brightness,
                                contrast: settings.contrast,
                                saturation: settings.saturation,
                                sharpness: settings.sharpness,
                            },
                        });
                        Object.assign(result, processed);
                    }
                    const processedPath = result.path;
                    const entry = await storeEntry({
                        type: "image",
                        content: result.path,
                        mediaPath: result.path,
                        title: "截图",
                        sourceApp: "Clipy TSX",
                    });
                    if (entry.mediaId) {
                        await releaseCapture();
                        const lease = await native("media.lease", {
                            id: entry.mediaId,
                        });
                        captureLease = { id: entry.mediaId, ...lease };
                        result.path = lease.path;
                    }
                    patch({
                        capture: result,
                        capturePath: result.path,
                        captureMediaId: entry.mediaId,
                    });
                    if (useNativeStorage) {
                        for (const temporary of [...new Set(generated)].filter(
                            (path) => path !== processedPath,
                        )) {
                            try {
                                const original = await native("media.import", {
                                    path: temporary,
                                });
                                await native("media.consumeSource", {
                                    path: temporary,
                                    id: original.id,
                                });
                                await native("media.abandonImport", {
                                    id: original.id,
                                });
                            } catch {}
                        }
                        void native("media.collect", {
                            ids: base
                                .state()
                                .history.map((h) => h.mediaId)
                                .filter(Boolean),
                        }).catch(() => {});
                    }
                    if (
                        captureAction === "copy" ||
                        captureAction === "saveAndCopy"
                    )
                        await native("clipboard.write", {
                            type: "image",
                            path: result.path,
                            sensitive: true,
                        });
                    if (
                        settings.autoSave ||
                        ["save", "saveAndCopy"].includes(captureAction)
                    )
                        await native("capture.export", {
                            path: result.path,
                            directory: settings.captureDirectory,
                            format: settings.saveFormat,
                            quality: settings.saveQuality,
                            scale: settings.downscaleRetina
                                ? 1 / Number(result.backingScaleFactor || 1)
                                : 1,
                            sound: settings.captureSound,
                        });
                    if (settings.thumbnailEnabled)
                        void native("image.thumbnail", {
                            path: result.path,
                            stack: settings.stackThumbnails,
                            position: settings.thumbnailPosition,
                            scale: settings.thumbnailScale,
                        }).catch(() => {});
                    if (captureAction === "pin")
                        await native("image.pin", { path: result.path });
                    if (
                        settings.captureSound &&
                        !settings.autoSave &&
                        !["save", "saveAndCopy"].includes(
                            captureAction,
                        )
                    )
                        void native("capture.sound").catch(() => {});
                    if (captureAction === "ocr") {
                        await invoke("capture.ocr", { path: result.path });
                    } else if (captureAction === "share") {
                        await native("image.share", { path: result.path });
                    } else if (captureAction === "translate") {
                        await invoke("capture.translate", { path: result.path });
                    }
                    return result;
                }
                case "capture.openImage": {
                    const paths = await native("files.pick", {
                        multiple: false,
                    });
                    if (paths?.[0]) {
                        const result = await native("files.stageMedia", {
                            path: paths[0],
                        });
                        patch({ capture: result, capturePath: result.path });
                        return result;
                    }
                    return;
                }
                case "capture.ocr": {
                    const result = await native("ocr.recognize", p);
                    patch({ ocr: result });
                    await native("image.ocrResult", result);
                    return result;
                }
                case "capture.pin":
                    return native("image.pin", p);
                case "capture.thumbnail":
                    return native("image.thumbnail", p);
                case "capture.translate": {
                    const result = await native("ocr.recognize", p);
                    await native("image.ocrResult", { ...result, target: p.target || "简体中文", translate: true, backend:p.backend || base.state().settings.captureTranslationBackend });
                    return result;
                }
                case "capture.share":
                    return native("image.share", p);
                case "capture.edit":
                    patch({ editorPath: p.path });
                    return;
                case "capture.copy":
                    return native("clipboard.write", {
                        type: "image",
                        mediaPath: p.path,
                        path: p.path,
                    });
                case "capture.save":
                    return native("files.saveCopy", p);
                case "capture.chooseDirectory": {
                    const paths = await native("files.pick", {
                        directories: true,
                        multiple: false,
                    });
                    if (paths?.[0])
                        return base.actions.saveSettings({
                            captureDirectory: paths[0],
                        });
                    return;
                }
                case "relay.configure":
                    return updateRelay(
                        await native("relay.configure", {
                            ...p,
                            url: p.url || p.endpoint,
                        }),
                    );
                case "relay.create":
                case "relay.join":
                case "relay.leave":
                case "relay.disband":
                case "relay.rename":
                case "relay.remove":
                case "relay.approve": {
                    if (
                        (name === "relay.leave" ||
                            name === "relay.disband" ||
                            name === "relay.remove") &&
                        !(await confirm(
                            name === "relay.disband"
                                ? "解散设备组？"
                                : "确认设备组操作？",
                        ))
                    )
                        return;
                    const result = await native(name, {
                        ...p,
                        name: p.name || p.groupName,
                        device: p.device || p.deviceId || p.id,
                        request: p.request?.request || p.request,
                    });
                    if (
                        name === "relay.approve" ||
                        name === "relay.leave" ||
                        name === "relay.disband"
                    )
                        patch({ invitation: null, inviteLink: "" });
                    await refreshRelay();
                    if (name === "relay.create" || name === "relay.join")
                        await base.actions.saveSettings({ relayEnabled: true });
                    if (name === "relay.leave" || name === "relay.disband")
                        await base.actions.saveSettings({
                            relayEnabled: false,
                        });
                    return result;
                }
                case "relay.refresh":
                    return refreshRelay();
                case "relay.cancelJoin": {
                    const result = await native(name);
                    updateRelay(result.status || result);
                    return result;
                }
                case "relay.pending": {
                    const result = await native(name);
                    patch({
                        relay: {
                            ...(extra().relay || {}),
                            pending: result?.request ? [result] : [],
                        },
                    });
                    return result;
                }
                case "relay.finish": {
                    const result = await native(name);
                    updateRelay(result.status || result);
                    return result;
                }
                case "relay.cancel": {
                    const result = await native(name);
                    patch({
                        invitation: null,
                        inviteLink: "",
                        relay: { ...(extra().relay || {}), pending: [] },
                    });
                    return result;
                }
                case "relay.invite": {
                    const result = await native(name, {
                        ...p,
                        mode: p.auto === false ? "manual" : "auto",
                    });
                    patch({
                        invitation: result,
                        inviteLink: result.short_link || result.link || "",
                    });
                    return result;
                }
                case "relay.readQR": {
                    const paths = await native("files.pick", {
                        multiple: false,
                    });
                    if (!paths?.[0]) return;
                    const result = await native("ocr.recognize", {
                        path: paths[0],
                    });
                    patch({ invitationLink: result.codes?.[0] || "" });
                    return result;
                }
                case "sync.refresh": {
                    await native("lan.scan", {
                        port: base.state().settings.port,
                    });
                    const result = await native("lan.status");
                    patch({
                        devices: result?.peers || [],
                        diagnostics: result,
                    });
                    return result;
                }
                case "sync.addPeer":
                    return native("lan.connect", {
                        host: p.host || p.ip || p.address,
                        port: Number(p.port) || 5566,
                    });
                case "sync.sendPaths": {
                    if (!Array.isArray(p.paths) || p.paths.length > 32)
                        throw Error("一次最多选择32个文件");
                    const paths = p.paths.map((path: string) =>
                        path.startsWith("file:")
                            ? decodeURIComponent(new URL(path).pathname)
                            : path,
                    );
                    await native("files.authorizeSelection", { paths });
                    for (const path of paths)
                        await native("lan.sendFile", {
                            peerId: p.peerId,
                            path,
                        });
                    patch({ message: "文件已确认接收" });
                    return;
                }
                case "files.revealReceived":
                    return native("files.revealReceived");
                case "sync.sendFiles": {
                    const paths = await native("files.pick", {
                        multiple: true,
                        directories: true,
                    });
                    if (!paths?.length) return;
                    for (const path of paths)
                        await native("lan.sendFile", {
                            peerId: p.peerId || p.id,
                            path,
                        });
                    patch({ message: "文件已确认接收" });
                    return;
                }
                case "sync.peerSettings": {
                    const old = {
                        ...model
                            .state()
                            .devices.find((device: any) => device.id === p.id),
                        ...(extra().peerSettings?.[p.id] || {}),
                    };
                    const next = { ...old, ...p };
                    patch({
                        peerSettings: {
                            ...(extra().peerSettings || {}),
                            [p.id]: next,
                        },
                    });
                    const previous =
                        peerSettingQueues.get(p.id) || Promise.resolve();
                    const work = previous
                        .catch(() => {})
                        .then(() =>
                            native("lan.authorize", {
                                peerId: p.id,
                                clipboard: !!next.syncClipboard,
                                notifications: !!next.syncNotifications,
                            }),
                        );
                    peerSettingQueues.set(p.id, work);
                    try {
                        await work;
                    } catch (error) {
                        if (peerSettingQueues.get(p.id) === work)
                            patch({
                                peerSettings: {
                                    ...(extra().peerSettings || {}),
                                    [p.id]: old,
                                },
                            });
                        throw error;
                    } finally {
                        if (peerSettingQueues.get(p.id) === work)
                            peerSettingQueues.delete(p.id);
                    }
                    return;
                }
                case "sync.sendText":
                    return native("lan.sendText", {
                        ...p,
                        peerId: p.peerId || p.deviceId || p.id,
                    });
                case "sync.configure":
                    return base.actions.saveSettings(p);
                case "sync.diagnostics": {
                    const result = await native("lan.status");
                    patch({ diagnostics: result });
                    return result;
                }
                case "recording.start": {
                    const result = await captureWithHiddenWindow(name, p);
                    if (result.cancelled) return result;
                    patch({ recording: { ...result, active: true } });
                    return result;
                }
                case "recording.stop": {
                    const result = await native(name);
                    patch({
                        recording: { ...result, active: false },
                        videoPath: result.path,
                    });
                    return result;
                }
                case "video.open": {
                    const paths = await native("files.pick", {
                        multiple: false,
                    });
                    if (paths?.[0]) {
                        const result = await native("files.stageMedia", {
                            path: paths[0],
                        });
                        patch({
                            videoPath: result.path,
                            videoInfo: await native("video.info", result),
                        });
                    }
                    return;
                }
                case "video.addEffect": {
                    const effect = { ...p, id: String(Date.now()) };
                    patch({
                        videoEffects: [...(extra().videoEffects || []), effect],
                    });
                    return effect;
                }
                case "video.export": {
                    patch({ videoExportBusy: true, videoProgress: 0 });
                    try {
                        const result = await native(name, {
                            ...p,
                            speed: p.speed || p.rate || 1,
                            effects: p.effects || extra().videoEffects || [],
                            path: p.path || extra().videoPath,
                        });
                        patch({ videoExport: result, videoProgress: 1 });
                        if (result?.path && p.save !== false) {
                            const saved = await native("files.saveCopy", {
                                path: result.path,
                            });
                            if (!saved.cancelled)
                                patch({
                                    videoExport: {
                                        ...result,
                                        savedPath: saved.path,
                                    },
                                });
                        }
                        return result;
                    } finally {
                        patch({ videoExportBusy: false });
                    }
                }
                default:
                    return await native(name, p);
            }
        } catch (error) {
            if (name === "capture.start" && extra().captureRestoreMain && !extra().editorCapture)
                Window.get("main")?.focus();
            const code = String((error as any)?.code || "");
            if (code === "CANCELLED" && ["editor.open","editor.importStamp","editor.appendCapture"].includes(name)) return {cancelled:true};
            if (code === "CANCELLED" && !extra().editorActive &&
                ["image.render", "image.redact", "image.smartHighlight"].includes(name)) return undefined;
            if (
                code.includes("401") ||
                code === "AUTH_REJECTED" ||
                code === "UNAUTHORIZED" ||
                /\b401\b|authentication|unauthorized/i.test(
                    String((error as any)?.message || ""),
                )
            )
                patch({
                    relay: {
                        url: extra().relay?.url,
                        configured: extra().relay?.configured,
                        connected: false,
                        members: [],
                        peers: [],
                        pending: null,
                        authRejected: true,
                    },
                    invitation: null,
                    inviteLink: "",
                    invitationLink: "",
                });
            report(error);
            return undefined;
        }
    }
    function updateRelay(value: any) {
        if (
            value?.url &&
            value.url !== base.state().settings.relayEndpoint &&
            !disposed
        )
            void base.actions.saveSettings({ relayEndpoint: value.url });
        patch({
            relay: value,
            ...(value?.authRejected
                ? { invitation: null, inviteLink: "", invitationLink: "" }
                : {}),
            ...(value?.identityError ? { message: value.identityError } : {}),
        });
        return value;
    }
    async function refreshRelay() {
        const result = await native("relay.refresh");
        patch({ relay: result });
        return result;
    }
    effect(() => {
        const wanted =
            useNativeStorage &&
            !!extra().editorActive &&
            !!base.state().settings.stylusPressure;
        if (wanted === pressureWatching) return;
        pressureWatching = wanted;
        if (wanted)
            void native("editor.watchPressure", {
                enabled: true,
                visible: true,
            }).catch(report);
        else if (useNativeStorage)
            void native("editor.stopPressure").catch(() => {});
    });
    effect(() => {
        const status = extra().relay || {},
            invitation = extra().invitation;
        const visible =
            base.state().page === "relay" &&
            extra().uiVisible !== false &&
            (!useNativeStorage ||
                Window.get("main")?.state()?.visible !== false);
        const waiting = !!status.joinPending || invitation?.mode === "manual";
        if (visible && waiting && !relayPoll) {
            const generation = ++relayGeneration;
            relayPoll = setInterval(() => {
                if (relayPolling || disposed) return;
                if (
                    extra().invitation?.expires &&
                    Date.now() / 1000 >= Number(extra().invitation.expires)
                ) {
                    patch({
                        invitation: null,
                        inviteLink: "",
                        message: t("邀请已过期，请重新生成"),
                    });
                    return;
                }
                relayPolling = true;
                void (async () => {
                    try {
                        if (extra().relay?.joinPending) {
                            const result = await native("relay.finish");
                            if (generation === relayGeneration && !disposed)
                                updateRelay(result.status || result);
                        } else {
                            const result = await native("relay.pending");
                            if (generation === relayGeneration && !disposed)
                                patch({
                                    relay: {
                                        ...(extra().relay || {}),
                                        pending: result?.request
                                            ? [result]
                                            : [],
                                    },
                                });
                        }
                    } catch (error) {
                        if (generation === relayGeneration) report(error);
                    } finally {
                        relayPolling = false;
                    }
                })();
            }, 2000);
        } else if ((!visible || !waiting) && relayPoll) {
            clearInterval(relayPoll);
            relayPoll = undefined;
            relayGeneration++;
        }
    });
    const decorated = Object.fromEntries(
        Object.entries(base.actions).map(([key, fn]) => [
            key,
            (...args: any[]) => {
                patch({ message: "" });
                base.state.set({ ...base.state(), message: "" });
                return (fn as any)(...args);
            },
        ]),
    );
    const actions: Record<string, any> = {
        ...decorated,
        generatePassword: async (config: any) => {
            const value = await base.actions.generatePassword(config);
            if (typeof value === "string") {
                generatedPasswords.add(value);
                while (generatedPasswords.size > 32)
                    generatedPasswords.delete(
                        generatedPasswords.values().next().value!,
                    );
            }
            return value;
        },
        selectHistory: (id: string) => {
            base.actions.selectHistory(id);
            void preview(id).catch(report);
        },
        pasteFileNames: async (id: string) => {
            const row = base.state().history.find((r) => r.id === id);
            if (!row) return;
            try {
                const paths = row.files || [row.mediaPath || row.content];
                const text = paths
                    .map((path) => path.split(/[\\/]/).pop() || path)
                    .join("\n");
                await native("clipboard.write", { text, paste: true });
            } catch (error) {
                report(error);
            }
        },
        copyHistory: async (id: string, paste = false, plain = false) => {
            patch({ message: "" });
            const row = base.state().history.find((r) => r.id === id);
            if (!row) return;
            try {
                let lease: any;
                if (row.mediaId)
                    lease = await native("media.lease", { id: row.mediaId });
                try {
                    if (row.type === "file")
                        await native("files.authorizeSelection", {
                            paths: row.files || [row.mediaPath || row.content],
                        });
                    await native("clipboard.write", {
                        ...row,
                        mediaPath: lease?.path || row.mediaPath,
                        text: row.content,
                        paste,
                        plain,
                        files: plain ? undefined : row.files,
                    });
                    patch({ message: paste ? "已请求粘贴" : "已复制" });
                } finally {
                    if (lease)
                        await native("media.release", {
                            leaseId: lease.leaseId,
                        });
                }
            } catch (error) {
                report(error);
            }
        },
        saveSettings: (input: any) => {
            patch({ message: "" });
            const aliases: Record<string, string> = {
                retentionDays: "historyRetentionDays",
                ocrHistory: "ocrEnabled",
                notificationSync: "notificationsEnabled",
                notificationKeywords: "keywords",
                notificationBlocked: "blockedKeywords",
                captureAutoSave: "autoSave",
                recordFps: "fps",
                wordShortcut: "lookupShortcut",
                captureShortcut: "screenshotShortcut",
            };
            const canonical = Object.fromEntries(
                Object.entries(input).map(([k, v]) => [aliases[k] || k, v]),
            );
            return base.actions.saveSettings(canonical);
        },
        invoke,
        invokeWithSignal: (method:string,params:any,signal:AbortSignal) => bridge.call(method === "model.translate" ? "capture.translateLine" : method,params,30000,signal),
        navigate: async (requestedPage: any) => {
            try {
                await actions.flushDrafts?.();
            } catch (error) {
                report(error);
                return false;
            }
            if (disposed) return false;
            const page = requestedPage === "wordbook" ? "words" : requestedPage;
            const prefill = ++prefillGeneration;
            patch({ message: "", editorPath: null, uiVisible: true });
            if (base.state().page === "words" && page !== "words") {
                void base.actions.cancelLookup();
                void native("speech.stop").catch(() => {});
            }
            base.actions.navigate(page);
            if (page === "words" && requestedPage !== "wordbook") {
                base.state.set({
                    ...base.state(),
                    word: "",
                    wordResult: null,
                    translation: "",
                    busy: false,
                });
                const version = ++wordRouteVersion;
                patch({
                    wordPrefill: "",
                    wordPrefillVersion: version,
                    wordQueryRequestVersion: version,
                });
            }
            if (
                page === "words" &&
                requestedPage !== "wordbook" &&
                useNativeStorage
            ) {
                void base.actions.cancelLookup();
                void native("speech.stop").catch(() => {});
                void native("clipboard.readText")
                    .then((result) => {
                        if (
                            disposed ||
                            prefill !== prefillGeneration ||
                            base.state().page !== "words"
                        )
                            return;
                        const text = String(
                            typeof result === "string"
                                ? result
                                : result?.text || "",
                        ).trim();
                        if (
                            text.length <= 500 &&
                            text !== base.state().password &&
                            /^[A-Za-z]+(?:['-][A-Za-z]+)*$/.test(text)
                        ) {
                            base.state.set({
                                ...base.state(),
                                word: text,
                                wordResult: null,
                                translation: "",
                                busy: false,
                            });
                            patch({
                                wordPrefill: text,
                                wordPrefillVersion: ++wordRouteVersion,
                            });
                        }
                    })
                    .catch(() => {});
            }
            if (page !== "history") void releasePreview().catch(() => {});
            if (page !== "capture") {
                void releaseCapture().catch(() => {});
                if (extra().captureMediaId)
                    patch({ capturePath: null, capture: null });
            } else if (extra().captureMediaId && !captureLease) {
                void native("media.lease", { id: extra().captureMediaId })
                    .then(async (lease) => {
                        if (disposed || base.state().page !== "capture") {
                            await bridge.call("media.release", {
                                leaseId: lease.leaseId,
                            });
                            return;
                        }
                        captureLease = { id: extra().captureMediaId, ...lease };
                        patch({
                            capturePath: lease.path,
                            capture: { path: lease.path },
                        });
                    })
                    .catch(report);
            }
            if (requestedPage === "wordbook")
                patch({ wordBookRequestVersion: ++wordRouteVersion });
            if (page === "relay") void invoke("relay.refresh");
            return true;
        },
        set: (key: string, value: any) => {
            if (
                [
                    "query",
                    "word",
                    "selection",
                    "selectedFolder",
                    "page",
                ].includes(key)
            )
                base.actions.set(key, value);
            else patch({ [key]: value });
        },
    };
    const off = [
        Notifications.on("press", async (press) => {
            await base.ready;
            if (disposed) return;
            if (press.id.startsWith("clipy-file:")) {
                const id = press.id.slice("clipy-file:".length);
                const row = base
                    .state()
                    .history.find(
                        (entry) => entry.id === id && entry.type === "file",
                    );
                try {
                    if (!row?.mediaPath) throw Error("文件记录已清理");
                    await native("files.reveal", { path: row.mediaPath });
                } catch {
                    await invoke("files.revealReceived");
                }
            } else if (press.id.startsWith("clipy-notif:")) {
                actions.navigate("notifications");
                Window.get("main")?.focus();
            }
        }),
        bridge.on("clipboard.changed", async (p) => {
            const content = p.text || p.files?.join("\n") || p.path;
            if (!content) return;
            if (
                /^common-relay:\/\//i.test(content) ||
                content === base.state().password ||
                generatedPasswords.has(content)
            ) {
                void native("clipboard.concealChange", {
                    changeCount: p.changeCount,
                }).catch(() => {});
                return;
            }
            try {
                await base.ready;
                await storeEntry({
                    type: p.type === "files" ? "file" : p.type || "text",
                    content,
                    mediaPath: p.mediaPath || p.path || p.files?.[0],
                    files: p.files,
                    sourceApp: p.source || p.bundleId || "本机",
                    sourceBundleId: p.bundleId,
                    sourceIconPath: p.sourceIconPath,
                    title:
                        p.type === "image"
                            ? t("图片")
                            : p.type === "pdf"
                              ? t("PDF 文档")
                              : String(content).slice(0, 80),
                });
                if (
                    p.type === "text" &&
                    (base.state().settings.syncEnabled ||
                        base.state().settings.relayEnabled) &&
                    !base
                        .state()
                        .settings.excludedApps.includes(p.bundleId || p.source)
                )
                    await native("lan.broadcast", { text: content });
            } catch (error) {
                report(error);
            }
        }),
        bridge.on(
            "notification.received",
            (p) =>
                void base.actions
                    .ingest({ type: "notification.received", data: p })
                    .catch(report),
        ),
        bridge.on(
            "devices.changed",
            (p) =>
                void base.actions.ingest({ type: "devices.changed", data: p }),
        ),
        bridge.on("lan.peers", (p) => patch({ devices: p.peers || [] })),
        bridge.on("lan.status", (p) => patch({ diagnostics: p })),
        bridge.on("lan.history.fetch", async (p) => {
            try {
                await base.ready;
                await native("lan.replayHistory", {
                    peerId: p.peerId,
                    texts: base
                        .state()
                        .history.filter((h) => h.type === "text")
                        .slice(0, 200)
                        .map((h) => h.content),
                });
            } catch (error) {
                report(error);
            }
        }),
        bridge.on("lan.notification.received", async (p) => {
            try {
                await base.ready;
                if (disposed) return;
                const row = p.notification || {},
                    key = String(
                        row.notificationKey || row.key || row.id || p.messageId,
                    );
                if (p.operation === "notif.post") {
                    if (!base.state().settings.notificationsEnabled) {
                        await base.flush();
                        if (!disposed)
                            await native("lan.ack", { messageId: p.messageId });
                        return;
                    }
                    const item = {
                        id: `${p.peerId}:${key}`,
                        title: row.title || "",
                        content: row.text || row.body || row.content || "",
                        app: row.appName || row.packageName || "手机通知",
                        date: (() => {
                            const raw = Number(row.postTime || row.date);
                            return raw
                                ? raw < 1e11
                                    ? raw * 1000
                                    : raw
                                : Date.now();
                        })(),
                        deviceId: p.peerId,
                        clearable: row.isClearable !== false,
                        packageName: row.packageName,
                        notificationKey: key,
                        groupKey: row.groupKey,
                    };
                    await base.actions.addNotification(item);
                    await base.flush();
                    if (disposed) return;
                    await native("lan.ack", { messageId: p.messageId });
                    const settings = base.state().settings;
                    if (
                        settings.notificationBanner &&
                        notificationMatches(
                            item,
                            settings.keywords,
                            settings.blockedKeywords,
                        )
                    )
                        void Notifications.show({
                            id: `clipy-notif:${item.id}`,
                            title: item.title || item.app,
                            body: item.content,
                            silent: !settings.notificationSound,
                        }).catch(() => {});
                } else {
                    if (
                        p.operation === "notif.clear" ||
                        p.operation === "notif.clearAll"
                    )
                        await base.actions.clearNotifications(p.peerId);
                    else {
                        const matches = base
                            .state()
                            .notifications.filter(
                                (n) =>
                                    n.deviceId === p.peerId &&
                                    ((row.notificationKey &&
                                        n.notificationKey ===
                                            row.notificationKey) ||
                                        (row.groupKey &&
                                            n.groupKey === row.groupKey &&
                                            n.packageName === row.packageName)),
                            );
                        await base.actions.removeNotifications(
                            matches.map((n) => n.id),
                        );
                    }
                    await base.flush();
                    if (disposed) return;
                    await native("lan.ack", { messageId: p.messageId });
                }
            } catch (error) {
                report(error);
            }
        }),
        bridge.on("lan.file.received", async (p) => {
            try {
                await base.ready;
                if (disposed) return;
                await base.actions.addHistory({
                    id: p.messageId,
                    type: "file",
                    content: p.path,
                    mediaPath: p.path,
                    title: p.name,
                    sourceApp: p.sourceApp || p.peerId,
                });
                await base.flush();
                if (disposed) return;
                await native("lan.ack", { messageId: p.messageId });
                patch({ message: `已接收文件：${p.name}` });
                void Notifications.show({
                    id: `clipy-file:${p.messageId}`,
                    title: t("已接收文件"),
                    body: `${p.name} · ${p.sourceApp || p.peerId}`,
                }).catch(() => {});
            } catch (error) {
                report(error);
            }
        }),
        bridge.on("lan.history.received", async (p) => {
            try {
                await base.ready;
                if (disposed) return;
                await base.actions.addHistory({
                    ...p,
                    id: p.messageId,
                    title: p.content.slice(0, 80),
                });
                await base.flush();
                if (disposed) return;
                await native("lan.ack", { messageId: p.messageId });
                await native("clipboard.write", {
                    text: p.content,
                    sensitive: true,
                });
            } catch (error) {
                report(error);
            }
        }),
        bridge.on("relay.status.changed", (p) => updateRelay(p)),
        bridge.on("relay.disconnected", () =>
            patch({ message: "公网中继连接已断开" }),
        ),
        bridge.on("image.actionError", (p) => patch({message:p.message})),
        bridge.on("image.action", async (p) => {
            try {
                if (!["edit","ocr","share","pin"].includes(p.action) || !p.path || disposed) return;
                if (p.action === "edit") {
                    if (extra().editorActive) throw Error("请先完成或关闭当前标注编辑器");
                    const lease = await invoke("editor.open", {path:p.path});
                    if (!lease?.path) return;
                    patch({editorPath:lease.path,editorCapture:null,uiVisible:true});
                    Window.get("main")?.focus();
                } else await invoke(`capture.${p.action}`, {path:p.path});
            } catch (error) { report(error); }
            finally {
                if (useNativeStorage) try {
                    const media = await native("media.import",{path:p.path});
                    await native("media.consumeSource",{path:p.path,id:media.id});
                    await native("media.abandonImport",{id:media.id});
                } catch {}
            }
        }),
        bridge.on("editor.pressure", (p) =>
            patch({ editorPressure: { ...p, receivedAt: Date.now() } }),
        ),
        bridge.on("video.progress", (p) =>
            patch({ videoProgress: p.progress }),
        ),
        bridge.on("recording.progress", (p) =>
            patch({
                recording: { ...(extra().recording || {}), ...p, active: true },
            }),
        ),
        bridge.on("recording.finished", (p) => {
            if (disposed) return;
            patch({ recording: { ...p, active: false }, videoPath: p.path });
            if (p.path)
                void Promise.resolve(
                    base.actions.addHistory({
                        type: "file",
                        content: p.path,
                        mediaPath: p.path,
                        title: "录屏",
                        sourceApp: "Clipy TSX",
                    }),
                ).catch(report);
        }),
        bridge.on("lan.scan", (p) => patch({ scan: p })),
        bridge.on("lan.error", (p) => report(p.message || "局域网连接错误")),
        bridge.on("native.startupError", (p) =>
            patch({
                hostAvailable: false,
                message: p.message || "系统服务启动失败",
            }),
        ),
        bridge.on("native.disconnected", () =>
            patch({
                hostAvailable: false,
                ...(!extra().message ? { message: "系统服务已退出" } : {}),
            }),
        ),
    ];
    const start = async () => {
        await base.ready;
        if (disposed) return;
        try {
            patch({
                systemInfo: await native("system.info"),
                hostAvailable: true,
            });
            patch({ menubarStatus: await native("menubar.install") });
        } catch (error) {
            report(error);
            return;
        }
        if (useNativeStorage) {
            try {
                const status = await native("storage.status");
                patch({ storageEncrypted: status.encrypted });
                if (base.isStorageHealthy()) {
                    if (
                        base.state().settings.encryptHistory !==
                        status.encrypted
                    )
                        await base.actions.saveSettings({
                            encryptHistory: status.encrypted,
                        });
                    await native("media.collect", {
                        ids: base
                            .state()
                            .history.map((h) => h.mediaId)
                            .filter(Boolean),
                    });
                }
            } catch (error) {
                report(error);
            }
        }
        try {
            await native("clipboard.watch", {
                enabled: true,
                excludedApps: base.state().settings.excludedApps,
            });
        } catch (error) {
            report(error);
        }
        try {
            patch({ permissions: await native("permissions.status") });
        } catch (error) {
            report(error);
        }
        if (useNativeStorage)
            void native("model.status")
                .then((status) => {
                    if (!disposed)
                        patch({
                            modelConfig: status,
                            modelConfigVersion: Date.now(),
                        });
                })
                .catch(() => {});
        if (!base.state().settings.onboardingComplete)
            base.actions.navigate("onboarding");
        if (base.state().settings.syncEnabled) {
            try {
                await native("lan.start", {
                    port: base.state().settings.port,
                    deviceName: base.state().settings.deviceName,
                });
            } catch (error) {
                report(error);
            }
        }
        if (useNativeStorage)
            void (async () => {
                try {
                    const relay = await native("relay.status");
                    if (disposed) return;
                    updateRelay(relay);
                    if (
                        base.state().settings.relayEnabled &&
                        (relay.membership || relay.joinPending)
                    )
                        updateRelay(await native("relay.connect"));
                } catch (error) {
                    report(error);
                }
            })();
    };
    return {
        model,
        actions,
        bridge,
        patch,
        start,
        setDesktopConfigure(fn: (next: any, old: any) => Promise<void>) {
            desktopConfigure = fn;
        },
        async dispose() {
            if (disposed) return;
            disposed = true;++editorEpoch;
            if (relayPoll) clearInterval(relayPoll);
            relayPoll = undefined;
            relayGeneration++;
            off.forEach((f) => f());
            try {
                await releasePreview();
                await releaseCapture();
                await releaseStampSources();
                await releaseEditorVersions();
                const previous=editorLease;editorLease=null;
                await releaseDocument(previous);
                await base.flush();
            } finally {
                generatedPasswords.clear();
                base.dispose();
                bridge.close();
            }
        },
    };
}
