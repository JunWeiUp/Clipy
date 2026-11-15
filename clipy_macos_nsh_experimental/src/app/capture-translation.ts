import type { Annotation } from "../editor/scene";

export interface TranslationRect { x: number; y: number; width: number; height: number }
export interface CaptureOCRResult {
    rows: { id?: string; text: string; rect: TranslationRect; confidence?: number }[];
    width?: number;
    height?: number;
    coordinateSpace: "source-pixels-top-left";
}
export interface CaptureTranslationStatus {
    phase: "recognizing" | "translating" | "complete" | "cancelled" | "failed";
    completed: number;
    total: number;
}
export interface CaptureTranslationOptions {
    sourcePath: string;
    sourceSize: { width: number; height: number };
    invoke(method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<any>;
    onStatus?(status: CaptureTranslationStatus): void;
}
export class CaptureTranslationError extends Error {
    constructor(public code: string, message: string) { super(message); this.name = "CaptureTranslationError"; }
}
let instanceSequence = 0;
const cancelled = () => new CaptureTranslationError("CANCELLED", "截图翻译已取消");

/** No OCR or network work starts until submit. A batch is returned atomically. */
export function createCaptureTranslation(options: CaptureTranslationOptions) {
    let generation = 0, active: AbortController | null = null, disposed = false;
    const instance = ++instanceSequence;
    const sourceSize = { ...options.sourceSize };
    function cancel() {
        generation++;
        const previous = active;
        active = null;
        previous?.abort();
        if (previous && !disposed) options.onStatus?.({ phase: "cancelled", completed: 0, total: 0 });
    }
    function dispose() { disposed = true; cancel(); }
    async function submit(target: string, colors: { background?: string; color?: string } = {}): Promise<Annotation[]> {
        if (disposed) throw new CaptureTranslationError("CLOSED", "截图编辑器已关闭");
        cancel();
        const current = generation;
        const controller = new AbortController();
        active = controller;
        const signal = controller.signal;
        const check = () => { if (disposed || signal.aborted || generation !== current) throw cancelled(); };
        const status = (phase: CaptureTranslationStatus["phase"], completed: number, total: number) => {
            if (!disposed && generation === current) options.onStatus?.({ phase, completed, total });
        };
        async function invoke(method: string, params: Record<string, unknown>) {
            check();
            // Also settles promptly when a test/adapter ignores AbortSignal; its late
            // resolution is observed, discarded and never published.
            return new Promise<any>((resolve, reject) => {
                const abort = () => reject(cancelled());
                signal.addEventListener("abort", abort, { once: true });
                Promise.resolve().then(() => { check(); return options.invoke(method, params, signal); })
                    .then(value => { check(); resolve(value); }, reject)
                    .catch(reject)
                    .finally(() => signal.removeEventListener("abort", abort));
            });
        }
        try {
            target = target.trim();
            if (!target || Array.from(target).length > 80) throw new CaptureTranslationError("INVALID_TARGET", "请明确选择目标语言");
            if (!options.sourcePath || !Number.isFinite(sourceSize.width) || !Number.isFinite(sourceSize.height) || sourceSize.width < 1 || sourceSize.height < 1)
                throw new CaptureTranslationError("INVALID_SOURCE", "截图尺寸无效");
            const background = colors.background ?? "#FFFFFF", color = colors.color ?? "#000000";
            if (!/^#[0-9a-f]{6}$/i.test(background) || !/^#[0-9a-f]{6}$/i.test(color))
                throw new CaptureTranslationError("INVALID_COLOR", "请选择不透明背景和文字颜色");
            status("recognizing", 0, 0);
            const ocr = await invoke("ocr.recognize", { path: options.sourcePath }) as CaptureOCRResult;
            check();
            if (!ocr || ocr.coordinateSpace !== "source-pixels-top-left" || !Array.isArray(ocr.rows))
                throw new CaptureTranslationError("INVALID_OCR", "文字识别未返回原图坐标，请重试");
            if ((ocr.width !== undefined && ocr.width !== sourceSize.width) || (ocr.height !== undefined && ocr.height !== sourceSize.height))
                throw new CaptureTranslationError("SOURCE_CHANGED", "截图尺寸已变化，请重新识别");
            const rows = ocr.rows.filter(row => typeof row?.text === "string" && row.text.trim().length > 0);
            if (!rows.length) throw new CaptureTranslationError("NO_TEXT", "截图中未识别到可翻译文字");
            if (rows.length > 20) throw new CaptureTranslationError("TOO_MANY_ROWS", "最多翻译 20 行，请缩小截图范围");
            // Validate the entire batch before any text leaves the device.
            for (const row of rows) {
                if (Array.from(row.text).length > 500) throw new CaptureTranslationError("ROW_TOO_LONG", "单行最多 500 字，请缩小截图范围");
                const r = row.rect;
                if (!r || ![r.x, r.y, r.width, r.height].every(Number.isFinite) || r.x < 0 || r.y < 0 || r.width <= 0 || r.height <= 0 || r.x + r.width > sourceSize.width + .01 || r.y + r.height > sourceSize.height + .01)
                    throw new CaptureTranslationError("INVALID_OCR", "识别文字坐标超出截图范围");
            }
            const result: Annotation[] = [];
            status("translating", 0, rows.length);
            for (let index = 0; index < rows.length; index++) {
                const row = rows[index]!;
                const translated = await invoke("model.translate", { text: row.text, target });
                check();
                if (typeof translated?.text !== "string" || !translated.text.trim()) throw new CaptureTranslationError("EMPTY_TRANSLATION", "模型返回空译文，请重试");
                if (new TextEncoder().encode(translated.text).length > 16384) throw new CaptureTranslationError("TRANSLATION_TOO_LONG", "模型返回的单行译文过长");
                const r = row.rect, id = `translation-${instance}-${current}-${index}`;
                const points = [{ x: r.x, y: r.y }, { x: r.x + r.width, y: r.y + r.height }];
                result.push({ id: `${id}-background`, tool: "solid", points, color: background, width: 1, opacity: 1, filled: true });
                const text: Annotation & { textBox: { width: number; height: number } } = {
                    id, tool: "text", points: points.map(point => ({ ...point })), color, width: 1, opacity: 1,
                    text: translated.text, fontSize: Math.max(8, Math.min(200, r.height * .8)), align: "left",
                    background, textBox: { width: r.width, height: r.height },
                };
                result.push(text);
                status("translating", index + 1, rows.length);
            }
            check();
            status("complete", rows.length, rows.length);
            return result;
        } catch (error) {
            if (disposed || signal.aborted || generation !== current) throw cancelled();
            status("failed", 0, 0);
            throw error;
        } finally {
            if (generation === current && active === controller) active = null;
        }
    }
    return { submit, cancel, dispose };
}
