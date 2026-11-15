import { keymap } from "nsh";
import { Menu, type MenuItem } from "nsh/desktop";
import { t } from "./locale";
import { titleOf, textOf } from "./primitives";
export function showHistoryMenu(
    row: any,
    actions: any,
    position?: { x: number; y: number },
) {
    const file = row.type === "file";
    const path =
        row.files?.[0] ||
        row.mediaPath ||
        String(row.content || "").split("\n")[0];
    const items: MenuItem[] = [
        {
            label: t("复制内容"),
            onSelect: () => void actions.copyHistory?.(row.id, false, false),
        },
        {
            label: t("复制并粘贴"),
            onSelect: () => void actions.copyHistory?.(row.id, true, false),
        },
        {
            label: t("粘贴为纯文本"),
            onSelect: () => void actions.copyHistory?.(row.id, true, true),
        },
    ];
    if (file)
        items.push(
            { type: "separator" },
            {
                label: t("粘贴文件名"),
                disabled: typeof actions.pasteFileNames !== "function",
                onSelect: () => void actions.pasteFileNames?.(row.id),
            },
            {
                label: t("粘贴文件"),
                onSelect: () => void actions.copyHistory?.(row.id, true, false),
            },
            {
                label: t("在 Finder 中显示"),
                onSelect: () => void actions.invoke?.("files.reveal", { path }),
            },
        );
    items.push(
        { type: "separator" },
        {
            label: t(row.isPinned ? "取消置顶" : "置顶"),
            onSelect: () => void actions.pinHistory?.(row.id),
        },
        {
            label: t("存为片段"),
            onSelect: () =>
                void actions.saveSnippet?.({
                    title: titleOf(row),
                    content: textOf(row),
                }),
        },
        {
            label: t("删除"),
            onSelect: () => void actions.deleteHistory?.(row.id),
        },
    );
    return Menu.popup(items, position);
}
export function bindHistoryKeys(options: {
    rows: () => any[];
    current: () => any;
    select: (row: any) => void;
    actions: any;
}) {
    const { rows, current, select, actions } = options;
    const paste = (index?: number, plain = false) => {
        const row = index === undefined ? current() : rows()[index];
        if (row) void actions.copyHistory?.(row.id, true, plain);
    };
    const move = (delta: number) => {
        const list = rows();
        if (!list.length) return;
        const index = list.findIndex((row) => row.id === current()?.id);
        select(list[Math.max(0, Math.min(list.length - 1, index + delta))]);
    };
    const remove = () => {
        const row = current();
        if (row) void actions.deleteHistory?.(row.id);
    };
    return keymap.bind(
        {
            up: () => move(-1),
            down: () => move(1),
            enter: () => paste(),
            "alt+mod+v": () => paste(undefined, true),
            backspace: remove,
            delete: remove,
            "mod+p": () => {
                const row = current();
                if (row) void actions.pinHistory?.(row.id);
            },
            "mod+z": () => void actions.undoDelete?.(),
            ...Object.fromEntries(
                Array.from({ length: 9 }, (_, index) => [
                    `mod+${index + 1}`,
                    () => paste(index),
                ]),
            ),
        },
        { when: "notEditing", repeat: true },
    );
}
