import { bounds, type Annotation } from "./scene";
import type { TranslationRect } from "../app/capture-translation";

type Kind = "highlight" | "text-censor";
export interface SmartHighlightStatus {
    phase: "pending" | "aligned" | "failed" | "limit";
    pending: number;
    count?: number;
    message?: string;
}
export interface SmartHighlightOptions {
    sourcePath(): string;
    invoke(method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<any>;
    getAnnotations(): Annotation[];
    setAnnotations(rows: Annotation[]): void;
    onStatus?(status: SmartHighlightStatus): void;
}
class SmartHighlightError extends Error {
    constructor(public code: string, message: string) { super(message); }
}
type Pending = { stroke: Annotation; signature: string; kind: Kind };
export function createSmartHighlight(options: SmartHighlightOptions) {
    let generation = 0, sequence = 0, disposed = false, source = "";
    let controller: AbortController | null = null;
    let cached: TranslationRect[] | null = null;
    let running: number | null = null;
    let failure: unknown = null;
    const pending = new Map<string, Pending>();
    const waiters: { resolve(): void; reject(error: unknown): void }[] = [];
    const report = (phase: SmartHighlightStatus["phase"], extra: Partial<SmartHighlightStatus> = {}) => {
        if (!disposed) options.onStatus?.({ phase, pending: pending.size, ...extra });
    };
    const cancelError = () => new SmartHighlightError("CANCELLED", "智能文字处理已取消");
    function reset() {
        generation++;
        controller?.abort();controller = null;
        pending.clear();cached = null;running = null;failure = null;source = "";
        for (const waiter of waiters.splice(0)) waiter.reject(cancelError());
        report("pending");
    }
    function dispose() { disposed = true;reset(); }
    function settle(): Promise<void> {
        if (disposed) return Promise.reject(cancelError());
        if (!pending.size && running === null) return failure ? Promise.reject(failure) : Promise.resolve();
        return new Promise<void>((resolve, reject) => waiters.push({ resolve, reject }));
    }
    function wake() {
        if (pending.size || running !== null) return;
        for (const waiter of waiters.splice(0)) failure ? waiter.reject(failure) : waiter.resolve();
    }
    async function drain() {
        const current = generation, path = source;
        if (running !== null || disposed) return;
        running = current;
        controller = new AbortController();const signal = controller.signal;
        const fresh = () => !disposed && generation === current && options.sourcePath() === path && !signal.aborted;
        try {
            if (!cached) {
                const result = await options.invoke("ocr.recognize", { path }, signal);
                if (!fresh()) return;
                if (result?.coordinateSpace !== "source-pixels-top-left" || !Array.isArray(result.rows) || result.rows.length > 2000)
                    throw new SmartHighlightError("INVALID_OCR", "识别未返回原图文字坐标，已保留原笔画");
                cached = result.rows.map((row: any) => row.rect as TranslationRect);
                if (!cached!.every(r => r && [r.x, r.y, r.width, r.height].every(Number.isFinite) && r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0))
                    throw new SmartHighlightError("INVALID_OCR", "文字识别坐标无效，已保留原笔画");
            }
            if (!fresh()) return;
            let annotations = options.getAnnotations(), changed = false, matched = 0, emptyCensor = false;
            for (const [id, work] of pending) {
                pending.delete(id);
                const position = annotations.findIndex(a => a.id === id && JSON.stringify(a) === work.signature);
                if (position < 0) continue; // Deleted, undone or edited strokes are never reinserted.
                const b = bounds(work.stroke), padX = work.kind === "highlight" ? 4 : 0, padY = work.kind === "highlight" ? 20 : 0;
                const area = { x: b.x - padX, y: b.y - padY, width: b.width + padX * 2, height: b.height + padY * 2 };
                const boxes = cached!.flatMap(r => {
                    const x = Math.max(area.x, r.x), right = Math.min(area.x + area.width, r.x + r.width);
                    const y = Math.max(area.y, r.y), bottom = Math.min(area.y + area.height, r.y + r.height);
                    if (right <= x || bottom <= y) return [];
                    return [{ x, y: work.kind === "highlight" ? r.y : y, width: right - x, height: work.kind === "highlight" ? r.height : bottom - y }];
                });
                if (!boxes.length && work.kind === "highlight") {
                    failure = new SmartHighlightError("NO_TEXT", "未匹配到文字行，已保留原笔画");continue;
                }
                if (annotations.length - 1 + boxes.length > 500) {
                    failure = new SmartHighlightError("ANNOTATION_LIMIT", "最多支持 500 个标注，已保留原笔画");continue;
                }
                const replacements: Annotation[] = boxes.map(r => ({
                    ...work.stroke, id: `smart-${current}-${++sequence}`,
                    points: [{ x: r.x, y: r.y }, { x: r.x + r.width, y: r.y + r.height }],
                    ...(work.kind === "highlight" ? { tool: "highlighter", filled: true, width: 3 } : {}),
                }));
                annotations = [...annotations.slice(0, position), ...replacements, ...annotations.slice(position + 1)];
                changed = true;matched += replacements.length;
                if (!boxes.length) emptyCensor = true;
            }
            if (!fresh()) return;
            if (changed) { options.setAnnotations(annotations);report("aligned", { count: matched, ...(emptyCensor ? { message: "未识别文字" } : {}) }); }
            if (failure) report("failed", { message: String((failure as Error).message || failure) });
        } catch (error) {
            if (fresh()) { cached = null;pending.clear();failure = error;report("failed", { message: String((error as Error)?.message || error) }); }
        } finally {
            if (generation === current) {
                if (options.sourcePath() !== path) { reset(); }
                else { running = null;controller = null;report("pending");wake(); }
            }
        }
    }
    function queue(stroke: Annotation, settings: { kind?: Kind } = {}): boolean {
        if (disposed) return false;
        const path = options.sourcePath();
        if (source !== path) { reset();source = path; }
        const kind = settings.kind ?? "highlight";
        if (!path || !stroke.id || !stroke.points.length || (kind === "text-censor" && !["mosaic", "blur", "solid", "erase"].includes(stroke.tool))) {
            report("failed", { message: "智能文字处理参数无效，已保留原笔画" });return false;
        }
        if (pending.has(stroke.id)) return false;
        const limit = kind === "highlight" ? 64 : 4;
        if ([...pending.values()].filter(work => work.kind === kind).length >= limit) {
            report("limit", { message: `最多同时处理 ${limit} 笔，已保留原笔画` });return false;
        }
        const signature = JSON.stringify(stroke), copy = JSON.parse(signature) as Annotation;
        pending.set(stroke.id, { stroke: copy, signature, kind });failure = null;
        report("pending");void drain();return true;
    }
    return { queue, reset, dispose, settle };
}
