import Foundation
import CryptoKit
import Darwin

/// Isolated, encrypted-frame journal. Content is encrypted before this owner sees it.
final class LANPendingStore {
    struct Record:Codable {let peer:String;let hash:String;let type:String;let frame:Data;let created:Date}
    let directory:URL
    private(set) var records:[String:Record]=[:]
    private let limit=16*1024*1024
    private var lockFD:Int32 = -1
    init(directory:URL)throws {
        self.directory=directory;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(directory.appendingPathComponent("journal.lock").path,O_RDWR|O_CREAT,0o600);guard fd>=0 else{throw BridgeFailure(code:"PENDING_LOCK",message:"离线队列无法加锁")};guard flock(fd,LOCK_EX|LOCK_NB)==0 else{_ = Darwin.close(fd);throw BridgeFailure(code:"PENDING_LOCK",message:"离线队列正在由另一实例使用")};var success=false;defer{if !success{_ = flock(fd,LOCK_UN);_ = Darwin.close(fd)}}
        let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey],options:[.skipsHiddenFiles]).filter{$0.pathExtension=="json" && $0.lastPathComponent != "configuration.json"}
        guard urls.count<=2048 else{throw BridgeFailure(code:"PENDING_LIMIT",message:"离线队列超限")}
        var total=0
        for url in urls {let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=3*1024*1024,total+size<=limit else{throw BridgeFailure(code:"PENDING_LIMIT",message:"离线队列文件超限")};total+=size;let value=try JSONDecoder().decode(Record.self,from:Data(contentsOf:url));guard value.peer.count<=128,value.hash.count<=128,value.frame.count<=2*1024*1024 else{throw BridgeFailure(code:"INVALID_PENDING",message:"离线队列数据无效")};records[key(value.peer,value.hash)]=value}
        lockFD=fd;success=true
    }
    deinit{if lockFD>=0{_ = flock(lockFD,LOCK_UN);_ = Darwin.close(lockFD)}}
    func put(peer:String,hash:String,type:String,frame:Data)throws->Record{
        let identifier=key(peer,hash)
        if let existing=records[identifier]{return existing}
        guard records.count<2048,records.values.reduce(0,{$0+$1.frame.count})+frame.count<=limit else{throw BridgeFailure(code:"PENDING_LIMIT",message:"离线队列已满，请等待设备确认")}
        let value=Record(peer:peer,hash:hash,type:type,frame:frame,created:Date());try durable(try JSONEncoder().encode(value),to:path(identifier));records[identifier]=value;return value
    }
    func remove(peer:String,hash:String)throws{let identifier=key(peer,hash);guard records[identifier] != nil else{return};try FileManager.default.removeItem(at:path(identifier));records.removeValue(forKey:identifier);syncDirectory()}
    func has(peer:String)->Bool{records.values.contains{$0.peer==peer}}
    func forPeer(_ peer:String)->[Record]{records.values.filter{$0.peer==peer}.sorted{$0.created<$1.created}}
    func configuration()throws->[String:Any]{let path=directory.appendingPathComponent("configuration.json");guard FileManager.default.fileExists(atPath:path.path)else{return [:]};let data=try Data(contentsOf:path);guard data.count<=1024*1024,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw BridgeFailure(code:"INVALID_CONFIG",message:"局域网配置无效")};return value}
    func saveConfiguration(_ value:[String:Any])throws{try durable(JSONSerialization.data(withJSONObject:value),to:directory.appendingPathComponent("configuration.json"))}
    private func key(_ peer:String,_ hash:String)->String{SHA256.hash(data:Data((peer+"\n"+hash).utf8)).map{String(format:"%02x",$0)}.joined()}
    private func path(_ key:String)->URL{directory.appendingPathComponent(key+".json")}
    private func durable(_ data:Data,to url:URL)throws{try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);let handle=try FileHandle(forWritingTo:url);try handle.synchronize();try handle.close();syncDirectory()}
    private func syncDirectory(){let fd=open(directory.path,O_RDONLY);if fd>=0{_ = fsync(fd);_ = Darwin.close(fd)}}
}
