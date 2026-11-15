import AppKit
import Foundation
import Darwin

/// Only explicit structured metadata reaches disk. Params, response bodies and Error.description are forbidden.
final class DiagnosticLogWriter:@unchecked Sendable {
    let directory:URL
    private let queue=DispatchQueue(label:"dev.clipy.tsx.diagnostics",qos:.utility)
    private let day=DateFormatter()
    private let timestamp=ISO8601DateFormatter()
    private let fileLimit=5*1024*1024,totalLimit=50*1024*1024
    private let pendingLock=NSLock()
    private var pending=0
    private var dropped=0
    init(directory:URL){self.directory=directory;day.locale=Locale(identifier:"en_US_POSIX");day.timeZone = .current;day.dateFormat="yyyy-MM-dd";timestamp.timeZone = .current;timestamp.formatOptions=[.withInternetDateTime,.withFractionalSeconds]}
    func record(method:String,phase:String,errorCode:String?=nil,durationMs:Double?=nil,queued:Int?=nil){
        pendingLock.lock();guard pending<2048 else{dropped+=1;pendingLock.unlock();return};pending+=1;pendingLock.unlock()
        let method=Self.identifier(method),phase=Self.identifier(phase),code=errorCode.map(Self.identifier)
        queue.async{[self]in defer{pendingLock.lock();pending-=1;pendingLock.unlock()};do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let now=Date();var entry:[String:Any]=["timestamp":timestamp.string(from:now),"method":method,"phase":phase,"pid":ProcessInfo.processInfo.processIdentifier];if let code{entry["errorCode"]=code};if let durationMs,durationMs.isFinite{entry["durationMs"]=max(0,min(durationMs,86400000))};if let queued{entry["queued"]=max(0,min(queued,100000))};let bytes=try JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys])+Data([10]);let date=day.string(from:now),prefix="clipy-"+date+"-";let current=(try files()).filter{$0.lastPathComponent.hasPrefix(prefix)}.sorted{$0.lastPathComponent<$1.lastPathComponent}.last;var index=current.flatMap{Int($0.deletingPathExtension().lastPathComponent.split(separator:"-").last ?? "")} ?? 1;var target=current ?? directory.appendingPathComponent(prefix+String(format:"%06d",index)+".log");let size=(try? target.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0;if size+bytes.count>fileLimit{index+=1;target=directory.appendingPathComponent(prefix+String(format:"%06d",index)+".log")};if !FileManager.default.fileExists(atPath:target.path){guard FileManager.default.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:0o600])else{return}};let handle=try FileHandle(forWritingTo:target);defer{try? handle.close()};try handle.seekToEnd();try handle.write(contentsOf:bytes);try prune(now)}catch{/* Logging failure must not recurse or turn a business ACK into failure. */}}
    }
    static func identifier(_ value:String)->String{let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-");return String(value.unicodeScalars.prefix(96).map{allowed.contains($0) ? Character(String($0)):"_"})}
    func flush(){queue.sync{}}
    func recent()throws->String{try queue.sync{guard let last=try files().sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).last else{return "暂无诊断日志"};let input=try FileHandle(forReadingFrom:last);defer{try? input.close()};let size=try input.seekToEnd(),offset=size>512*1024 ? size-512*1024:0;try input.seek(toOffset:offset);var data=try input.readToEnd() ?? Data();if offset>0,let newline=data.firstIndex(of:10){data=Data(data.dropFirst(newline+1))};return String(data:data,encoding:.utf8) ?? "无法读取日志编码"}}
    func summary()throws->[String:Any]{try queue.sync{let items=try files();let total=try items.reduce(0){$0+(try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)};pendingLock.lock();let lost=dropped;pendingLock.unlock();return ["droppedMetadataRecords":lost,"queueLimit":2048,"files":items.count,"bytes":total,"retentionDays":7,"fileLimitBytes":fileLimit,"totalLimitBytes":totalLimit]}}
    private func files()throws->[URL]{guard FileManager.default.fileExists(atPath:directory.path)else{return []};return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey],options:[.skipsHiddenFiles]).filter{$0.lastPathComponent.hasPrefix("clipy-")&&$0.pathExtension=="log"}}
    private func prune(_ now:Date)throws{let oldest=Calendar.current.date(byAdding:.day,value:-6,to:Calendar.current.startOfDay(for:now)) ?? now.addingTimeInterval(-6*86400);var kept:[(URL,Int)]=[];for file in try files(){let parts=file.lastPathComponent.split(separator:"-");let date=parts.count>=4 ? day.date(from:parts[1...3].joined(separator:"-")):nil;if let date,date<oldest{try? FileManager.default.removeItem(at:file);continue};kept.append((file,try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0))};kept.sort{$0.0.lastPathComponent<$1.0.lastPathComponent};var total=kept.reduce(0){$0+$1.1};for(file,size)in kept where total>totalLimit{try FileManager.default.removeItem(at:file);total-=size}}
}

@MainActor final class DiagnosticsService {
    let logger:DiagnosticLogWriter
    var window:NSWindow?
    init(root:URL){logger=DiagnosticLogWriter(directory:root.appendingPathComponent("logs",isDirectory:true));logger.record(method:"system.launch",phase:"start")}
    func record(method:String,phase:String,errorCode:String?=nil,durationMs:Double?=nil,queued:Int?=nil){logger.record(method:method,phase:phase,errorCode:errorCode,durationMs:durationMs,queued:queued)}
    func close(){record(method:"system.close",phase:"complete");logger.flush();window?.orderOut(nil);window?.close();window=nil}
    func invoke(_ method:String,_ p:[String:Any])async throws->Any{
        switch method{
        case "logs.reveal":logger.flush();try FileManager.default.createDirectory(at:logger.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);NSWorkspace.shared.open(logger.directory);return true
        case "logs.show":logger.flush();let text=try logger.recent();show(text,title:"Clipy 诊断日志");return ["shown":true,"characters":text.count]
        case "system.diagnostics":let info=try information();let data=try JSONSerialization.data(withJSONObject:info,options:[.prettyPrinted,.sortedKeys]);show(String(data:data,encoding:.utf8) ?? "",title:"Clipy 系统诊断");return info
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"未知诊断接口")
        }
    }
    func information()throws->[String:Any]{var info:[String:Any]=["os":ProcessInfo.processInfo.operatingSystemVersionString,"helperPid":ProcessInfo.processInfo.processIdentifier,"systemUptimeSeconds":Int(ProcessInfo.processInfo.systemUptime),"appVersion":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "preview","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown","logging":try logger.summary(),"redaction":"No clipboard, notification body, API key, login password, invitation URL or request params are logged"]
        #if arch(arm64)
        info["architecture"]="arm64"
        #else
        info["architecture"]="x86_64"
        #endif
        var vm=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let result=withUnsafeMutablePointer(to:&vm){pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}};if result==KERN_SUCCESS{info["helperPhysicalFootprintBytes"]=vm.phys_footprint};return info
    }
    private func show(_ value:String,title:String){if let window{window.orderOut(nil);window.close()};let window=NSWindow(contentRect:CGRect(x:0,y:0,width:820,height:560),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false);window.title=title;window.isReleasedWhenClosed=false;window.minSize=CGSize(width:520,height:300);let scroll=NSScrollView(frame:window.contentView!.bounds);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;let text=NSTextView(frame:scroll.bounds);text.isEditable=false;text.isSelectable=true;text.font=NSFont.userFixedPitchFont(ofSize:12) ?? NSFont.systemFont(ofSize:12);text.textContainerInset=CGSize(width:18,height:18);text.backgroundColor = .textBackgroundColor;text.textColor = .textColor;text.string=value;text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.textContainer?.widthTracksTextView=true;scroll.documentView=text;window.contentView=scroll;self.window=window;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
}
