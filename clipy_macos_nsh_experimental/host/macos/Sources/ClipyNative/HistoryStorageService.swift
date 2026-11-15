import Foundation
import SQLite3
import CryptoKit
import Security
import Vision
import Darwin
import MachO

/// SQLite snapshots and managed media. No production storage path or identity is ever consulted.
@MainActor final class HistoryStorageService {
    private let root:URL
    private let mediaRoot:URL
    private let leaseRoot:URL
    private let authorizePath:(String)->Bool
    private var database:OpaquePointer?
    private var encryption=false
    private var leases:[String:(URL,Date)]=[:]
    private var leaseMedia:[String:String]=[:]
    private var importPins=Set<String>()
    private let sessionId=UUID().uuidString
    private var gcTask:Task<Void,Never>?
    private let gcGrace:TimeInterval = ProcessInfo.processInfo.environment["CLIPY_STORAGE_TEST"]=="1" ? 0.2:30
    private var reads:[String:(Data,Date)]=[:]
    private struct WriteStage{let key:String;let size:Int;var bytes=Data();let date=Date()}
    private var writes:[String:WriteStage]=[:]

    private var workers:[String:Process]=[:]
    private var generation=0
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private let keyAccount:String
    init(root:URL,authorizePath:@escaping(String)->Bool={_ in false})throws{
        self.root=root;self.authorizePath=authorizePath;mediaRoot=root.appendingPathComponent("media",isDirectory:true);leaseRoot=root.appendingPathComponent("preview-leases",isDirectory:true);keyAccount=SHA256.hash(data:Data(root.resolvingSymlinksInPath().path.utf8)).map{String(format:"%02x",$0)}.joined()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try FileManager.default.createDirectory(at:mediaRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try? FileManager.default.removeItem(at:leaseRoot);try FileManager.default.createDirectory(at:leaseRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open_v2(root.appendingPathComponent("history.sqlite").path,&database,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{throw Self.error("无法打开历史数据库")}
        var initialized=false;defer{if !initialized,let database{sqlite3_close(database);self.database=nil}}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("history.sqlite").path);sqlite3_busy_timeout(database,3000);try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY,v BLOB NOT NULL,e INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT NOT NULL); CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY,path TEXT NOT NULL,ext TEXT NOT NULL,size INTEGER NOT NULL,e INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS ocr(id TEXT PRIMARY KEY,v BLOB NOT NULL,e INTEGER NOT NULL);")
        try rows("SELECT v FROM meta WHERE k='encrypted'"){row in self.encryption=sqlite3_column_text(row,0).map{String(cString:$0)}=="1"}
        var hasSHA=false;try rows("PRAGMA table_info(media)"){if String(cString:sqlite3_column_text($0,1))=="sha"{hasSHA=true}};if !hasSHA{try execute("ALTER TABLE media ADD COLUMN sha TEXT NOT NULL DEFAULT ''")};var mediaColumns=Set<String>();try rows("PRAGMA table_info(media)"){mediaColumns.insert(String(cString:sqlite3_column_text($0,1)))};if !mediaColumns.contains("committed"){try execute("ALTER TABLE media ADD COLUMN committed INTEGER NOT NULL DEFAULT 1")};if !mediaColumns.contains("owner"){try execute("ALTER TABLE media ADD COLUMN owner TEXT NOT NULL DEFAULT ''")};if !mediaColumns.contains("deletedAt"){try execute("ALTER TABLE media ADD COLUMN deletedAt REAL")};var mismatched=0;for table in ["kv","media","ocr"]{try rows("SELECT count(*) FROM \(table) WHERE e NOT IN (0,1) OR e!=\(encryption ? 1:0)"){mismatched+=Int(sqlite3_column_int($0,0))}};guard mismatched==0 else{throw Self.error("历史加密模式与记录不一致，原数据保留")};if encryption{_ = try key(create:false)};try cleanOrphans();initialized=true
    }
    deinit{if let database{sqlite3_close(database)}}
    func close(){gcTask?.cancel();gcTask=nil;reads.removeAll();writes.removeAll();cancelOCR();for(_,lease)in leases{try? FileManager.default.removeItem(at:lease.0)};leases.removeAll();leaseMedia.removeAll();importPins.removeAll();if let database{sqlite3_close(database);self.database=nil}}
    func invoke(_ method:String,_ p:[String:Any])async throws->Any{
        for(id,item)in reads where Date().timeIntervalSince(item.1)>300{reads.removeValue(forKey:id)};for(id,item)in writes where Date().timeIntervalSince(item.date)>300{writes.removeValue(forKey:id)}
        switch method{
        case "storage.read.begin":
            guard reads.count<4 else{throw Self.error("并发读取过多")};guard let text=try get(try string(p,"key")) else{return ["exists":false,"size":0]};let bytes=Data(text.utf8);guard reads.values.reduce(0,{$0+$1.0.count})+bytes.count<=32*1024*1024 else{throw Self.error("读取内存预算已满")};let id=UUID().uuidString;reads[id]=(bytes,Date());return ["id":id,"exists":true,"size":bytes.count]
        case "storage.read.chunk":
            let id=try string(p,"id");guard let entry=reads[id],let offset=p["offset"] as? Int,offset>=0,offset<=entry.0.count else{throw Self.error("读取会话或偏移无效")};let length=min(max(p["length"] as? Int ?? 65536,1),65536);let end=min(entry.0.count,offset+length);return ["data":Data(entry.0.dropFirst(offset).prefix(end-offset)).base64EncodedString(),"nextOffset":end]
        case "storage.read.end":reads.removeValue(forKey:try string(p,"id"));return true
        case "storage.write.begin":
            let key=try string(p,"key");guard key.utf8.count<=256,let size=p["size"] as? Int,size>=0,size<=16*1024*1024,writes.count<2,writes.values.reduce(0,{$0+$1.size})+size<=32*1024*1024 else{throw Self.error("写入大小或并发预算无效")};let id=UUID().uuidString;writes[id]=WriteStage(key:key,size:size);return ["id":id]
        case "storage.write.chunk":
            let id=try string(p,"id");guard var stage=writes[id],let offset=p["offset"] as? Int,offset==stage.bytes.count,let bytes=Data(base64Encoded:try string(p,"data")),bytes.count<=65536,stage.bytes.count+bytes.count<=stage.size else{throw Self.error("写入块顺序或大小无效")};stage.bytes.append(bytes);writes[id]=stage;return ["nextOffset":stage.bytes.count]
        case "storage.write.commit":
            let id=try string(p,"id");guard let stage=writes[id],stage.bytes.count==stage.size,let text=String(data:stage.bytes,encoding:.utf8)else{throw Self.error("写入未完成或编码无效")};try set(stage.key,text);writes.removeValue(forKey:id);return true
        case "storage.write.cancel":writes.removeValue(forKey:try string(p,"id"));return true
        case "storage.get":return try get(try string(p,"key")) as Any? ?? NSNull()
        case "storage.set":try set(try string(p,"key"),try string(p,"value",allowEmpty:true));return true
        case "storage.status":return try status()
        case "storage.testCleanupKey":try removeTestKey();return true
        case "storage.configure":guard let enabled=p["encrypted"] as? Bool else{throw Self.error("加密开关必须为布尔值")};try configure(enabled);return try status()
        case "media.import":return try importMedia(try string(p,"path"))
        case "media.lease":return try lease(try string(p,"id"))
        case "media.abandonImport":try abandonImport(try string(p,"id"));return true
        case "media.collect":guard let ids=p["ids"] as? [String]else{throw Self.error("媒体引用列表无效")};return try collect(ids)
        case "media.consumeSource":try consumeSource(path:try string(p,"path"),id:try string(p,"id"));return true
        case "media.release":release(try string(p,"leaseId"));return true
        case "history.ocr":return try await recognize(try string(p,"id"))
        case "history.searchOCR":return try searchOCR(try string(p,"query"),offset:p["offset"] as? Int ?? 0)
        case "history.cancelOCR":cancelOCR();return true
        default:throw Self.error("未知历史存储接口")
        }
    }
    private static func error(_ message:String)->BridgeFailure{BridgeFailure(code:"HISTORY_STORAGE",message:message)}
    private func string(_ p:[String:Any],_ key:String,allowEmpty:Bool=false)throws->String{guard let value=p[key] as? String,(allowEmpty || !value.isEmpty)else{throw Self.error("参数无效：\(key)")};return value}
    private func execute(_ sql:String)throws{guard sqlite3_exec(database,sql,nil,nil,nil)==SQLITE_OK else{throw Self.error("数据库写入失败：\(String(cString:sqlite3_errmsg(database)))")}}
    private func statement(_ sql:String)throws->OpaquePointer{var value:OpaquePointer?;guard sqlite3_prepare_v2(database,sql,-1,&value,nil)==SQLITE_OK,let value else{throw Self.error("数据库语句无效")};return value}
    private func bind(_ value:String,_ index:Int32,_ s:OpaquePointer){sqlite3_bind_text(s,index,value,-1,transient)}
    private func bind(_ value:Data,_ index:Int32,_ s:OpaquePointer){if value.isEmpty{sqlite3_bind_zeroblob(s,index,0);return};_ = value.withUnsafeBytes{sqlite3_bind_blob(s,index,$0.baseAddress,Int32(value.count),transient)}}
    private func data(_ s:OpaquePointer,_ index:Int32)->Data{let size=Int(sqlite3_column_bytes(s,index));guard size>0,let bytes=sqlite3_column_blob(s,index)else{return Data()};return Data(bytes:bytes,count:size)}
    private func rows(_ sql:String,bind values:((OpaquePointer)->Void)?=nil,_ body:(OpaquePointer)throws->Void)throws{let s=try statement(sql);defer{sqlite3_finalize(s)};values?(s);while true{let step=sqlite3_step(s);if step==SQLITE_DONE{return};guard step==SQLITE_ROW else{throw Self.error("数据库读取失败")};try body(s)}}
    private func done(_ s:OpaquePointer)throws{guard sqlite3_step(s)==SQLITE_DONE else{throw Self.error("数据库保存失败")}}
    private func key(create:Bool)throws->SymmetricKey{
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.clipy.tsx.history-key",kSecAttrAccount as String:keyAccount,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne];var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status==errSecSuccess,let bytes=result as? Data,bytes.count==32{return SymmetricKey(data:bytes)}
        guard status==errSecItemNotFound,create else{throw Self.error("无法读取本机历史加密密钥（\(status)），原数据保留")}
        var bytes=Data(count:32);let random=bytes.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!)};guard random==errSecSuccess else{throw Self.error("无法生成加密密钥")}
        var add=query;add.removeValue(forKey:kSecReturnData as String);add.removeValue(forKey:kSecMatchLimit as String);add[kSecValueData as String]=bytes;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else{throw Self.error("无法安全保存加密密钥")};return SymmetricKey(data:bytes)
    }
    private func encode(_ bytes:Data,encrypted:Bool,aad:String)throws->Data{guard encrypted else{return bytes};guard let value=try AES.GCM.seal(bytes,using:key(create:true),authenticating:Data(aad.utf8)).combined else{throw Self.error("加密失败")};return value}
    private func decode(_ bytes:Data,encrypted:Bool,aad:String)throws->Data{guard encrypted else{return bytes};return try AES.GCM.open(AES.GCM.SealedBox(combined:bytes),using:key(create:false),authenticating:Data(aad.utf8))}
    func get(_ name:String)throws->String?{guard name.utf8.count<=256 else{throw Self.error("存储键过长")};var result:String?;try rows("SELECT v,e FROM kv WHERE k=?",bind:{self.bind(name,1,$0)}){s in let bytes=try self.decode(self.data(s,0),encrypted:sqlite3_column_int(s,1) != 0,aad:"kv:"+name);guard let text=String(data:bytes,encoding:.utf8)else{throw Self.error("历史数据损坏，未覆盖原数据")};result=text};return result}
    func set(_ name:String,_ value:String)throws{guard !name.isEmpty,name.utf8.count<=256,value.utf8.count<=16*1024*1024 else{throw Self.error("状态快照超过16 MiB上限")};let bytes=try encode(Data(value.utf8),encrypted:encryption,aad:"kv:"+name);var used=0,count=0,existing=0;try rows("SELECT count(*),coalesce(sum(length(v)),0) FROM kv"){count=Int(sqlite3_column_int($0,0));used=Int(sqlite3_column_int64($0,1))};try rows("SELECT length(v) FROM kv WHERE k=?",bind:{self.bind(name,1,$0)}){existing=Int(sqlite3_column_int64($0,0))};guard used-existing+bytes.count<=64*1024*1024,count<1024||existing>0 else{throw Self.error("状态存储已达64 MiB或1024键上限")};let s=try statement("INSERT INTO kv(k,v,e) VALUES(?,?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v,e=excluded.e");defer{sqlite3_finalize(s)};bind(name,1,s);bind(bytes,2,s);sqlite3_bind_int(s,3,encryption ? 1:0);try done(s)}
    func status()throws->[String:Any]{var count=0,bytes=0,media=0,ocr=0;try rows("SELECT count(*),coalesce(sum(length(v)),0) FROM kv"){count=Int(sqlite3_column_int64($0,0));bytes=Int(sqlite3_column_int64($0,1))};try rows("SELECT count(*) FROM media"){media=Int(sqlite3_column_int64($0,0))};try rows("SELECT count(*) FROM ocr"){ocr=Int(sqlite3_column_int64($0,0))};return ["encrypted":encryption,"rows":count,"bytes":bytes,"mediaCount":media,"ocrCount":ocr]}
    func configure(_ enabled:Bool)throws{
        guard enabled != encryption else{return};cancelOCR();for key in Array(leases.keys){release(key)};if enabled{_ = try key(create:true)}
        var replacements:[(String,URL,URL)]=[];try execute("BEGIN IMMEDIATE")
        do{
            for table in ["kv","ocr"]{let column=table=="kv" ? "k":"id";var updates:[(String,Data)]=[];try rows("SELECT \(column),v,e FROM \(table)"){s in let id=String(cString:sqlite3_column_text(s,0));let clear=try self.decode(self.data(s,1),encrypted:sqlite3_column_int(s,2) != 0,aad:table+":"+id);updates.append((id,try self.encode(clear,encrypted:enabled,aad:table+":"+id)))};for(id,bytes)in updates{let s=try statement("UPDATE \(table) SET v=?,e=? WHERE \(column)=?");defer{sqlite3_finalize(s)};bind(bytes,1,s);sqlite3_bind_int(s,2,enabled ? 1:0);bind(id,3,s);try done(s)}}
            var media:[(String,URL,Bool)]=[];try rows("SELECT id,path,e FROM media"){s in media.append((String(cString:sqlite3_column_text(s,0)),self.mediaRoot.appendingPathComponent(String(cString:sqlite3_column_text(s,1))),sqlite3_column_int(s,2) != 0))}
            for(id,old,wasEncrypted)in media{let plain=leaseRoot.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:plain)};try transformMedia(old,to:plain,id:id,fromEncrypted:wasEncrypted,toEncrypted:false);let new=mediaRoot.appendingPathComponent(UUID().uuidString+".media");try transformMedia(plain,to:new,id:id,fromEncrypted:false,toEncrypted:enabled);replacements.append((id,old,new));let s=try statement("UPDATE media SET path=?,e=? WHERE id=?");defer{sqlite3_finalize(s)};bind(new.lastPathComponent,1,s);sqlite3_bind_int(s,2,enabled ? 1:0);bind(id,3,s);try done(s)}
            let s=try statement("INSERT INTO meta(k,v) VALUES('encrypted',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v");bind(enabled ? "1":"0",1,s);defer{sqlite3_finalize(s)};try done(s);try execute("COMMIT");encryption=enabled
        }catch{try? execute("ROLLBACK");for(_,_,new)in replacements{try? FileManager.default.removeItem(at:new)};throw error}
        for(_,old,_)in replacements{try FileManager.default.removeItem(at:old)};try execute("VACUUM")
    }
    private func importMedia(_ path:String)throws->[String:Any]{
        let source=URL(fileURLWithPath:path).standardizedFileURL;guard source.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/")||authorizePath(source.path)else{throw Self.error("请先通过文件选择器授权导入媒体")}
        let attributes=try FileManager.default.attributesOfItem(atPath:source.path);guard attributes[.type] as? FileAttributeType == .typeRegular,let size=(attributes[.size] as? NSNumber)?.intValue,size<=128*1024*1024 else{throw Self.error("媒体必须为不超过128 MiB的普通文件")}
        try runGC();var total=0,count=0;try rows("SELECT count(*),coalesce(sum(size),0) FROM media"){count=Int(sqlite3_column_int($0,0));total=Int(sqlite3_column_int64($0,1))};guard count<1000,total+size<=1024*1024*1024 else{throw Self.error("媒体存储已达1 GiB或1000项上限")}
        let digest=try sourceDigest(source);var duplicate:String?;try rows("SELECT id FROM media WHERE sha=? LIMIT 1",bind:{self.bind(digest,1,$0)}){duplicate=String(cString:sqlite3_column_text($0,0))};if let duplicate{importPins.insert(duplicate);return ["id":duplicate,"size":size,"sha256":digest,"encrypted":encryption]}
        let id=UUID().uuidString,target=mediaRoot.appendingPathComponent(UUID().uuidString+".media");try transformMedia(source,to:target,id:id,fromEncrypted:false,toEncrypted:encryption)
        do{let s=try statement("INSERT INTO media(id,path,ext,size,e,sha,committed,owner) VALUES(?,?,?,?,?,?,0,?)");defer{sqlite3_finalize(s)};let ext=source.pathExtension.lowercased();bind(id,1,s);bind(target.lastPathComponent,2,s);bind(ext.count<=16&&ext.unicodeScalars.allSatisfy{CharacterSet.alphanumerics.contains($0)} ? ext:"bin",3,s);sqlite3_bind_int64(s,4,Int64(size));sqlite3_bind_int(s,5,encryption ? 1:0);bind(digest,6,s);bind(sessionId,7,s);try done(s)}catch{try? FileManager.default.removeItem(at:target);throw error};importPins.insert(id);return ["id":id,"size":size,"sha256":digest,"encrypted":encryption]
    }
    private func abandonImport(_ id:String)throws{
        guard id.count<=128 else{throw Self.error("媒体ID无效")};importPins.remove(id)
        // Abandonment never deletes or marks a committed row. Only the next authoritative
        // post-state-commit collect decides whether it is still referenced by history.
        let s=try statement("UPDATE media SET owner='' WHERE id=? AND committed=0");defer{sqlite3_finalize(s)};bind(id,1,s);try done(s)
    }
    private func collect(_ ids:[String])throws->[String:Any]{
        guard ids.count<=100000,ids.allSatisfy({$0.count<=128})else{throw Self.error("媒体引用列表超限")};let live=Set(ids);var items:[(String,Bool,String,Bool)]=[];try rows("SELECT id,committed,owner,deletedAt FROM media"){s in items.append((String(cString:sqlite3_column_text(s,0)),sqlite3_column_int(s,1) != 0,String(cString:sqlite3_column_text(s,2)),sqlite3_column_type(s,3) != SQLITE_NULL))};try execute("BEGIN IMMEDIATE")
        do{for(id,committed,owner,marked)in items{if live.contains(id){importPins.remove(id);let s=try statement("UPDATE media SET committed=1,deletedAt=NULL WHERE id=?");defer{sqlite3_finalize(s)};bind(id,1,s);try done(s)}else if (committed||owner != sessionId) && !marked{let s=try statement("UPDATE media SET deletedAt=? WHERE id=?");defer{sqlite3_finalize(s)};sqlite3_bind_double(s,1,Date().timeIntervalSince1970);bind(id,2,s);try done(s)}};try execute("COMMIT")}catch{try? execute("ROLLBACK");throw error};try scheduleGC();return ["live":live.count,"graceSeconds":gcGrace]
    }
    private func scheduleGC()throws{
        gcTask?.cancel();gcTask=nil;guard database != nil else{return};let active=Set(leaseMedia.values).union(importPins);var earliest:TimeInterval?
        try rows("SELECT id,deletedAt FROM media WHERE deletedAt IS NOT NULL"){s in let id=String(cString:sqlite3_column_text(s,0));if !active.contains(id){let deadline=sqlite3_column_double(s,1)+self.gcGrace;earliest=min(earliest ?? deadline,deadline)}}
        guard let earliest else{return};let delay=max(0,earliest-Date().timeIntervalSince1970)
        gcTask=Task{ @MainActor [weak self] in do{try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}catch{return};guard !Task.isCancelled,let self,self.database != nil else{return};do{try self.runGC();try self.scheduleGC()}catch{self.gcTask=nil}}
    }
    private func runGC()throws{
        let active=Set(leaseMedia.values).union(importPins);var expired:[(String,URL)]=[];try rows("SELECT id,path FROM media WHERE deletedAt IS NOT NULL AND deletedAt<=?",bind:{sqlite3_bind_double($0,1,Date().timeIntervalSince1970-self.gcGrace)}){s in let id=String(cString:sqlite3_column_text(s,0));if !active.contains(id){expired.append((id,self.mediaRoot.appendingPathComponent(String(cString:sqlite3_column_text(s,1)))))}};guard !expired.isEmpty else{return};try execute("BEGIN IMMEDIATE")
        do{for(id,_)in expired{for table in ["ocr","media"]{let s=try statement("DELETE FROM \(table) WHERE id=?");defer{sqlite3_finalize(s)};bind(id,1,s);try done(s)}};try execute("COMMIT")}catch{try? execute("ROLLBACK");throw error};for(_,path)in expired{try? FileManager.default.removeItem(at:path)}
    }
    private func sourceDigest(_ url:URL)throws->String{let input=try openRegular(url);defer{try? input.close()};var digest=SHA256(),total=0;while let bytes=try input.read(upToCount:1024*1024),!bytes.isEmpty{total+=bytes.count;guard total<=128*1024*1024 else{throw Self.error("媒体超过128 MiB")};digest.update(data:bytes)};return digest.finalize().map{String(format:"%02x",$0)}.joined()}
    private func consumeSource(path:String,id:String)throws{
        let original=URL(fileURLWithPath:path).standardizedFileURL;let source=original.resolvingSymlinksInPath();let base=root.resolvingSymlinksInPath();let allowed=["clipboard","captures","imports","edited-images","processed"].contains{source.path.hasPrefix(base.appendingPathComponent($0).path+"/")}
        guard allowed,try FileManager.default.attributesOfItem(atPath:original.path)[.type] as? FileAttributeType == .typeRegular else{throw Self.error("仅允许清理本应用clipboard/captures/imports/edited-images/processed暂存普通文件")}
        var expected:String?,managed:URL?,encrypted=false;try rows("SELECT sha,path,e FROM media WHERE id=?",bind:{self.bind(id,1,$0)}){s in expected=String(cString:sqlite3_column_text(s,0));managed=self.mediaRoot.appendingPathComponent(String(cString:sqlite3_column_text(s,1)));encrypted=sqlite3_column_int(s,2) != 0};guard let expected,!expected.isEmpty,let managed,try sourceDigest(source)==expected else{throw Self.error("源媒体与已持久副本不一致，未删除")}
        if encrypted{let verification=leaseRoot.appendingPathComponent("verify-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:verification)};try transformMedia(managed,to:verification,id:id,fromEncrypted:true,toEncrypted:false);guard try sourceDigest(verification)==expected else{throw Self.error("受管媒体副本不完整，原始文件保留")}}else{guard try sourceDigest(managed)==expected else{throw Self.error("受管媒体副本不完整，原始文件保留")}};try FileManager.default.removeItem(at:original)
    }
    private func lease(_ id:String)throws->[String:Any]{guard leases.count<32 else{throw Self.error("预览已达32项，请先关闭已有预览")};var source:URL?,ext="bin",encrypted=false;try rows("SELECT path,ext,e FROM media WHERE id=?",bind:{self.bind(id,1,$0)}){s in source=self.mediaRoot.appendingPathComponent(String(cString:sqlite3_column_text(s,0)));ext=String(cString:sqlite3_column_text(s,1));encrypted=sqlite3_column_int(s,2) != 0};guard let source else{throw Self.error("媒体不存在")};let token=UUID().uuidString,target=leaseRoot.appendingPathComponent(token+"."+ext);try transformMedia(source,to:target,id:id,fromEncrypted:encrypted,toEncrypted:false);leases[token]=(target,Date());leaseMedia[token]=id;return ["leaseId":token,"path":target.path]}
    private func release(_ token:String){leaseMedia.removeValue(forKey:token);if let lease=leases.removeValue(forKey:token){try? FileManager.default.removeItem(at:lease.0)};try? scheduleGC()}
    private func cleanOrphans()throws{var used=Set<String>();try rows("SELECT path FROM media"){used.insert(String(cString:sqlite3_column_text($0,0)))};for url in try FileManager.default.contentsOfDirectory(at:mediaRoot,includingPropertiesForKeys:nil)where !used.contains(url.lastPathComponent){try FileManager.default.removeItem(at:url)}}
    private func openRegular(_ url:URL)throws->FileHandle{let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw Self.error("无法读取媒体或路径是链接")};var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG else{_ = Darwin.close(fd);throw Self.error("仅允许普通媒体文件")};return FileHandle(fileDescriptor:fd,closeOnDealloc:true)}
    private func transformMedia(_ source:URL,to target:URL,id:String,fromEncrypted:Bool,toEncrypted:Bool)throws{
        guard !fromEncrypted || !toEncrypted else{throw Self.error("无效的媒体转换")};let input=try openRegular(source);defer{try? input.close()};let fd=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw Self.error("无法创建媒体目标")};let output=FileHandle(fileDescriptor:fd,closeOnDealloc:true);var success=false;defer{try? output.close();if !success{try? FileManager.default.removeItem(at:target)}}
        if fromEncrypted {
            let header=try exact(input,44);guard header.prefix(4)==Data("CTM1".utf8)else{throw Self.error("媒体加密头损坏")};let size=header.dropFirst(4).prefix(8).reduce(UInt64(0)){($0<<8)|UInt64($1)};guard size<=128*1024*1024 else{throw Self.error("媒体大小超限")};let expected=Data(header.suffix(32)),key=try key(create:false);var total=0,index=0,digest=SHA256()
            repeat{let length=try exact(input,4).reduce(0){($0<<8)|Int($1)};let expectedBytes=min(1024*1024,Int(size)-total);guard length==expectedBytes+28 else{throw Self.error("媒体块长度无效")};var aad=header;aad.append(Data(id.utf8));aad.appendBE(UInt32(index));let raw=try AES.GCM.open(AES.GCM.SealedBox(combined:exact(input,length)),using:key,authenticating:aad);try output.write(contentsOf:raw);digest.update(data:raw);total+=raw.count;index+=1}while total<Int(size)
            guard (try input.read(upToCount:1) ?? Data()).isEmpty,Data(digest.finalize())==expected else{throw Self.error("媒体完整性校验失败")}
        }else{
            let size=try input.seekToEnd();guard size<=128*1024*1024 else{throw Self.error("媒体超过128 MiB")};try input.seek(toOffset:0)
            if toEncrypted{var digest=SHA256(),count=0;while let bytes=try input.read(upToCount:1024*1024),!bytes.isEmpty{count+=bytes.count;guard count<=128*1024*1024 else{throw Self.error("媒体读取超限")};digest.update(data:bytes)};guard count==Int(size)else{throw Self.error("媒体读取时发生变化")};try input.seek(toOffset:0);var header=Data("CTM1".utf8);header.appendBE(size);header.append(Data(digest.finalize()));try output.write(contentsOf:header);let key=try key(create:true);var total=0,index=0,check=SHA256()
                repeat{let bytes=try input.read(upToCount:1024*1024) ?? Data();guard total+bytes.count<=Int(size)else{throw Self.error("媒体读取时发生变化")};var aad=header;aad.append(Data(id.utf8));aad.appendBE(UInt32(index));guard let sealed=try AES.GCM.seal(bytes,using:key,authenticating:aad).combined else{throw Self.error("媒体加密失败")};var length=Data();length.appendBE(UInt32(sealed.count));try output.write(contentsOf:length);try output.write(contentsOf:sealed);check.update(data:bytes);total+=bytes.count;index+=1;guard !bytes.isEmpty||total==Int(size)else{throw Self.error("媒体被截断")}}while total<Int(size)
                guard Data(check.finalize())==Data(header.suffix(32)),(try input.read(upToCount:1) ?? Data()).isEmpty else{throw Self.error("媒体读取时发生变化")}
            }else{var total=0;while let bytes=try input.read(upToCount:1024*1024),!bytes.isEmpty{total+=bytes.count;guard total<=Int(size)else{throw Self.error("媒体读取时发生变化")};try output.write(contentsOf:bytes)};guard total==Int(size)else{throw Self.error("媒体被截断")}}
        }
        try output.synchronize();success=true
    }
    private func exact(_ input:FileHandle,_ size:Int)throws->Data{var output=Data();while output.count<size{guard let bytes=try input.read(upToCount:size-output.count),!bytes.isEmpty else{throw Self.error("媒体被截断")};output.append(bytes)};return output}
    func cancelOCR(){generation+=1;for process in workers.values where process.isRunning{process.terminate()};workers.removeAll()}
    private func recognize(_ id:String)async throws->[String:Any]{
        guard workers.count<2 else{throw Self.error("最多同时识别两张图片")};let preview=try lease(id);guard let token=preview["leaseId"] as? String,let path=preview["path"] as? String else{throw Self.error("无法读取识别媒体")};defer{release(token)}
        let current=generation,taskId=UUID().uuidString,process=Process(),pipe=Pipe();var executableSize:UInt32=0;_NSGetExecutablePath(nil,&executableSize);var executableBuffer=[CChar](repeating:0,count:Int(executableSize));guard _NSGetExecutablePath(&executableBuffer,&executableSize)==0 else{throw Self.error("无法定位OCR子进程程序")};process.executableURL=URL(fileURLWithPath:String(cString:executableBuffer)).resolvingSymlinksInPath();process.arguments=["--history-ocr-worker",path];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice;workers[taskId]=process;defer{workers.removeValue(forKey:taskId)};do{try process.run()}catch{workers.removeValue(forKey:taskId);throw error}
        let timeout=Task{@MainActor in try? await Task.sleep(nanoseconds:30_000_000_000);if !Task.isCancelled,process.isRunning{process.terminate()}};defer{timeout.cancel()}
        let bytes=try await Task.detached(priority:.utility){let result=try pipe.fileHandleForReading.readToEnd() ?? Data();process.waitUntilExit();return result}.value
        guard current==generation,process.terminationStatus==0,bytes.count<=1024*1024,let result=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let text=result["text"] as? String else{throw Self.error("文字识别已取消、超时或失败")}
        let encoded=try encode(Data(text.utf8),encrypted:encryption,aad:"ocr:"+id);let s=try statement("INSERT INTO ocr(id,v,e) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET v=excluded.v,e=excluded.e");defer{sqlite3_finalize(s)};bind(id,1,s);bind(encoded,2,s);sqlite3_bind_int(s,3,encryption ? 1:0);try done(s);return ["id":id,"text":text]
    }
    private func searchOCR(_ query:String,offset:Int)throws->[String:Any]{guard query.count<=500,offset>=0,offset<=100000 else{throw Self.error("搜索参数无效")};var ids:[String]=[],seen=0;try rows("SELECT id,v,e FROM ocr ORDER BY id LIMIT 256 OFFSET ?",bind:{sqlite3_bind_int($0,1,Int32(offset))}){s in seen+=1;let id=String(cString:sqlite3_column_text(s,0)),bytes=try self.decode(self.data(s,1),encrypted:sqlite3_column_int(s,2) != 0,aad:"ocr:"+id);if let text=String(data:bytes,encoding:.utf8),text.localizedCaseInsensitiveContains(query){ids.append(id)}};return ["ids":ids,"nextOffset":seen==256 ? offset+seen as Any:NSNull()]}
    nonisolated static func runOCRWorker(path:String)throws->[String:Any]{let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true;try VNImageRequestHandler(url:URL(fileURLWithPath:path)).perform([request]);let text=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n");return ["text":String(text.prefix(256*1024))]}
    /// Only test-created accounts may be cleaned by the regression harness, never production accounts.
    func removeTestKey()throws{guard ProcessInfo.processInfo.environment["CLIPY_STORAGE_TEST"]=="1",root.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path),root.path.contains("clipy-") else{throw Self.error("测试清理不可用于正式身份")};let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.clipy.tsx.history-key",kSecAttrAccount as String:keyAccount];let result=SecItemDelete(query as CFDictionary);guard result==errSecSuccess||result==errSecItemNotFound else{throw Self.error("测试密钥清理失败")}}
}
private extension Data{
 mutating func appendBE(_ value:UInt32){append(UInt8((value>>24)&255));append(UInt8((value>>16)&255));append(UInt8((value>>8)&255));append(UInt8(value&255))}
 mutating func appendBE(_ value:UInt64){appendBE(UInt32(value>>32));appendBE(UInt32(value&0xffffffff))}
}
