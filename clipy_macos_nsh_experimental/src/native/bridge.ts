import process, { type ChildProcess } from "process";

export interface NativeTransport {
    write(line: string): void;
    end(): void;
    kill(): void;
    onLine(handler: (line: string) => void): void;
    onExit(handler: () => void): void;
}
export type NativeEventHandler = (payload: any) => void;
export class NativeError extends Error {
    constructor(
        public code: string,
        message: string,
    ) {
        super(message);
        this.name = "NativeError";
    }
}

/** One private stdio channel. Bounded pending requests; no sockets or polling. */
export class NativeBridge {
    private transport: NativeTransport | null = null;
    private pending = new Map<
        string,
        {
            resolve: (value: any) => void;
            reject: (error: Error) => void;
            timer: ReturnType<typeof setTimeout>;
            disposeAbort: () => void;
        }
    >();
    private listeners = new Map<string, Set<NativeEventHandler>>();
    private sequence = 0;
    private closed = false;
    private startupError: NativeError | null = null;
    constructor(private launch: () => NativeTransport = launchHelper) {}

    private connect() {
        if (this.closed) throw new NativeError("CLOSED", "系统服务已关闭");
        if (this.transport) return this.transport;
        this.startupError = null;
        const transport = this.launch();
        this.transport = transport;
        transport.onLine((line) => this.receive(line));
        transport.onExit(() => {
            if (this.transport !== transport) return;
            this.transport = null;
            this.rejectAll(
                this.startupError ||
                    new NativeError(
                        "HELPER_EXITED",
                        "系统服务已退出，请重新打开客户端",
                    ),
            );
            this.emit("native.disconnected", {});
        });
        return transport;
    }

    call<T = any>(
        method: string,
        params: unknown = {},
        timeoutMs = 30000,
        signal?: AbortSignal,
    ): Promise<T> {
        if (signal?.aborted) return Promise.reject(new NativeError("CANCELLED", "操作已取消"));
        if (!/^[a-z][a-zA-Z0-9_.]*$/.test(method))
            return Promise.reject(
                new NativeError("INVALID_METHOD", "系统操作名称无效"),
            );
        if (this.pending.size >= 32)
            return Promise.reject(
                new NativeError("BUSY", "待处理操作过多，请稍后再试"),
            );
        let transport: NativeTransport;
        try {
            transport = this.connect();
        } catch (error) {
            return Promise.reject(error);
        }
        const id = String(++this.sequence);
        return new Promise<T>((resolve, reject) => {
            const cancelNative = () => { try { transport.write(JSON.stringify({id:`cancel-${id}`,method:"task.cancel",params:{requestId:id}})+"\n"); } catch {} };
            const abort = () => {
                const pending = this.pending.get(id);
                if (!pending) return;
                this.pending.delete(id);clearTimeout(pending.timer);pending.disposeAbort();
                reject(new NativeError("CANCELLED", "操作已取消"));cancelNative();
            };
            const disposeAbort = () => signal?.removeEventListener("abort",abort);
            const timer = setTimeout(() => {
                this.pending.delete(id);disposeAbort();
                reject(new NativeError("TIMEOUT", "操作超时，结果尚未确认"));
                try {
                    transport.write(
                        JSON.stringify({
                            id: `cancel-${id}`,
                            method: "task.cancel",
                            params: { requestId: id },
                        }) + "\n",
                    );
                } catch {}
            }, timeoutMs);
            this.pending.set(id, { resolve, reject, timer, disposeAbort });
            signal?.addEventListener("abort",abort,{once:true});
            if (signal?.aborted) { abort(); return; }
            try {
                const line = JSON.stringify({ id, method, params });
                if (line.length > 524288)
                    throw new NativeError(
                        "TOO_LARGE",
                        "操作内容超过单次处理上限，请缩小范围后重试",
                    );
                transport.write(line + "\n");
            } catch (error) {
                clearTimeout(timer);disposeAbort();
                this.pending.delete(id);
                reject(error);
            }
        });
    }

    on(event: string, handler: NativeEventHandler): () => void {
        let entries = this.listeners.get(event);
        if (!entries) {
            entries = new Set();
            this.listeners.set(event, entries);
        }
        entries.add(handler);
        return () => {
            entries!.delete(handler);
            if (!entries!.size) this.listeners.delete(event);
        };
    }
    private emit(event: string, payload: unknown) {
        for (const handler of this.listeners.get(event) ?? []) {
            try {
                handler(payload);
            } catch (error) {
                console.error("Native event handler failed", event);
            }
        }
    }
    private receive(line: string) {
        if (line.length > 4 * 1048576) {
            this.close();
            return;
        }
        let reply: any;
        try {
            reply = JSON.parse(line);
        } catch {
            console.error("Invalid native response");
            return;
        }
        if (typeof reply.event === "string") {
            if (reply.event === "native.startupError") {
                this.startupError = new NativeError(
                    reply.payload?.code || "STARTUP_ERROR",
                    reply.payload?.message || "系统服务启动失败",
                );
                this.rejectAll(this.startupError);
            }
            this.emit(reply.event, reply.payload);
            return;
        }
        const entry = this.pending.get(String(reply.id));
        if (!entry) return;
        this.pending.delete(String(reply.id));
        clearTimeout(entry.timer);entry.disposeAbort();
        if (reply.ok === true) entry.resolve(reply.result);
        else
            entry.reject(
                new NativeError(
                    reply.error?.code ?? "NATIVE_ERROR",
                    reply.error?.message ?? "系统操作失败",
                ),
            );
    }
    private rejectAll(error: Error) {
        for (const entry of this.pending.values()) {
            clearTimeout(entry.timer);entry.disposeAbort();
            entry.reject(error);
        }
        this.pending.clear();
    }
    close() {
        if (this.closed) return;
        this.closed = true;
        const transport = this.transport;
        this.transport = null;
        this.rejectAll(new NativeError("CLOSED", "系统服务已关闭"));
        this.listeners.clear();
        if (transport) {
            try {
                transport.end();
            } finally {
                transport.kill();
            }
        }
    }
}

function launchHelper(): NativeTransport {
    const helper = process.env.CLIPY_NSH_HELPER;
    if (!helper)
        throw new NativeError(
            "HELPER_UNAVAILABLE",
            "系统服务未启动，请通过 clipy_macos_nsh_experimental/scripts/run_macos.sh 打开客户端",
        );
    const child: ChildProcess = process.spawn(
        helper,
        ["--data-dir", `${process.dataDir}/native`],
        { stdin: "pipe", lines: true },
    );
    return {
        write: (line) => child.write(line),
        end: () => child.end(),
        kill: () => child.kill(),
        onLine: (fn) => {
            child.on("stdout", fn);
        },
        onExit: (fn) => {
            child.on("exit", fn);
        },
    };
}
