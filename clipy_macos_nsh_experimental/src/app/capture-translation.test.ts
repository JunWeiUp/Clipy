import { test, expect } from "nsh/test";
import { createCaptureTranslation, type CaptureOCRResult } from "./capture-translation";

const row = (text = "original", x = 10) => ({ text, rect: { x, y: 20, width: 100, height: 30 } });
const ocr = (rows = [row()]): CaptureOCRResult => ({ rows, width: 400, height: 300, coordinateSpace: "source-pixels-top-left" });
const source = { sourcePath: "/synthetic/source.png", sourceSize: { width: 400, height: 300 } };
async function errorCode(work: Promise<unknown>) { try { await work; return "NO_ERROR"; } catch (error) { return String((error as any).code || (error as any).message); } }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
async function spinUntil(check: () => boolean) { for (let i = 0; i < 30 && !check(); i++) await Promise.resolve(); expect(check()).toBe(true); }

test("capture translation starts only on explicit submit, preserves pixel boxes and returns editable atomic layers", async () => {
    const calls: string[] = [];
    let concurrent = 0, peak = 0;
    const translator = createCaptureTranslation({ ...source, invoke: async (method, params) => {
        calls.push(method);
        if (method === "ocr.recognize") return ocr([row("one"), row("two", 120)]);
        concurrent++; peak = Math.max(peak, concurrent); await Promise.resolve(); concurrent--;
        expect(params.target).toBe("English"); return { text: `translated ${params.text}` };
    } });
    expect(calls.length).toBe(0);
    const result = await translator.submit("English", { background: "#123456" });
    expect(peak).toBe(1); expect(result.length).toBe(4);
    expect(result[0]!.tool).toBe("solid"); expect(result[0]!.color).toBe("#123456");
    expect(result[1]!.tool).toBe("text"); expect(result[1]!.points).toEqual([{ x: 10, y: 20 }, { x: 110, y: 50 }]);
    expect((result[1] as any).textBox).toEqual({ width: 100, height: 30 });
    expect(result[1]!.text).toBe("translated one");
    translator.dispose();
});

test("capture translation validates the full batch before networking without silent truncation", async () => {
    let modelCalls = 0;
    for (const [result, code] of [
        [ocr(Array.from({ length: 21 }, () => row())), "TOO_MANY_ROWS"],
        [ocr([row("😀".repeat(501))]), "ROW_TOO_LONG"],
        [ocr([row("text", -1)]), "INVALID_OCR"],
        [{ text: "legacy only" }, "INVALID_OCR"],
        [ocr([]), "NO_TEXT"],
        [{ ...ocr(), width: 800 }, "SOURCE_CHANGED"],
    ] as const) {
        const translator = createCaptureTranslation({ ...source, invoke: async method => {
            if (method === "ocr.recognize") return result;
            modelCalls++; return { text: "translation" };
        } });
        expect(await errorCode(translator.submit("English"))).toBe(code);
        translator.dispose();
    }
    expect(modelCalls).toBe(0);
});

test("capture translation accepts 500 Unicode characters and preserves empty/model errors", async () => {
    let mode = "empty", seen = "";
    const translator = createCaptureTranslation({ ...source, invoke: async (method, params) => {
        if (method === "ocr.recognize") return ocr([row("😀".repeat(500))]);
        seen = String(params.text);
        if (mode === "error") throw Object.assign(new Error("model rejected"), { code: "AUTH_REJECTED" });
        return { text: "   " };
    } });
    expect(await errorCode(translator.submit("English"))).toBe("EMPTY_TRANSLATION");
    expect(Array.from(seen).length).toBe(500);
    mode = "error";
    expect(await errorCode(translator.submit("English"))).toBe("AUTH_REJECTED");
    translator.dispose();
});

test("capture translation cancels a stale target and cannot publish late results even if adapter ignores abort", async () => {
    const old = deferred<any>(); let firstSignal: AbortSignal | null = null, reachedOld = false;
    const translator = createCaptureTranslation({ ...source, invoke: async (method, params, signal) => {
        if (method === "ocr.recognize") return ocr();
        if (params.target === "old") { firstSignal = signal; reachedOld = true; return old.promise; }
        return { text: "new result" };
    } });
    const previous = errorCode(translator.submit("old"));
    await spinUntil(() => reachedOld);
    const result = await translator.submit("new");
    expect(await previous).toBe("CANCELLED"); expect(firstSignal!.aborted).toBe(true);
    expect(result[1]!.text).toBe("new result");
    old.resolve({ text: "late old result" }); await Promise.resolve();
    expect(result[1]!.text).toBe("new result");
    translator.dispose();
    expect(await errorCode(translator.submit("again"))).toBe("CLOSED");
});

test("capture translation closing during OCR settles cancellation and never sends text", async () => {
    const pending = deferred<any>(); let entered = false, modelCalls = 0;
    const translator = createCaptureTranslation({ ...source, invoke: async method => {
        if (method === "ocr.recognize") { entered = true; return pending.promise; }
        modelCalls++; return { text: "never" };
    } });
    const result = errorCode(translator.submit("English"));
    await spinUntil(() => entered); translator.dispose();
    expect(await result).toBe("CANCELLED"); pending.resolve(ocr()); await Promise.resolve();
    expect(modelCalls).toBe(0);
});

test("capture translation returns no partial batch when a later row fails and rejects absent explicit target", async () => {
    let requests = 0, modelCalls = 0;
    const translator = createCaptureTranslation({ ...source, invoke: async method => {
        requests++;
        if (method === "ocr.recognize") return ocr([row("first"), row("second", 120)]);
        modelCalls++;
        if (modelCalls === 2) throw Object.assign(new Error("server busy"), { code: "RATE_LIMITED" });
        return { text: "first translation" };
    } });
    expect(await errorCode(translator.submit(" "))).toBe("INVALID_TARGET");
    expect(requests).toBe(0);
    expect(await errorCode(translator.submit("English"))).toBe("RATE_LIMITED");
    expect(modelCalls).toBe(2);
    translator.dispose();
});
