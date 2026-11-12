import Darwin
import Foundation

/// 常驻菜单栏应用的内存调优：让释放的大块内存（截图时的整屏位图、PNG 编码缓冲）
/// 立刻还给系统。
///
/// macOS 26 的 libmalloc 会把释放的大块（MALLOC_LARGE）留在缓存里几分钟；
/// `malloc_zone_pressure_relief` 对它们也返回 0。实测每次截图后 footprint 因此
/// 多出 100–200 MB，并随截图次数叠加。`MallocLargeCache=0` 只在进程启动时
/// 由 libmalloc 读取，所以：
/// - 正常启动（Finder / 登录项 / `open`）由 Info.plist 的 `LSEnvironment` 设置；
/// - 直接执行二进制等未带该变量的启动方式，在任何框架初始化前带上变量重新 exec 自身一次。
enum MallocTuning {
    static let variable = "MallocLargeCache"

    static func ensureLargeAllocationsReturnToSystem() {
        guard getenv(variable) == nil else { return }
        setenv(variable, "0", 1)
        guard let path = Bundle.main.executablePath else { return }
        // 失败时继续以默认分配策略运行，不影响功能。
        execv(path, CommandLine.unsafeArgv)
    }
}
