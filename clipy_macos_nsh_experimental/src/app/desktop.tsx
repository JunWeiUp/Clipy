import { cleanup, effect, signal, type Bounds } from "nsh";
import {
    Application,
    currentWindow,
    GlobalShortcut,
    Menu,
    Tray,
    Window,
    displays,
    type WindowRef,
} from "nsh/desktop";
import { normalizeShortcut } from "../core/shortcuts";
import { t as tr } from "../ui/locale";
import trayIcon from "../../assets/tray.svg";
import { RootScreen } from "../screens/RootScreen";
import { ImageEditor } from "../editor/ImageEditor";

export function installDesktop(model: any, actions: any, nativeTray = false) {
    let popup: WindowRef | null = null;
    let menuRefresh: ReturnType<typeof setInterval> | undefined;
    const navigate = async (page: string) => {
        popup?.close();
        popup = null;
        actions.set("uiVisible", true);
        const ok = await actions.navigate(page);
        if (ok !== false) currentWindow().focus();
        return ok;
    };
    function panel(bounds?: Bounds | null) {
        if (popup?.state()?.visible) {
            popup.close();
            popup = null;
            if (menuRefresh) clearInterval(menuRefresh);
            return;
        }
        const display =
            displays().find(
                (d) =>
                    bounds &&
                    bounds.origin.x >= d.bounds.origin.x &&
                    bounds.origin.x < d.bounds.origin.x + d.bounds.size.width,
            ) || displays()[0];
        const x = Math.min(
            (bounds?.origin.x || display?.visibleBounds.origin.x || 0) - 330,
            (display?.visibleBounds.origin.x || 0) +
                (display?.visibleBounds.size.width || 1200) -
                440,
        );
        const y = bounds ? bounds.origin.y + bounds.size.height + 6 : 80;
        const localPage = signal("panel");
        const panelModel = {
            state: () => ({ ...model.state(), page: localPage() }),
        };
        const panelActions = {
            ...actions,
            navigate: (page: string) =>
                page === "panel" ? localPage.set(page) : navigate(page),
        };
        if (model.state().settings.showHiddenIcons)
            void actions.invoke("menubar.refresh");
        popup = Window.open(
            () => <RootScreen model={panelModel} actions={panelActions} />,
            {
                id: "clipy-panel",
                title: "Clipy",
                kind: "popup",
                defaultSize: { width: 440, height: 640 },
                defaultPosition: {
                    x: Math.max(display?.visibleBounds.origin.x || 0, x),
                    y,
                },
                closeOnEscape: true,
                closeOnBlur: true,
                frame: "none",
                level: "floating",
                shadow: true,
            },
        );
        popup.on("close", () => {
            if (menuRefresh) clearInterval(menuRefresh);
            menuRefresh = undefined;
        });
        if (model.state().settings.showHiddenIcons)
            menuRefresh = setInterval(() => {
                void actions.invoke("menubar.refresh");
            }, 15000);
    }
    // Publish after the root surface is attached. A title keeps the item
    // visible while AppKit resolves the imported template image.
    if (!nativeTray)
        effect(() =>
            Tray.set({
                icon: trayIcon,
                title: [{ text: "Clipy" }],
                tooltip: "Clipy TSX Preview",
                onClick: (e) => panel(e.bounds),
            }),
        );
    effect(() =>
        Menu.setApplicationMenu([
            {
                label: tr("Clipy TSX"),
                submenu: [
                    {
                        label: tr("关于 Clipy TSX"),
                        onSelect: () => navigate("settings"),
                    },
                    { type: "separator" },
                    { role: "hide" },
                    { role: "hideOthers" },
                    { role: "showAll" },
                    { type: "separator" },
                    {
                        label: tr("退出 Clipy TSX"),
                        shortcut: "mod+q",
                        onSelect: () => {
                            void Promise.resolve(actions.flushDrafts?.())
                                .then(async () => {
                                    if (model.state().recording?.active)
                                        await actions.invoke("recording.stop");
                                    Application.quit();
                                })
                                .catch((error: any) =>
                                    actions.set("message", String(error)),
                                );
                        },
                    },
                ],
            },
            {
                label: tr("文件"),
                submenu: [
                    {
                        label: tr("历史"),
                        shortcut: "alt+mod+1",
                        onSelect: () => navigate("history"),
                    },
                    {
                        label: tr("片段"),
                        shortcut: "alt+mod+2",
                        onSelect: () => navigate("snippets"),
                    },
                    {
                        label: tr("设备"),
                        shortcut: "alt+mod+3",
                        onSelect: () => navigate("devices"),
                    },
                    {
                        label: tr("通知"),
                        shortcut: "alt+mod+4",
                        onSelect: () => navigate("notifications"),
                    },
                    { type: "separator" },
                    {
                        label: tr("偏好设置…"),
                        shortcut: "mod+,",
                        onSelect: () => navigate("settings"),
                    },
                    { role: "close", label: tr("关闭窗口"), shortcut: "mod+w" },
                ],
            },
            {
                label: tr("编辑"),
                submenu: [
                    { role: "undo" },
                    { role: "redo" },
                    { type: "separator" },
                    { role: "cut" },
                    { role: "copy" },
                    { role: "paste" },
                    { role: "selectAll" },
                ],
            },
            {
                label: tr("工具"),
                submenu: [
                    { label: tr("截图"), onSelect: () => navigate("capture") },
                    {
                        label: tr("录屏"),
                        onSelect: () => navigate("recording"),
                    },
                    { label: tr("查词"), onSelect: () => navigate("words") },
                    {
                        label: tr("单词本"),
                        onSelect: () => navigate("wordbook"),
                    },
                    {
                        label: tr("生成密码"),
                        onSelect: () => navigate("tools"),
                    },
                ],
            },
            {
                label: tr("窗口"),
                submenu: [{ role: "minimize" }, { role: "zoom" }],
            },
        ]),
    );
    const focus = currentWindow().on("focusChange", (event) => {
        if (event.focused) actions.set("uiVisible", true);
    });
    const close = currentWindow().on("closePress", () => {
        void Promise.resolve(actions.flushDrafts?.())
            .then(async () => {
                const result=await actions.invoke("lifecycle.hide");
                if(!result?.cancelled && model.state().uiVisible === false)currentWindow().hide();
            })
            .catch((error: any) => actions.set("message", String(error)));
    });
    // Experimental shortcut avoids taking the installed client's configured keys.
    const registered = new Map<string, string>();
    const callbacks: Record<string, () => void> = {
        searchShortcut: () => navigate("history"),
        lookupShortcut: () => navigate("words"),
        screenshotShortcut: () => {
            navigate("capture");
            void actions.invoke("capture.start", {
                mode: model.state().settings.captureMode,
            });
        },
    };
    async function configureSettings(next: any, old: any) {
        const changed = Object.keys(callbacks).filter(
            (key) => next[key] !== old[key],
        );
        const values = Object.keys(callbacks)
            .map((key) => next[key])
            .filter(Boolean);
        if (new Set(values.map(normalizeShortcut)).size !== values.length)
            throw Error("不同功能不能使用相同快捷键");
        const added: string[] = [];
        try {
            for (const key of changed) {
                const chord = next[key];
                if (chord) {
                    const ok = await GlobalShortcut.register(
                        chord,
                        callbacks[key]!,
                    );
                    if (!ok) throw Error(`快捷键 ${chord} 已被其他应用占用`);
                    added.push(chord);
                }
            }
        } catch (error) {
            for (const chord of added) GlobalShortcut.unregister(chord);
            for (const key of changed) {
                const previous = registered.get(key);
                if (previous)
                    await GlobalShortcut.register(previous, callbacks[key]!);
            }
            throw error;
        }
        for (const key of changed) {
            const previous = registered.get(key);
            if (
                previous &&
                !values
                    .map(normalizeShortcut)
                    .includes(normalizeShortcut(previous))
            )
                GlobalShortcut.unregister(previous);
            if (next[key]) registered.set(key, next[key]);
            else registered.delete(key);
        }
    }
    void model.ready.then(async () => {
        for (const key of Object.keys(callbacks)) {
            const next = model.state().settings;
            try {
                await configureSettings(next, {
                    ...next,
                    [key]: "__restore__",
                });
            } catch (error) {
                actions.set("message", String(error));
            }
        }
    });
    let captureEditor: WindowRef | null = null;
    let captureEditorPath = "";
    effect(() => {
        const state = model.state();
        const capture = state.editorCapture;
        if (!capture || !state.editorPath) {
            captureEditor?.close();
            captureEditor = null;
            captureEditorPath = "";
            return;
        }
        if (captureEditorPath === state.editorPath) return;
        const bounds = capture.displayFrame;
        if (!bounds) return;
        captureEditorPath = state.editorPath;
        const path = state.editorPath;
        const previousEditor = captureEditor;
        captureEditor = null;
        previousEditor?.close();
        let finishing = false;
        const finish = () => {
            if (finishing) return;
            finishing = true;
            void actions.invoke("editor.close").finally(() => {
                if (model.state().captureRestoreMain) Window.get("main")?.focus();
            });
        };
        const opened = Window.open(() => <ImageEditor
            path={path} actions={actions} defaults={state.settings}
            initialSize={{width:capture.width,height:capture.height}}
            pressure={model.state().editorPressure}
            overlay={{ selectionRect:capture.selectionRect, displayFrame:bounds,
                scale:Number(capture.backingScaleFactor || 1) }}
            onClose={finish}
        />, {
            id:"clipy-capture-editor", title:tr("截图标注"), kind:"panel",
            defaultSize:{width:bounds.width,height:bounds.height},
            defaultPosition:{x:bounds.x,y:bounds.y}, frame:"none",
            transparent:true, level:"aboveDock", shadow:false,
            closeOnEscape:true, closeOnPress:true, closeOnBlur:false,
            restoreBounds:false, movable:false, resizable:false,
        });
        captureEditor = opened;
        opened.on("close", () => {
            if (captureEditor === opened && model.state().editorCapture) finish();
        });
        opened.focus();
    });
    const dispose = () => {
        captureEditor?.close();
        if (menuRefresh) clearInterval(menuRefresh);
        popup?.close();
        popup = null;
        close();
        focus();
        GlobalShortcut.unregisterAll();
        if (!nativeTray) Tray.set(null);
    };
    cleanup(dispose);
    return { panel, navigate, dispose, configureSettings };
}
