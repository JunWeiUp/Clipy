export function normalizeShortcut(value: string): string {
    const aliases: Record<string, string> = {
        command: "mod",
        cmd: "mod",
        meta: "mod",
        control: "ctrl",
        option: "alt",
        opt: "alt",
        cmdorctrl: "mod",
    };
    const parts = value
        .toLowerCase()
        .split("+")
        .map((p) => aliases[p.trim()] || p.trim())
        .filter(Boolean);
    const key = parts.pop() || "";
    const modifiers = ["ctrl", "alt", "mod", "shift"].filter((m) =>
        parts.includes(m),
    );
    return [...modifiers, key].join("+");
}
export function assertShortcutFree(
    chord: string,
    owner: string,
    bindings: { owner: string; chord?: string }[],
): void {
    if (!chord) return;
    const normalized = normalizeShortcut(chord);
    const conflict = bindings.find(
        (b) =>
            b.owner !== owner &&
            b.chord &&
            normalizeShortcut(b.chord) === normalized,
    );
    if (conflict) throw Error("快捷键已被其他功能使用，请更换或先清除旧快捷键");
}
