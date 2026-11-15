import { Buffer } from "buffer";
import type { HostAdapter, StorageAdapter } from "./types";
const CHUNK = 64 * 1024,
    MAX = 16 * 1024 * 1024;
/** State crosses the bounded stdio bridge in 64 KiB chunks; never one oversized JSON line. */
export function createNativeStorage(host: HostAdapter): StorageAdapter {
    let latestIds: string[] | null = null,
        collecting = false;
    const scheduleCollect = (value: string) => {
        try {
            const snapshot = JSON.parse(value);
            if (
                snapshot?.version !== 1 ||
                !Array.isArray(snapshot.history) ||
                !Array.isArray(snapshot.folders) ||
                !Array.isArray(snapshot.snippets) ||
                !snapshot.settings ||
                typeof snapshot.settings !== "object"
            )
                return;
            latestIds = [
                ...new Set<string>(
                    snapshot.history
                        .map((row: any) => row?.mediaId)
                        .filter(
                            (id: any) =>
                                typeof id === "string" && id.length <= 128,
                        ),
                ),
            ];
            if (collecting) return;
            collecting = true;
            void (async () => {
                try {
                    while (latestIds) {
                        const ids = latestIds;
                        latestIds = null;
                        try {
                            await host.call("media.collect", { ids });
                        } catch {
                            console.warn(
                                "Media collection deferred; saved state remains durable",
                            );
                        }
                    }
                } finally {
                    collecting = false;
                }
            })();
        } catch {
            /* Arbitrary storage keys are not interpreted as app history. */
        }
    };
    return {
        maxStateBytes: 16 * 1024 * 1024,
        async getItem(key) {
            const start = await host.call<{
                id?: string;
                exists: boolean;
                size: number;
            }>("storage.read.begin", { key });
            if (!start.exists) return null;
            if (!start.id || start.size < 0 || start.size > MAX)
                throw Error("历史读取长度无效");
            const decoder = new TextDecoder();
            let result = "",
                offset = 0;
            try {
                while (offset < start.size) {
                    const part = await host.call<{
                        data: string;
                        nextOffset: number;
                    }>("storage.read.chunk", {
                        id: start.id,
                        offset,
                        length: CHUNK,
                    });
                    const bytes = Buffer.from(part.data, "base64");
                    if (
                        bytes.length > CHUNK ||
                        part.nextOffset !== offset + bytes.length ||
                        !bytes.length
                    )
                        throw Error("历史读取块无效");
                    result += decoder.decode(bytes, { stream: true });
                    offset = part.nextOffset;
                }
                result += decoder.decode();
                return result;
            } finally {
                await host.call("storage.read.end", { id: start.id });
            }
        },
        async setItem(key, value) {
            const bytes = new TextEncoder().encode(value);
            if (bytes.length > MAX) throw Error("历史状态超过16 MiB");
            const start = await host.call<{ id: string }>(
                "storage.write.begin",
                { key, size: bytes.length },
            );
            try {
                for (let offset = 0; offset < bytes.length; offset += CHUNK) {
                    const data = Buffer.from(
                        bytes.subarray(
                            offset,
                            Math.min(bytes.length, offset + CHUNK),
                        ),
                    ).toString("base64");
                    await host.call("storage.write.chunk", {
                        id: start.id,
                        offset,
                        data,
                    });
                }
                await host.call("storage.write.commit", { id: start.id });
                scheduleCollect(value);
            } catch (error) {
                try {
                    await host.call("storage.write.cancel", { id: start.id });
                } catch {}
                throw error;
            }
        },
    };
}
export interface StorageStatus {
    encrypted: boolean;
    rows: number;
    bytes: number;
    mediaCount: number;
    ocrCount: number;
}
export const historyStorage = {
    status: (host: HostAdapter) => host.call<StorageStatus>("storage.status"),
    configure: (host: HostAdapter, encrypted: boolean) =>
        host.call<StorageStatus>("storage.configure", { encrypted }),
    importMedia: (host: HostAdapter, path: string) =>
        host.call<{
            id: string;
            size: number;
            sha256: string;
            encrypted: boolean;
        }>("media.import", { path }),
    lease: (host: HostAdapter, id: string) =>
        host.call<{ leaseId: string; path: string }>("media.lease", { id }),
    abandonImport: (host: HostAdapter, id: string) =>
        host.call("media.abandonImport", { id }),
    collect: (host: HostAdapter, ids: string[]) =>
        host.call("media.collect", { ids }),
    consumeSource: (host: HostAdapter, path: string, id: string) =>
        host.call("media.consumeSource", { path, id }),
    release: (host: HostAdapter, leaseId: string) =>
        host.call("media.release", { leaseId }),
    recognize: (host: HostAdapter, id: string) =>
        host.call<{ id: string; text: string }>("history.ocr", { id }),
    searchOCR: (host: HostAdapter, query: string, offset = 0) =>
        host.call<{ ids: string[]; nextOffset: number | null }>(
            "history.searchOCR",
            { query, offset },
        ),
    cancelOCR: (host: HostAdapter) => host.call("history.cancelOCR"),
};
