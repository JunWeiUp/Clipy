import { test, expect } from "nsh/test";
import { NativeBridge, type NativeTransport } from "./bridge";

function fake() {
    const writes: string[] = [];
    let line = (s: string) => {};
    let exit = () => {};
    let killed = false;
    const transport: NativeTransport = {
        write: (s) => {
            writes.push(s);
        },
        end: () => {},
        kill: () => {
            killed = true;
        },
        onLine: (fn) => {
            line = fn;
        },
        onExit: (fn) => {
            exit = fn;
        },
    };
    return {
        transport,
        writes,
        reply: (v: any) => line(JSON.stringify(v)),
        exit: () => exit(),
        killed: () => killed,
    };
}
test("native replies correlate across out of order completion and propagate errors", async () => {
    const io = fake();
    const bridge = new NativeBridge(() => io.transport);
    const first = bridge.call("files.pick");
    const second = bridge.call("system.info");
    io.reply({ id: "2", ok: true, result: { name: "Mac" } });
    io.reply({
        id: "1",
        ok: false,
        error: { code: "CANCELLED", message: "已取消" },
    });
    expect((await second).name).toBe("Mac");
    let code = "";
    try {
        await first;
    } catch (e) {
        code = (e as any).code;
    }
    expect(code).toBe("CANCELLED");
    bridge.close();
});
test("native exit rejects outstanding work and unsubscribed events cannot update state", async () => {
    const io = fake();
    const bridge = new NativeBridge(() => io.transport);
    let received = 0;
    const off = bridge.on("clipboard.changed", () => received++);
    const pending = bridge.call("system.info");
    io.reply({ event: "clipboard.changed", payload: {} });
    off();
    io.reply({ event: "clipboard.changed", payload: {} });
    io.exit();
    let code = "";
    try {
        await pending;
    } catch (e) {
        code = (e as any).code;
    }
    expect(received).toBe(1);
    expect(code).toBe("HELPER_EXITED");
    bridge.close();
});

test("escaped text at the supported clipboard byte limit does not close the event pipe", async () => {
    const io = fake();
    const bridge = new NativeBridge(() => io.transport);
    let size = 0;
    bridge.on("clipboard.changed", (payload) => {
        size = payload.text.length;
    });
    const pending = bridge.call("system.info");
    io.reply({
        event: "clipboard.changed",
        payload: { text: "\u0000".repeat(512 * 1024) },
    });
    io.reply({ id: "1", ok: true, result: { ready: true } });
    expect(size).toBe(512 * 1024);
    expect((await pending).ready).toBe(true);
    expect(io.killed()).toBe(false);
    bridge.close();
});

test("aborting a native request cancels only its id and ignores its late reply", async () => {
    const io=fake(), bridge=new NativeBridge(()=>io.transport), abort=new AbortController();
    const task=bridge.call("model.translate",{text:"fixture"},30000,abort.signal).catch(e=>e.code);
    const independent=bridge.call("system.info");
    abort.abort();
    expect(await task).toBe("CANCELLED");
    const cancel=io.writes.map(s=>JSON.parse(s)).find(s=>s.method==="task.cancel");
    expect(cancel.params.requestId).toBe("1");
    io.reply({id:"1",ok:true,result:"late"});
    io.reply({id:"2",ok:true,result:{alive:true}});
    expect((await independent).alive).toBe(true);
    const before=io.writes.length;
    expect(await bridge.call("system.info",{},30000,abort.signal).catch(e=>e.code)).toBe("CANCELLED");
    expect(io.writes.length).toBe(before);
    bridge.close();
});
