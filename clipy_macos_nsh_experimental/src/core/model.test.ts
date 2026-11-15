import { test, expect } from "nsh/test";
import { createAppModel } from "./model";
function fixture(initial: string | null = null) {
    let value = initial;
    const calls: { name: string; payload: unknown }[] = [];
    const storage = {
        async getItem(_key: string) {
            return value;
        },
        async setItem(_key: string, next: string) {
            value = next;
        },
    };
    const host = {
        async call<T = unknown>(name: string, payload?: unknown): Promise<T> {
            calls.push({ name, payload });
            throw Error("此系统能力尚未连接");
        },
    };
    return {
        storage,
        host,
        calls,
        get value() {
            return value;
        },
    };
}
test("history persists across model recreation, delete undo expires correctly", async () => {
    const f = fixture();
    let clock = 100;
    const a = createAppModel({ ...f, now: () => clock });
    await a.ready;
    await a.actions.addHistory({ id: "a", content: "persisted" });
    await a.flush();
    a.dispose();
    const b = createAppModel({ ...f, now: () => clock });
    await b.ready;
    expect(b.state().history[0]?.content).toBe("persisted");
    await b.actions.deleteHistory("a");
    clock += 9000;
    b.actions.undoDelete();
    expect(b.state().history.length).toBe(0);
    b.dispose();
});
test("damaged local state stays byte identical and refuses overwrite", async () => {
    const raw = "{broken";
    const f = fixture(raw);
    const a = createAppModel(f);
    await a.ready;
    let failed = false;
    try {
        await a.actions.addHistory({ content: "new" });
    } catch {
        failed = true;
    }
    expect(failed).toBe(true);
    expect(f.value).toBe(raw);
    expect(a.isStorageHealthy()).toBe(false);
    a.dispose();
});
test("ingest waits for storage load before adding a clipboard change", async () => {
    const f = fixture();
    let release: (s: string | null) => void = () => {};
    const storage = {
        ...f.storage,
        getItem: () =>
            new Promise<string | null>((resolve) => {
                release = resolve;
            }),
    };
    const a = createAppModel({ storage, host: f.host });
    const ingest = a.actions.ingest({
        type: "clipboard.changed",
        data: { id: "a", content: "clipboard" },
    });
    expect(a.state().history.length).toBe(0);
    release(null);
    await ingest;
    expect(a.state().history[0]?.content).toBe("clipboard");
    a.dispose();
});
test("system capability failure is reported and never claimed copied", async () => {
    const f = fixture();
    const a = createAppModel(f);
    await a.ready;
    await a.actions.addHistory({ id: "a", content: "hello" });
    await a.actions.copyHistory("a");
    expect(a.state().message).toBe("此系统能力尚未连接");
    expect(f.calls[0]?.name).toBe("clipboard.write");
    a.dispose();
});
test("unknown secret fields are excluded from persisted settings", async () => {
    const f = fixture();
    const a = createAppModel(f);
    await a.ready;
    await a.actions.saveSettings({
        apiKey: "test-private-value",
        historyLimit: 50,
    });
    await a.flush();
    expect(f.value?.includes("test-private-value")).toBe(false);
    expect(a.state().settings.historyLimit).toBe(50);
    a.dispose();
});
test("password has all selected classes and never persists secret", async () => {
    const f = fixture();
    const a = createAppModel(f);
    await a.ready;
    const password = await a.actions.generatePassword({ length: 24 });
    expect(password?.length).toBe(24);
    expect(/[A-Z]/.test(password || "")).toBe(true);
    expect(/[a-z]/.test(password || "")).toBe(true);
    expect(/[0-9]/.test(password || "")).toBe(true);
    expect(/[^A-Za-z0-9]/.test(password || "")).toBe(true);
    expect(f.value).toBe(null);
    a.dispose();
});
test("storage failure rejects commit and flush so transport must not ACK", async () => {
    const f = fixture();
    const a = createAppModel({
        host: f.host,
        storage: {
            getItem: f.storage.getItem,
            async setItem() {
                throw Error("disk full");
            },
        },
    });
    await a.ready;
    let rejected = 0;
    try {
        await a.actions.addHistory({ content: "not durable" });
    } catch {
        rejected++;
    }
    try {
        await a.flush();
    } catch {
        rejected++;
    }
    expect(rejected).toBe(2);
    expect(a.state().message).toBe("保存失败：disk full");
    a.dispose();
});
test("disposed model rejects late inbound mutation and preserves durable state", async () => {
    const f = fixture();
    const a = createAppModel(f);
    await a.ready;
    await a.actions.addHistory({ content: "before close" });
    const saved = f.value;
    a.dispose();
    let rejected = false;
    try {
        await a.actions.addHistory({ content: "late event" });
    } catch {
        rejected = true;
    }
    expect(rejected).toBe(true);
    expect(f.value).toBe(saved);
});
test("excluded bundle ID wins over localized display name and icon metadata survives persistence", async () => {
    const f = fixture();
    const a = createAppModel({
        storage: f.storage,
        host: {
            async call<T = unknown>(): Promise<T> {
                return true as T;
            },
        },
    });
    await a.ready;
    await a.actions.saveSettings({ excludedApps: ["com.fixture.secret"] });
    await a.actions.addHistory({
        content: "excluded-content-fixture",
        sourceApp: "Localized App",
        sourceBundleId: "com.fixture.secret",
    });
    expect(a.state().history.length).toBe(0);
    await a.actions.addHistory({
        content: "public",
        sourceApp: "Normal App",
        sourceBundleId: "com.fixture.normal",
        sourceIconPath: "/private/fixture-icon.png",
    });
    await a.flush();
    expect(a.state().history[0]?.sourceApp).toBe("Normal App");
    expect(a.state().history[0]?.sourceBundleId).toBe("com.fixture.normal");
    expect(
        JSON.parse(f.value!).history.some(
            (row: any) => row.content === "excluded-content-fixture",
        ),
    ).toBe(false);
    expect(f.value?.includes("Localized App")).toBe(false);
    a.dispose();
});
