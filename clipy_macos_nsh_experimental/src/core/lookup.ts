/** Explicit user-submitted dictionary lookup. No background requests or API secrets. */
export interface DictionaryResult {
    word: string;
    phonetic: string;
    definitions: string[];
    definition: string;
    phrases: { text: string; translation: string }[];
    examples: { text: string; translation: string }[];
    provider: string;
}
function list(value: any): any[] {
    return Array.isArray(value) ? value : [];
}
function text(value: any): string {
    return typeof value === "string"
        ? value
        : typeof value === "number"
          ? String(value)
          : "";
}
export function parseDictionary(data: any, query: string): DictionaryResult {
    const entry = list(data?.ec?.word)[0] || data?.ec?.word || {};
    const definitions = list(entry.trs).flatMap((tr: any) =>
        list(tr.tr).flatMap((r: any) =>
            list(r.l?.i)
                .map((i: any) => text(i))
                .filter(Boolean),
        ),
    );
    const fallback = list(data?.fanyi?.tran).map(text).filter(Boolean);
    if (!definitions.length && typeof data?.fanyi?.tran === "string")
        fallback.push(data.fanyi.tran);
    const phrases = list(data?.phrs?.phrs)
        .map((p: any) => ({
            text: text(p.phr?.headword?.l?.i || p.phr?.headword),
            translation: list(p.phr?.trs)
                .flatMap((t: any) => list(t.tr?.l?.i).map(text))
                .join("；"),
        }))
        .filter((p) => p.text);
    const examples = list(data?.blng_sents_part?.["sentence-pair"])
        .slice(0, 10)
        .map((s: any) => ({
            text: text(s.sentence),
            translation: text(s["sentence-translation"]),
        }))
        .filter((s) => s.text);
    const lines = definitions.length ? definitions : fallback;
    if (!lines.length)
        throw Error("未找到词典释义，请尝试单个英文单词或使用模型翻译");
    return {
        word: text(entry.return?.["i"]) || query,
        phonetic: text(entry.usphone) || text(entry.phone),
        definitions: lines,
        definition: lines.join("\n"),
        phrases,
        examples,
        provider: "有道词典",
    };
}
export async function lookupDictionary(
    query: string,
    signal?: AbortSignal,
): Promise<DictionaryResult> {
    const value = query.trim();
    if (!value || value.length > 500) throw Error("查询内容必须为 1–500 字");
    const controller = new AbortController();
    const cancel = () => controller.abort();
    if (signal?.aborted) controller.abort();
    signal?.addEventListener("abort", cancel);
    const timeout = setTimeout(cancel, 15000);
    try {
        const response = await fetch(
            `https://dict.youdao.com/jsonapi?q=${encodeURIComponent(value)}&jsonversion=2`,
            {
                signal: controller.signal,
                redirect: "error",
                headers: { Accept: "application/json" },
            },
        );
        if (!response.ok) throw Error(`词典请求失败 (${response.status})`);
        const length = Number(response.headers.get("content-length") || 0);
        if (length > 1024 * 1024) throw Error("词典响应超过 1 MiB");
        let raw = "";
        if (response.body) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let total = 0;
            try {
                for (;;) {
                    const part = await reader.read();
                    if (part.done) break;
                    total += part.value.byteLength;
                    if (total > 1024 * 1024) {
                        await reader.cancel();
                        throw Error("词典响应超过 1 MiB");
                    }
                    raw += decoder.decode(part.value, { stream: true });
                }
                raw += decoder.decode();
            } finally {
                reader.releaseLock();
            }
        } else {
            raw = await response.text();
            if (new TextEncoder().encode(raw).byteLength > 1024 * 1024)
                throw Error("词典响应超过 1 MiB");
        }
        return parseDictionary(JSON.parse(raw), value);
    } finally {
        clearTimeout(timeout);
        signal?.removeEventListener("abort", cancel);
    }
}
