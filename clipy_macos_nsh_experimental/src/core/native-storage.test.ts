import { test, expect } from "nsh/test";
import { createNativeStorage } from "./native-storage";
test("post-commit GC failure does not reject durable snapshot write", async () => {
    let committed = false,
        collection = false;
    const host = {
        async call<T = unknown>(name: string, _payload?: unknown): Promise<T> {
            if (name === "storage.write.begin") return { id: "write" } as T;
            if (name === "storage.write.chunk") return {} as T;
            if (name === "storage.write.commit") {
                committed = true;
                return true as T;
            }
            if (name === "media.collect") {
                collection = true;
                throw Error("GC unavailable");
            }
            throw Error(name);
        },
    };
    const storage = createNativeStorage(host);
    await storage.setItem(
        "state",
        JSON.stringify({
            version: 1,
            history: [{ mediaId: "media-a" }],
            folders: [],
            snippets: [],
            settings: {},
        }),
    );
    expect(committed).toBe(true);
    expect(collection).toBe(true);
});
