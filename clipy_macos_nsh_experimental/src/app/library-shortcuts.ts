import { cleanup, effect } from "nsh";
import { GlobalShortcut, Menu } from "nsh/desktop";
import { t } from "../ui/locale";
import { normalizeShortcut } from "../core/shortcuts";

/** Registrations follow the library, including empty-string clears and deletions. */
export function installLibraryShortcuts(model: any, actions: any) {
    const registered = new Map<string, { chord: string; value: string }>();
    let signature = "",
        closed = false,
        queue = Promise.resolve();
    effect(() => {
        const state = model.state();
        const records = [
            ...state.folders
                .filter((row: any) => row.shortcut)
                .map((row: any) => ({
                    id: `folder:${row.id}`,
                    chord: row.shortcut,
                    value: row.id,
                    kind: "folder",
                })),
            ...state.snippets
                .filter((row: any) => row.shortcut)
                .map((row: any) => ({
                    id: `snippet:${row.id}`,
                    chord: row.shortcut,
                    value: row.content,
                    kind: "snippet",
                })),
        ];
        const next = JSON.stringify(records);
        if (next === signature) return;
        signature = next;
        queue = queue
            .catch(() => {})
            .then(async () => {
                if (closed) return;
                for (const [id, old] of registered) {
                    const row = records.find((r: any) => r.id === id);
                    if (
                        !row ||
                        normalizeShortcut(row.chord) !==
                            normalizeShortcut(old.chord)
                    ) {
                        GlobalShortcut.unregister(old.chord);
                        registered.delete(id);
                    }
                }
                if (records.length > 128)
                    actions.set?.(
                        "message",
                        "最多同时注册128个片段和文件夹快捷键",
                    );
                for (const row of records.slice(0, 128)) {
                    if (closed) return;
                    const old = registered.get(row.id);
                    if (old?.chord === row.chord && old?.value === row.value)
                        continue;
                    const callback = () => {
                        if (row.kind === "folder") {
                            const snippets = model
                                .state()
                                .snippets.filter(
                                    (s: any) => s.folderId === row.value,
                                );
                            void Menu.popup(
                                snippets.length
                                    ? snippets.map((s: any) => ({
                                          label:
                                              s.title || s.content.slice(0, 40),
                                          onSelect: () => {
                                              void actions.invoke(
                                                  "clipboard.copy",
                                                  {
                                                      text: s.content,
                                                      paste: true,
                                                  },
                                              );
                                          },
                                      }))
                                    : [
                                          {
                                              label: t("这个文件夹还没有片段"),
                                              disabled: true,
                                          },
                                      ],
                            );
                        } else
                            void actions.invoke("clipboard.copy", {
                                text: row.value,
                                paste: true,
                            });
                    };
                    try {
                        if (
                            !(await GlobalShortcut.register(
                                row.chord,
                                callback,
                            ))
                        )
                            throw Error(`快捷键 ${row.chord} 已被其他应用占用`);
                        registered.set(row.id, {
                            chord: row.chord,
                            value: row.value,
                        });
                    } catch (error) {
                        actions.set?.(
                            "message",
                            error instanceof Error
                                ? error.message
                                : String(error),
                        );
                    }
                }
            });
    });
    const dispose = () => {
        closed = true;
        for (const row of registered.values())
            GlobalShortcut.unregister(row.chord);
        registered.clear();
    };
    cleanup(dispose);
    return dispose;
}
