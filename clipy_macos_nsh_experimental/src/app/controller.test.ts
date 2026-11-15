import { expect, test } from "nsh/test";
import { createController } from "./controller";

function harness(captureAction?: string, captureExtra:Record<string,unknown> = {}, overrides:Record<string,(p:any)=>any> = {}) {
    const data = new Map<string, string>();
    let diskFailed = false;
    const storage = {
        getItem: async (k: string) => data.get(k) || null,
        setItem: async (k: string, v: string) => {
            if (diskFailed) throw Error("disk full");
            data.set(k, v);
        },
        removeItem: async (k: string) => {
            data.delete(k);
        },
        keys: async () => [...data.keys()],
        clear: async () => data.clear(),
    };
    const calls: { name: string; p: any }[] = [];
    const listeners = new Map<string, Set<(p: any) => any>>();
    const bridge = {
        call: async <T = any>(name: string, p: any): Promise<T> => {
            calls.push({ name, p });
            if (overrides[name]) return overrides[name](p) as T;
            if (name === "capture.screen")
                return { path: "/private/capture.png", action: captureAction, displayId:4,
                    selectionRect:{x:-900,y:150,width:400,height:300},
                    displayFrame:{x:-1200,y:100,width:1200,height:800}, ...captureExtra } as T;
            if (name === "capture.scroll") return {path:"/private/scroll.png"} as T;
            if (name === "recording.start") return {active:true} as T;
            return true as T;
        },
        on: (name: string, fn: (p: any) => any) => {
            if (!listeners.has(name)) listeners.set(name, new Set());
            listeners.get(name)!.add(fn);
            return () => {
                listeners.get(name)!.delete(fn);
            };
        },
        close: () => {
            listeners.clear();
        },
    };
    const app = createController({
        storage,
        bridge,
        confirm: async () => true,
    });
    return {
        app,
        calls,
        failDisk: () => {
            diskFailed = true;
        },
        emit: async (name: string, p: any) => {
            for (const fn of listeners.get(name) || []) await fn(p);
        },
    };
}
test("manual device sending keeps peer identity and uses the unified v3 transport", async () => {
    const { app, calls } = harness();
    await app.model.ready;
    await app.actions.invoke("sync.sendText", {
        peerId: "peer-1",
        text: "hello",
    });
    const call = calls.find((c) => c.name === "lan.sendText");
    expect(call?.p.peerId).toBe("peer-1");
    expect(call?.p.text).toBe("hello");
    await app.dispose();
});
test("capture entry commits a real path and exposes the result to the screen", async () => {
    const { app } = harness();
    await app.model.ready;
    await app.actions.invoke("capture.start", { mode: "region" });
    expect(app.model.state().capturePath).toBe("/private/capture.png");
    expect(app.model.state().history[0]?.mediaPath).toBe(
        "/private/capture.png",
    );
    await app.dispose();
});
test("inbound history acknowledges only after persistent commit and retains remote identity", async () => {
    const { app, emit, calls } = harness();
    await app.model.ready;
    await emit("lan.history.received", {
        messageId: "receipt-1",
        content: "received",
        type: "text",
        peerId: "peer",
        date: 1,
    });
    expect(app.model.state().history[0]?.id).toBe("receipt-1");
    expect(calls.find((c) => c.name === "lan.ack")?.p.messageId).toBe(
        "receipt-1",
    );
    await app.dispose();
});
test("disk failure never produces an inbound receipt", async () => {
    const { app, emit, calls, failDisk } = harness();
    await app.model.ready;
    failDisk();
    await emit("lan.history.received", {
        messageId: "receipt-2",
        content: "unsaved",
        type: "text",
        peerId: "peer",
        date: 1,
    });
    expect(calls.some((c) => c.name === "lan.ack")).toBe(false);
    expect(app.model.state().message.includes("disk full")).toBe(true);
    try {
        await app.dispose();
    } catch {}
});

test("generated credentials and relay invitations never enter clipboard history", async () => {
    const { app, emit, calls } = harness();
    await app.model.ready;
    const first = await app.actions.generatePassword({ length: 20 });
    await app.actions.generatePassword({ length: 24 });
    await emit("clipboard.changed", {
        type: "text",
        text: first,
        changeCount: 41,
    });
    await emit("clipboard.changed", {
        type: "text",
        text: "common-relay://i/fixture#test-key.test-password",
        changeCount: 42,
    });
    expect(app.model.state().history.length).toBe(0);
    expect(
        calls.filter((c) => c.name === "clipboard.concealChange").length,
    ).toBe(2);
    await app.actions.invoke("clipboard.copy", {
        text: "common-relay://i/fixture#test-key.test-password",
    });
    expect(calls.find((c) => c.name === "clipboard.write")?.p.sensitive).toBe(
        true,
    );
    await app.dispose();
});
test("notification protocol metadata keeps seconds, remote keys and peer-scoped clearing", async () => {
    const { app, emit, calls } = harness();
    await app.model.ready;
    for (const peerId of ["phone-a", "phone-b"])
        await emit("lan.notification.received", {
            operation: "notif.post",
            peerId,
            messageId: peerId,
            notification: {
                notificationKey: "notice-key",
                packageName: "org.example.fixture",
                groupKey: "group",
                title: "Fixture",
                text: "Synthetic notification",
                postTime: 1700000000,
                isClearable: true,
            },
        });
    expect(app.model.state().notifications[0]?.date).toBe(1700000000000);
    await app.actions.invoke("notifications.dismissRemote", {
        id: "phone-a:notice-key",
    });
    expect(
        calls.find((c) => c.name === "lan.notification")?.p.payload
            .notificationKey,
    ).toBe("notice-key");
    await emit("lan.notification.received", {
        operation: "notif.clear",
        peerId: "phone-a",
        messageId: "clear",
        notification: {},
    });
    expect(app.model.state().notifications.length).toBe(1);
    expect(app.model.state().notifications[0]?.deviceId).toBe("phone-b");
    await app.dispose();
});
test("global navigation respects failed draft persistence and wordbook has its own route", async () => {
    const { app } = harness();
    await app.model.ready;
    app.actions.flushDrafts = async () => {
        throw Error("unsaved draft");
    };
    expect(await app.actions.navigate("devices")).toBe(false);
    expect(app.model.state().page).toBe("history");
    app.actions.flushDrafts = async () => {};
    expect(await app.actions.navigate("wordbook")).toBe(true);
    expect(app.model.state().page).toBe("words");
    expect(app.model.state().wordBookRequestVersion > 0).toBe(true);
    await app.dispose();
});

test("explicit screenshot overlay actions override quick capture settings", async () => {
    for (const action of ["copy", "save", "pin", "ocr", "share", "translate"]) {
        const { app, calls } = harness(action);
        await app.model.ready;
        await app.actions.invoke("capture.start", { mode: "region" });
        const expected = { copy: "clipboard.write", save: "capture.export", pin: "image.pin", ocr: "ocr.recognize", share: "image.share", translate: "image.ocrResult" }[action];
        expect(calls.some(call => call.name === expected)).toBe(true);
        if (action !== "copy") expect(calls.some(call => call.name === "clipboard.write")).toBe(false);
        expect(app.model.state().history.length).toBe(1);
        await app.dispose();
    }
});

test("editing a screenshot keeps the unredacted source out of history until final commit", async () => {
    const { app, calls } = harness("editor");
    await app.model.ready;
    await app.actions.saveSettings({ beautify: true });
    await app.actions.invoke("capture.start", { mode: "region" });
    expect(app.model.state().editorPath).toBe("/private/capture.png");
    expect(app.model.state().history.length).toBe(0);
    expect(calls.some(call => call.name === "history.ocr")).toBe(false);
    expect(calls.some(call => call.name === "image.render")).toBe(false);
    const result = await app.actions.invoke("image.commit", { path: "/private/final-redacted.png" });
    expect(result?.committed).toBe(true);
    expect(app.model.state().history[0]?.mediaPath).toBe("/private/final-redacted.png");
    await app.dispose();
});

test("screenshot translation opens the OCR result surface instead of writing an invisible word result", async () => {
    const { app, calls } = harness();
    await app.model.ready;
    await app.actions.invoke("capture.translate", { path: "/private/capture.png", target: "English" });
    const window = calls.find(call => call.name === "image.ocrResult");
    expect(window?.p.translate).toBe(true);
    expect(window?.p.target).toBe("English");
    await app.dispose();
});

test("selected region handoffs preserve global scroll bounds and local recording bounds", async () => {
    for (const action of ["scroll", "recording"]) {
        const { app, calls } = harness(action);
        await app.model.ready;
        await app.actions.invoke("capture.start", { mode:"region" });
        const call = calls.find(call => call.name === (action === "scroll" ? "capture.scroll" : "recording.start"));
        expect(call?.p.rect).toEqual(action === "scroll" ? {x:-900,y:150,width:400,height:300} : {x:300,y:50,width:400,height:300});
        if (action === "recording") {
            expect(call?.p.displayId).toBe(4);
            expect(app.model.state().history.length).toBe(0);
        } else expect(app.model.state().history[0]?.mediaPath).toBe("/private/scroll.png");
        await app.dispose();
    }
});

test("annotation overlays retain their display geometry and spanning windows keep the complete independent editor", async () => {
    for (const spanning of [false,true]) {
        const { app } = harness("annotate", spanning ? {selectionRect:{x:-900,y:150,width:1400,height:300},windowId:42} : {});
        await app.model.ready;
        await app.actions.invoke("capture.start", {mode:"region"});
        expect(app.model.state().editorPath).toBe("/private/capture.png");
        expect(!!app.model.state().editorCapture).toBe(!spanning);
        expect(app.model.state().history.length).toBe(0);
        await app.dispose();
    }
});

test("thumbnail edit actions route to the real editor and preserve an already active document", async () => {
    const { app, emit } = harness();
    await app.model.ready;
    await emit("image.action", {action:"edit",path:"/private/preview.png"});
    expect(app.model.state().editorPath).toBe("/private/preview.png");
    app.actions.set("editorActive", true);
    await emit("image.action", {action:"edit",path:"/private/second.png"});
    expect(app.model.state().editorPath).toBe("/private/preview.png");
    expect(app.model.state().message).toContain("请先完成或关闭");
    await app.dispose();
});

test("append capture preserves the scene, composes native outputs and leaves history untouched on success or cancel", async () => {
    for (const cancelled of [false,true]) {
        const {app,calls}=harness(undefined,{cancelled},{
            "image.render":()=>({path:"/private/baked.png"}),
            "image.compose":()=>({path:"/private/composed.png",width:800,height:600}),
        });
        await app.model.ready;
        app.actions.set("editorActive",true);
        const scene={imagePath:"/private/original.png",annotations:[{tool:"rectangle"}],effects:{beautify:true}};
        const result=await app.actions.invoke("editor.appendCapture",{scene,axis:"horizontal"});
        expect(calls.find(c=>c.name==="image.render")?.p).toEqual(scene);
        expect(calls.find(c=>c.name==="capture.screen")?.p.selectionOnly).toBe(true);
        if (cancelled) {expect(result?.cancelled).toBe(true);expect(calls.some(c=>c.name==="image.compose")).toBe(false);}
        else {expect(result?.path).toBe("/private/composed.png");expect(calls.find(c=>c.name==="image.compose")?.p.paths).toEqual(["/private/baked.png","/private/capture.png"]);}
        expect(app.model.state().history.length).toBe(0);
        expect(calls.some(c=>c.name==="clipboard.write")).toBe(false);
        expect(calls.some(c=>c.name==="image.releaseOutput"&&c.p.path==="/private/baked.png")).toBe(true);
        await app.dispose();
    }
});

test("image stamp sources enforce count and byte budgets and release only their own leases", async () => {
    for (const bytes of [1024*1024,5*1024*1024]) {
        let count=0;
        const {app,calls}=harness(undefined,{}, {
            "files.pick":()=>["/virtual/stamp.png"],"image.info":()=>({width:100,height:50,bytes}),
            "files.stageMedia":()=>({path:"/private/staged.png"}),"media.import":()=>({id:`media-${++count}`}),
            "media.lease":()=>({leaseId:`stamp-${count}`,path:`/private/stamp-${count}.png`}),
        });
        await app.model.ready;
        app.actions.set("editorActive",true);
        const limit=bytes===1024*1024?8:6;
        for(let i=0;i<limit;i++)expect((await app.actions.invoke("editor.importStamp"))?.bytes).toBe(bytes);
        expect(await app.actions.invoke("editor.importStamp")).toBe(undefined);
        expect(app.model.state().message).toContain(bytes===1024*1024?"8张":"32 MiB");
        await app.actions.invoke("editor.close");
        expect(calls.filter(c=>c.name==="media.release").length).toBe(limit);
        expect(calls.filter(c=>c.name==="media.abandonImport").length).toBe(limit+(bytes===1024*1024?0:1));
        await app.dispose();
    }
});

test("closing a document invalidates late stamp and compose requests without changing the replacement document", async () => {
    for (const operation of ["stamp","compose"]) {
        let reached!:()=>void, finish!:(value:any)=>void;
        const started=new Promise<void>(resolve=>reached=resolve), pending=new Promise<any>(resolve=>finish=resolve);
        const overrides:Record<string,(p:any)=>any>=operation==="stamp" ? {
            "files.pick":()=>["/virtual/stamp.png"],"files.stageMedia":()=>({path:"/private/staged.png"}),
            "image.info":()=>({width:10,height:10,bytes:100}),"media.import":()=>({id:"old-stamp"}),
            "media.lease":()=>{reached();return pending;},
        } : {"image.render":()=>({path:"/private/baked.png"}),"image.compose":()=>{reached();return pending;}};
        const {app,calls,emit}=harness(undefined,{},overrides);
        await app.model.ready;app.actions.set("editorActive",true);
        const request=app.actions.invoke(operation==="stamp"?"editor.importStamp":"editor.appendCapture",{scene:{imagePath:"/private/a.png"}});
        await started;
        await app.actions.invoke("editor.close");
        await emit("image.action",{action:"edit",path:"/private/b.png"});
        finish(operation==="stamp"?{leaseId:"late-stamp",path:"/private/late.png"}:{path:"/private/late-compose.png",width:100,height:100});
        expect((await request)?.cancelled).toBe(true);
        expect(app.model.state().editorPath).toBe("/private/b.png");
        expect(app.model.state().editorActive).toBe(true);
        if(operation==="stamp")expect(calls.some(c=>c.name==="media.release"&&c.p.leaseId==="late-stamp")).toBe(true);
        else expect(calls.some(c=>c.name==="image.releaseOutput"&&c.p.path==="/private/late-compose.png")).toBe(true);
        await app.dispose();
    }
});
