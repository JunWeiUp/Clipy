import Foundation
import Darwin
let executable = URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
let directory = executable.deletingLastPathComponent().path
let runtime = executable.path + ".runtime"
setenv("CLIPY_NSH_HELPER", "clipy-native", 1)
setenv("PATH", directory + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"), 1)
let values = [runtime] + Array(CommandLine.arguments.dropFirst())
let pointers = values.map { strdup($0) } + [nil]
_ = pointers.withUnsafeBufferPointer { buffer in execv(runtime, buffer.baseAddress!) }
fputs("Unable to start packaged NSH runtime\n",stderr)
exit(127)
