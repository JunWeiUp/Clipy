import { test, expect } from "nsh/test";
import { createSmartHighlight } from "./smart-highlight";
import type { Annotation } from "./scene";
function stroke(id: string, tool: Annotation["tool"] = "highlighter"): Annotation {
    return { id, tool, color: "#FFCC00", opacity: .5, width: 8, points: [{ x: 10, y: 30 }, { x: 150, y: 35 }] };
}
const recognized = { coordinateSpace: "source-pixels-top-left", rows: [{ rect: { x: 20, y: 15, width: 100, height: 20 } }] };
function deferred() { let resolve!: (value: any) => void, reject!: (error: any) => void;const promise = new Promise<any>((yes, no) => { resolve = yes;reject = no; });return { promise, resolve, reject }; }
async function code(work: Promise<void>) { try { await work;return "OK"; } catch (error) { return (error as any).code || "ERROR"; } }

test("smart highlight shares OCR across consecutive strokes and preserves new unrelated annotations", async () => {
    const request = deferred();let calls = 0, rows = [stroke("a"), stroke("b")];
    const engine = createSmartHighlight({ sourcePath: () => "source", invoke: async () => { calls++;return request.promise; }, getAnnotations: () => rows, setAnnotations: value => { rows = value; } });
    engine.queue(rows[0]!);engine.queue(rows[1]!);rows = [...rows, stroke("new", "pen")];
    request.resolve(recognized);await engine.settle();
    expect(calls).toBe(1);expect(rows.length).toBe(3);expect(rows[2]!.id).toBe("new");
    expect(rows[0]!.filled).toBe(true);expect(rows[0]!.points).toEqual([{ x: 20, y: 15 }, { x: 120, y: 35 }]);
    rows = [...rows, stroke("c")];engine.queue(rows[3]!);await engine.settle();expect(calls).toBe(1);
    engine.dispose();
});

test("smart highlight never resurrects an undone stroke or replaces a changed stroke", async () => {
    const request = deferred();let rows = [stroke("deleted"), stroke("edited")];const pendingCounts:number[]=[];
    const engine = createSmartHighlight({ sourcePath: () => "source", invoke: () => request.promise, getAnnotations: () => rows, setAnnotations: value => { rows = value; },onStatus:status=>{if(status.phase==="pending")pendingCounts.push(status.pending);} });
    engine.queue(rows[0]!);engine.queue(rows[1]!);
    rows = [{ ...rows[1]!, color: "#000000" }, stroke("later")];
    request.resolve(recognized);await engine.settle();
    expect(rows.map(row => row.id)).toEqual(["edited", "later"]);expect(rows[0]!.color).toBe("#000000");expect(pendingCounts[pendingCounts.length-1]).toBe(0);engine.dispose();
});

test("smart highlight reset rejects settle, cancels specific OCR and ignores late results", async () => {
    const request = deferred();let rows = [stroke("a")], signal: AbortSignal | undefined, calls = 0;
    const engine = createSmartHighlight({ sourcePath: () => "source", invoke: async (_, __, abort) => { calls++;signal = abort;return calls === 1 ? request.promise : recognized; }, getAnnotations: () => rows, setAnnotations: value => { rows = value; } });
    engine.queue(rows[0]!);const waiting = code(engine.settle());engine.reset();
    expect(await waiting).toBe("CANCELLED");expect(signal!.aborted).toBe(true);
    request.resolve(recognized);await Promise.resolve();expect(rows[0]!.id).toBe("a");
    engine.queue(rows[0]!);await engine.settle();expect(calls).toBe(2);engine.dispose();
});

test("smart highlight and text-censor have separate bounded queues and share one OCR", async () => {
    const request = deferred();let rows: Annotation[] = [], calls = 0;
    const engine = createSmartHighlight({ sourcePath: () => "source", invoke: async () => { calls++;return request.promise; }, getAnnotations: () => rows, setAnnotations: value => { rows = value; } });
    for (let i = 0; i < 65; i++) { const item = stroke(`h${i}`);rows.push(item);expect(engine.queue(item)).toBe(i < 64); }
    for (let i = 0; i < 5; i++) { const item = stroke(`c${i}`, "mosaic");rows.push(item);expect(engine.queue(item, { kind: "text-censor" })).toBe(i < 4); }
    request.resolve(recognized);await engine.settle();
    expect(calls).toBe(1);expect(rows.some(row => row.id === "h64")).toBe(true);expect(rows.some(row => row.id === "c4")).toBe(true);
    const mosaic = rows.find(row => row.tool === "mosaic" && row.id !== "c4")!;
    expect(mosaic.points).toEqual([{ x: 20, y: 30 }, { x: 120, y: 35 }]);engine.dispose();
});

test("smart processing failures and annotation capacity retain originals; empty censor removes only itself", async () => {
    let rows = [stroke("censor", "blur"), stroke("keep", "pen")], response: any = { ...recognized, rows: [] };
    const engine = createSmartHighlight({ sourcePath: () => "source", invoke: async () => response, getAnnotations: () => rows, setAnnotations: value => { rows = value; } });
    engine.queue(rows[0]!, { kind: "text-censor" });await engine.settle();expect(rows.map(row => row.id)).toEqual(["keep"]);
    engine.reset();response = { ...recognized, rows: [recognized.rows[0], recognized.rows[0]] };
    rows = Array.from({ length: 500 }, (_, i) => stroke(String(i)));
    engine.queue(rows[0]!);expect(await code(engine.settle())).toBe("ANNOTATION_LIMIT");expect(rows[0]!.id).toBe("0");
    engine.reset();response = { text: "legacy" };engine.queue(rows[0]!);
    expect(await code(engine.settle())).toBe("INVALID_OCR");expect(rows.length).toBe(500);engine.dispose();
});

test("smart processing source change drops old cache and errors remain explicit", async () => {
    let path = "first", rows = [stroke("a")], calls = 0;
    const engine = createSmartHighlight({ sourcePath: () => path, invoke: async () => { calls++;if (calls === 2) throw Object.assign(new Error("worker unavailable"), { code: "WORKER_FAILED" });return recognized; }, getAnnotations: () => rows, setAnnotations: value => { rows = value; } });
    engine.queue(rows[0]!);await engine.settle();path = "second";rows.push(stroke("b"));engine.queue(rows[1]!);
    expect(await code(engine.settle())).toBe("WORKER_FAILED");expect(rows[1]!.id).toBe("b");expect(calls).toBe(2);engine.dispose();
});
