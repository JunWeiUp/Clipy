# Mac 端崩溃捕获加固：补 POSIX signal 捕获

## 背景与根因

应用"又自己崩溃了"，但 `~/Library/Logs/ClipyClone/` 自家日志和 `~/Library/Logs/DiagnosticReports/` 系统崩溃报告里今天都查不到记录。

**根因**：当前崩溃捕获只装了 `NSSetUncaughtExceptionHandler`（`LogManager.swift:200-207`），它**只抓 ObjC `NSException`**。全树没有任何 `signal()`/`sigaction()`。信号型崩溃（SIGABRT/SIGSEGV/SIGBUS/SIGFPE/SIGILL）绕过 handler，进程被直接终止，日志来不及落盘。这与 08-02 那批 TCC 崩溃（`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` 投递 SIGABRT）"自家日志同样无痕迹"的现象完全吻合——历史已多次印证。

另外审计确认 Info.plist 隐私键无缺失（`build_macos_app.sh:119-126` 的 4 个键覆盖全部被调用的隐私 API），排除"缺键 SIGABRT"。

## 本次修复范围

经审计，Explore 报的 3 个嫌疑点实际防御都已到位，**真正修复 = 补 signal 捕获**：
- GifskiExporter SIGBUS → 发生在**外挂 gifski 子进程**（`GifskiExporter.swift:106` `Process.run()`），父进程不崩。
- SyncManager drainBuffer 裸指针 → 有 `count >= 4` guard + 值类型拷贝（`SyncManager.swift:809,824`），逻辑安全。
- RecordingEngine `screenID!` → 有 `screenID != nil &&` 短路保护，安全。

## 实施步骤

### A. 核心：async-signal-safe 的 signal 崩溃捕获（`LogManager.swift`）

在 `CrashReporter` 里扩展，**保留现有 NSException handler 不动**，新增信号捕获：

1. **`install()` 里注册 sigaction**：SIGABRT、SIGSEGV、SIGBUS、SIGFPE、SIGILL → 自定义 handler；SIGPIPE → `SIG_IGN`（socket 对端关闭的正常情况不能当崩溃，否则同步断开会误崩）。
2. **预缓存日志路径**：install 时（主上下文）算好 `LogManager.currentLogFile.path`，用 `strdup` 存成 `static var crashLogPath: UnsafeMutablePointer<CChar>?`（进程即死，不释放）。
3. **signal handler 用 `@convention(c)` 闭包**，只调一个 `writeSignalTrace(_:)` 静态函数，内部严格只用 async-signal-safe 的 POSIX 调用：
   - `open(path, O_WRONLY|O_CREAT|O_APPEND, 0644)` 打开当天日志（与正常日志同文件）。
   - `time`/`ctime_r` 写粗时间戳 + 信号名（switch 返回 string literal，静态存储安全）。
   - `backtrace` + `backtrace_symbols_fd(_, _, fd)` 直接把调用栈写进 fd（这两函数 macOS 文档确认为 async-signal-safe）。
   - `fsync` + `close`。
   - **绝不复用 `logFatalSynchronously`**（它用 `bufferQueue.sync`/`DateFormatter`/`FileHandle.synchronize()`，全都不 signal-safe，挂上来会死锁或二次崩溃）。
4. **写完让系统生成 .ips**（用户已确认要）：handler 末尾 `signal(sig, SIG_DFL)` 恢复默认处理 + `raise(sig)` 重新投递 → 走默认 abort 路径 → `ReportCrash` 生成 `.ips` + 系统"意外退出"对话框，拿到完整机器栈。

技术实现细节（用 `import Darwin` 拿到 `sigaction`/`sigemptyset`/`open`/`write`/`fsync`/`close`/`backtrace`/`backtrace_symbols_fd`/`raise`/`time`/`ctime_r`/`strdup`；`sigaction.__sigaction_u.__sa_handler` 赋 `@convention(c)` 闭包；backtrace 用栈上 `[UnsafeMutableRawPointer?](repeating:nil, count:64)` 数组）。

### B. 顺手加固（最小有价值集合，诚实评估后仅 1 项）

审计发现代码整体防御良好，加固空间有限。做 1 项有边际价值、零风险的改进：

- **SyncManager.drainBuffer（`SyncManager.swift:813-815`）**：`raw.load(as: UInt32.self)` → `raw.loadUnaligned(as: UInt32.self)`。明确无对齐假设语义，防极端情况下对齐相关 trap。已有 `count >= 4` guard 保证不越界。

（GifskiExporter / RecordingEngine 经审计防御已到位，不强改，避免无价值改动引入风险。）

### C. 验证

1. `proxy` + `bash build_macos_app.sh` 编译通过（EXIT 0）。
2. 可选：临时在 `applicationDidFinishLaunching` 末尾插一行 `raise(SIGABRT)`（验证用，验证后立即删），跑一次确认：① 当天日志追加出 `[FATAL] signal SIGABRT ...` + backtrace 栈；② `~/Library/Logs/DiagnosticReports/` 生成本 app 的 `.ips`。验证完毕删除测试代码。

## 修复后的效果

下次再崩溃（无论 NSException 还是 signal），都会在自家日志留下 `[FATAL]` 标记 + 调用栈，且系统会生成 `.ips` 崩溃报告——届时能精确定位到具体 file:line 和触发模块，不必再"查不到痕迹"。

## 不在本次范围

- 不动 Info.plist（已确认键齐全）。
- 不改 NotificationManager.swift 的未提交改动（已确认安全，与崩溃无关）。
- 不重构 gifski / 录屏引擎（子进程崩溃不影响主进程）。