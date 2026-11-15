import Foundation
import Darwin

/// Classic ZIP stored-only snapshots. No external unzip process, compression or link traversal.
enum FolderTransferService {
    static let maximum=512*1024*1024
    struct Entry{let name:String;let directory:Bool;let size:Int;let crc:UInt32;let mode:UInt32;let offset:Int}
    private static let table:[UInt32]=(0..<256).map{value in var c=UInt32(value);for _ in 0..<8{c=(c&1)==1 ? 0xedb88320^(c>>1):c>>1};return c}
    private static func crc(_ bytes:Data,_ initial:UInt32=0xffffffff)->UInt32{var c=initial;for b in bytes{c=table[Int((c^UInt32(b))&255)]^(c>>8)};return c}
    private static func error(_ text:String)->BridgeFailure{BridgeFailure(code:"FOLDER_INVALID",message:text)}
    static func archive(_ original:URL,temporaryDirectory:URL)throws->URL{
        guard try FileManager.default.attributesOfItem(atPath:original.path)[.type] as? FileAttributeType == .typeDirectory else{throw error("不能打包符号链接或特殊文件")};let source=original.standardizedFileURL.resolvingSymlinksInPath()
        let root=source.lastPathComponent;try validateName(root)
        let rootAttributes=try FileManager.default.attributesOfItem(atPath:source.path);guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else{throw error("仅支持普通文件夹")}
        var urls=[source];var enumerationError:Error?
        guard let walker=FileManager.default.enumerator(at:source,includingPropertiesForKeys:nil,options:[],errorHandler:{_,failure in enumerationError=failure;return false}) else{throw error("无法遍历文件夹")}
        for case let url as URL in walker{urls.append(url);guard urls.count<=10000 else{throw error("文件夹最多10000项")}}
        if let enumerationError{throw enumerationError}
        urls=urls.sorted{a,b in a.pathComponents.count==b.pathComponents.count ? a.path<b.path:a.pathComponents.count<b.pathComponents.count}
        var metadata:[(url:URL,name:String,directory:Bool,size:Int,mode:UInt32)]=[];var total=22
        for url in urls{
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path);let type=attributes[.type] as? FileAttributeType;guard type == .typeDirectory || type == .typeRegular else{throw error("文件夹不能包含符号链接或特殊文件")}
            let normalized=url.standardizedFileURL.resolvingSymlinksInPath();guard normalized.path==source.path||normalized.path.hasPrefix(source.path+"/")else{throw error("文件超出源目录")};let directory=type == .typeDirectory;let suffix=normalized.path==source.path ? "":String(normalized.path.dropFirst(source.path.count+1));let name=root+(suffix.isEmpty ? "":"/"+suffix)+(directory ? "/":"");try validatePath(name)
            let size=directory ? 0:(attributes[.size] as? NSNumber)?.intValue ?? 0;guard size>=0 else{throw error("文件大小无效")}
            total+=30+46+name.utf8.count*2+size;guard total<=maximum else{throw error("文件夹含ZIP开销不能超过512 MiB")}
            let permissions=(attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? (directory ? 0o755:0o644);metadata.append((url,name,directory,size,(directory ? 0o040000:0o100000)|(permissions&0o777)))
        }
        try FileManager.default.createDirectory(at:temporaryDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let target=temporaryDirectory.appendingPathComponent(UUID().uuidString+".zip")
        guard FileManager.default.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:0o600])else{throw error("无法创建文件夹快照")};let output=try FileHandle(forWritingTo:target);var complete=false;defer{try? output.close();if !complete{try? FileManager.default.removeItem(at:target)}}
        var entries:[Entry]=[];var offset=0
        for item in metadata{
            var checksum:UInt32=0
            if !item.directory{let input=try openRegular(item.url);defer{try? input.close()};var count=0,c:UInt32=0xffffffff;while let data=try input.read(upToCount:65536),!data.isEmpty{count+=data.count;guard count<=item.size else{throw error("文件在快照期间变化")};c=crc(data,c)};guard count==item.size else{throw error("文件在快照期间变化")};checksum=c^0xffffffff}
            let name=Data(item.name.utf8);var header=Data();header.u32(0x04034b50);header.u16(20);header.u16(0x800);header.u16(0);header.u16(0);header.u16(0x21);header.u32(checksum);header.u32(UInt32(item.size));header.u32(UInt32(item.size));header.u16(UInt16(name.count));header.u16(0);header.append(name);try output.write(contentsOf:header)
            if !item.directory{let input=try openRegular(item.url);defer{try? input.close()};var count=0,c:UInt32=0xffffffff;while let data=try input.read(upToCount:65536),!data.isEmpty{count+=data.count;guard count<=item.size else{throw error("文件在快照期间变化")};c=crc(data,c);try output.write(contentsOf:data)};guard count==item.size,c^0xffffffff==checksum else{throw error("文件在快照期间变化")}}
            entries.append(Entry(name:item.name,directory:item.directory,size:item.size,crc:checksum,mode:item.mode,offset:offset));offset+=header.count+item.size
        }
        let centralOffset=offset
        for entry in entries{let name=Data(entry.name.utf8);var h=Data();h.u32(0x02014b50);h.u16(0x0314);h.u16(20);h.u16(0x800);h.u16(0);h.u16(0);h.u16(0x21);h.u32(entry.crc);h.u32(UInt32(entry.size));h.u32(UInt32(entry.size));h.u16(UInt16(name.count));h.u16(0);h.u16(0);h.u16(0);h.u16(0);h.u32(entry.mode<<16);h.u32(UInt32(entry.offset));h.append(name);try output.write(contentsOf:h);offset+=h.count}
        var end=Data();end.u32(0x06054b50);end.u16(0);end.u16(0);end.u16(UInt16(entries.count));end.u16(UInt16(entries.count));end.u32(UInt32(offset-centralOffset));end.u32(UInt32(centralOffset));end.u16(0);try output.write(contentsOf:end);try output.synchronize();complete=true;return target
    }
    static func extract(_ source:URL,into directory:URL,expectedName:String)throws->URL{
        try validateName(expectedName);let input=try openRegular(source);defer{try? input.close()};let size=try input.seekToEnd();guard size>=22,size<=UInt64(maximum)else{throw error("ZIP大小无效")}
        let end=try read(input,at:Int(size)-22,count:22);guard end.r32(0)==0x06054b50,end.r16(4)==0,end.r16(6)==0,end.r16(20)==0,end.r16(8)==end.r16(10)else{throw error("只接受无注释单卷ZIP")};let count=Int(end.r16(8)),centralSize=Int(end.r32(12)),centralOffset=Int(end.r32(16));guard count>0,count<=10000,centralOffset+centralSize==Int(size)-22 else{throw error("ZIP索引无效")}
        var entries:[Entry]=[],cursor=centralOffset,nextLocal=0;var aliases=Set<String>(),directories=Set<String>()
        for _ in 0..<count{
            let h=try read(input,at:cursor,count:46);guard h.r32(0)==0x02014b50,h.r16(4)==0x0314,h.r16(6)==20,h.r16(8)==0x800,h.r16(10)==0,h.r16(30)==0,h.r16(32)==0,h.r16(34)==0,h.r32(20)==h.r32(24)else{throw error("ZIP包含不支持的压缩/扩展/数据描述")}
            let nameSize=Int(h.r16(28));guard nameSize>0,nameSize<=4096,cursor+46+nameSize<=centralOffset+centralSize else{throw error("ZIP路径长度无效")};let nameData=try read(input,at:cursor+46,count:nameSize);guard let name=String(data:nameData,encoding:.utf8)else{throw error("ZIP路径必须为UTF-8")};try validatePath(name)
            let isDirectory=name.hasSuffix("/"),path=isDirectory ? String(name.dropLast()):name;let alias=path.precomposedStringWithCanonicalMapping.lowercased();guard aliases.insert(alias).inserted else{throw error("ZIP包含重名或别名路径")}
            guard (entries.isEmpty&&path==expectedName&&isDirectory)||(!entries.isEmpty&&path.hasPrefix(expectedName+"/"))else{throw error("ZIP根目录与文件夹元数据不一致")}
            let components=path.split(separator:"/");if components.count>1{guard directories.contains(components.dropLast().joined(separator:"/"))else{throw error("ZIP父目录必须在子项之前")}};if isDirectory{directories.insert(path)}
            let mode=h.r32(38)>>16,type=mode&0o170000;guard type==(isDirectory ? 0o040000:0o100000)else{throw error("ZIP拒绝链接和特殊文件")}
            let bytes=Int(h.r32(24)),local=Int(h.r32(42));guard local==nextLocal,(!isDirectory||bytes==0),local+30+nameSize+bytes<=centralOffset else{throw error("ZIP数据区重叠、缺失或越界")}
            let localHeader=try read(input,at:local,count:30);guard localHeader.r32(0)==0x04034b50,localHeader.r16(4)==20,localHeader.r16(6)==0x800,localHeader.r16(8)==0,localHeader.r32(14)==h.r32(16),localHeader.r32(18)==h.r32(20),localHeader.r32(22)==h.r32(24),localHeader.r16(26)==UInt16(nameSize),localHeader.r16(28)==0,try read(input,at:local+30,count:nameSize)==nameData else{throw error("ZIP本地头和索引不一致")}
            entries.append(Entry(name:name,directory:isDirectory,size:bytes,crc:h.r32(16),mode:mode,offset:local+30+nameSize));nextLocal=local+30+nameSize+bytes;cursor+=46+nameSize
        }
        guard cursor==centralOffset+centralSize,nextLocal==centralOffset else{throw error("ZIP含未索引数据")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let staging=directory.appendingPathComponent(".folder-"+UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:staging)}
        for entry in entries{let path=entry.directory ? String(entry.name.dropLast()):entry.name;let target=staging.appendingPathComponent(path,isDirectory:entry.directory)
            if entry.directory{try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);guard entry.crc==0 else{throw error("空目录CRC无效")}}
            else{let fd=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw error("文件目标已存在或不可写")};let output=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? output.close()};try input.seek(toOffset:UInt64(entry.offset));var remaining=entry.size,c:UInt32=0xffffffff;while remaining>0{guard let data=try input.read(upToCount:min(65536,remaining)),!data.isEmpty else{throw error("ZIP数据被截断")};c=crc(data,c);try output.write(contentsOf:data);remaining-=data.count};guard c^0xffffffff==entry.crc else{throw error("ZIP内容CRC校验失败")};try output.synchronize();try FileManager.default.setAttributes([.posixPermissions:entry.mode&0o777],ofItemAtPath:target.path)}
        }
        // Apply directory permissions only after all children are written.
        for entry in entries.reversed() where entry.directory{try FileManager.default.setAttributes([.posixPermissions:entry.mode&0o777],ofItemAtPath:staging.appendingPathComponent(String(entry.name.dropLast())).path)}
        let root=staging.appendingPathComponent(expectedName,isDirectory:true);var suffix=1
        while suffix<10000{let name=suffix==1 ? expectedName:"\(expectedName) (\(suffix))";let destination=directory.appendingPathComponent(name,isDirectory:true);if FileManager.default.fileExists(atPath:destination.path){suffix+=1;continue};do{try FileManager.default.moveItem(at:root,to:destination);return destination}catch{if FileManager.default.fileExists(atPath:destination.path){suffix+=1;continue};throw error}}
        throw error("同名文件夹过多")
    }
    private static func validateName(_ name:String)throws{guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\\"),!name.contains(":"),!name.contains("\0"),name.utf8.count<=255 else{throw error("文件夹名称无效")}}
    private static func validatePath(_ name:String)throws{let value=name.hasSuffix("/") ? String(name.dropLast()):name;let parts=value.split(separator:"/",omittingEmptySubsequences:false);guard name.utf8.count<=4096,parts.count<=128,!parts.isEmpty else{throw error("ZIP路径超限")};for part in parts{try validateName(String(part))}}
    private static func openRegular(_ url:URL)throws->FileHandle{let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw error("无法读取文件，符号链接不允许")};var info=stat();guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG else{_ = Darwin.close(fd);throw error("仅允许普通文件")};return FileHandle(fileDescriptor:fd,closeOnDealloc:true)}
    private static func read(_ input:FileHandle,at offset:Int,count:Int)throws->Data{guard offset>=0,count>=0 else{throw error("ZIP位置无效")};try input.seek(toOffset:UInt64(offset));guard let data=try input.read(upToCount:count),data.count==count else{throw error("ZIP被截断")};return data}
}
private extension Data{
 mutating func u16(_ value:UInt16){append(UInt8(value&255));append(UInt8((value>>8)&255))}
 mutating func u32(_ value:UInt32){u16(UInt16(value&65535));u16(UInt16((value>>16)&65535))}
 func r16(_ offset:Int)->UInt16{UInt16(self[startIndex+offset])|(UInt16(self[startIndex+offset+1])<<8)}
 func r32(_ offset:Int)->UInt32{UInt32(r16(offset))|(UInt32(r16(offset+2))<<16)}
}
