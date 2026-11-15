import Foundation
import Network
import CryptoKit
import Darwin

/// Fresh protocol-v3 transport. It never accesses the production client's identity or database.
@MainActor final class LANService {
    @MainActor private final class Session {
        let id = UUID().uuidString
        let connection: NWConnection?
        var tunnelSend:((Data)async throws->Void)?
        var onClose:(()->Void)?
        var writeTail:Task<Void,Error>?
        var outboundBytes=0
        var outboundFrames=0
        let host: String
        let outbound: Bool
        var buffer = Data()
        var peer: String?
        var name = ""
        var remotePort = 0
        var pending = 0
        var pendingBytes = 0
        var reading = false
        var closed = false
        var sentHashes=Set<String>()
        var lastActivity=Date()
        var connectedAt:Date?
        var screenChallenge:String?
        var screenIssued=Date.distantPast
        var timeout: Task<Void,Never>?
        var connectWait: CheckedContinuation<[String:Any],Error>?
        init(_ connection:NWConnection?,host:String,outbound:Bool){self.connection=connection;self.host=host;self.outbound=outbound}
    }
    private struct Incoming { let session:String;let hash:String;let type:String;let size:Int;let peer:String;let digest:String;var routes:Set<String>;init(session:String,hash:String,type:String,size:Int,peer:String,digest:String){self.session=session;self.hash=hash;self.type=type;self.size=size;self.peer=peer;self.digest=digest;self.routes=[session]} }
    @MainActor private final class IncomingFile {
        let id:String;let session:String;let name:String;let folderName:String?;let path:URL;let handle:FileHandle;let size:Int;let chunks:Int;let chunkSize:Int;let sha:String
        var index=0;var written=0;var digest=SHA256();var last=Date()
        init(id:String,session:String,name:String,path:URL,handle:FileHandle,size:Int,chunks:Int,chunkSize:Int,sha:String,folderName:String?=nil){self.folderName=folderName;self.id=id;self.session=session;self.name=name;self.path=path;self.handle=handle;self.size=size;self.chunks=chunks;self.chunkSize=chunkSize;self.sha=sha}
    }
    private struct Receipt { let peer:String;let hash:String;let wait:CheckedContinuation<[String:Any],Error>;let timer:Task<Void,Never>;var isFile=false }
    var screenStateProvider:(()async->[String:Any])?
    var screenCommandHandler:((String)async->String)?
    private var screenTasks:[String:(String,Task<Void,Never>)]=[:]
    private var screenBusyOwner:String?
    private var lastUnlock=Date.distantPast
    private let emit: (String,[String:Any])->Void
    private let queue = DispatchQueue(label:"dev.clipy.tsx.lan",qos:.utility)
    private let key = SymmetricKey(data:SHA256.hash(data:Data("ClipySyncSecret2026".utf8)))
    private let peerId:String
    private var files:[String:IncomingFile]=[:]
    private var fileTimer:Task<Void,Never>?
    private let receiveRoot:URL
    private var scanGeneration=0
    private var scanActive=false
    private var running=false
    private var stoppingAll=false
    private var authorized=Set<String>()
    private var notificationAuthorized=Set<String>()
    private var journal:LANPendingStore?
    private var journalLoaded=false
    private var maintenance:Task<Void,Never>?
    private var lastFlush:[String:Date]=[:]
    private var lastHistoryRequest:[String:Date]=[:]
    private var lastHistoryResponse:[String:Date]=[:]
    private let stateRoot:URL
    private var endpoints:[String:(String,Int)]=[:]
    private var reconnect:[String:Task<Void,Never>]=[:]
    private var reconnectTokens:[String:UUID]=[:]
    private var listener:NWListener?
    private var sessions:[String:Session]=[:]
    private var incoming:[String:Incoming]=[:]
    private var receipts:[String:Receipt]=[:]
    private var fileProgress:[String:Date]=[:]
    private var name="Clipy TSX"
    private var port=5567
    private var listening=false
    private var admittedBytes=0
    init(emit:@escaping(String,[String:Any])->Void,peerId:String?=nil,receiveDirectory:URL?=nil,stateDirectory:URL?=nil){
        stateRoot=stateDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ClipyTSX/lan-state",isDirectory:true)
        receiveRoot=receiveDirectory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ClipyTSX/received",isDirectory:true)
        self.emit=emit
        if let id=peerId ?? ProcessInfo.processInfo.environment["CLIPY_LAN_PEER_ID"],!id.isEmpty {self.peerId=id}
        else {let defaults=UserDefaults(suiteName:"dev.clipy.tsx.lan")!;let id=defaults.string(forKey:"peerId") ?? UUID().uuidString;defaults.set(id,forKey:"peerId");self.peerId=id}
    }
    func start(port:Int,deviceName:String)throws->[String:Any]{
        guard (1...65535).contains(port),let endpoint=NWEndpoint.Port(rawValue:UInt16(port)) else {throw failure("端口必须为1–65535")}
        stopLAN();try loadJournal();self.running=true;self.port=port;self.name=String(deviceName.prefix(128))
        let params=NWParameters.tcp;params.allowLocalEndpointReuse=true
        let server=try NWListener(using:params,on:endpoint);listener=server
        server.newConnectionHandler={ [weak self,weak server] connection in Task { @MainActor in guard let self,let server,self.listener===server,self.running,self.sessions.count<32 else {connection.cancel();return};self.adopt(connection,host:self.hostname(connection.endpoint),outbound:false) } }
        server.stateUpdateHandler={ [weak self,weak server] state in Task { @MainActor in guard let self,let server,self.listener===server else{return};switch state {case .ready:self.listening=true;self.emit("lan.status",self.status());case .failed:self.listening=false;self.emit("lan.error",["message":"局域网监听失败，端口可能已占用"]);default:break} } }
        server.start(queue:queue);startMaintenance();for peer in authorized.union(notificationAuthorized).union(Set(journal?.records.values.map(\.peer) ?? [])){scheduleReconnect(peer)};return status()
    }
    func connect(host:String,port:Int,timeout:Double=8)async throws->[String:Any]{
        guard !host.isEmpty,host.count<=253,(1...65535).contains(port),let endpoint=NWEndpoint.Port(rawValue:UInt16(port)) else {throw failure("请输入有效地址和端口")}
        guard sessions.count<32 else {throw failure("连接数量已达32台上限")}
        let connection=NWConnection(host:NWEndpoint.Host(host),port:endpoint,using:.tcp)
        do{return try await withCheckedThrowingContinuation { continuation in let session=adopt(connection,host:host,outbound:true,timeout:timeout);session.remotePort=port;session.connectWait=continuation }}catch{try? await Task.sleep(nanoseconds:50_000_000);if let existing=sessions.values.first(where:{$0.connection != nil && !$0.closed && $0.peer != nil && $0.host==host && $0.remotePort==port}){return peer(existing)};throw error}
    }
    private func loadJournal()throws{
        guard !journalLoaded else{return};let store=try LANPendingStore(directory:stateRoot.appendingPathComponent(SHA256.hash(data:Data(peerId.utf8)).map{String(format:"%02x",$0)}.joined(),isDirectory:true));let config=try store.configuration()
        authorized=Set(config["clipboard"] as? [String] ?? []);notificationAuthorized=Set(config["notifications"] as? [String] ?? [])
        if let values=config["endpoints"] as? [String:[String:Any]]{for(id,value)in values{if let host=value["host"] as? String,let port=value["port"] as? Int,(1...65535).contains(port){endpoints[id]=(host,port)}}};journal=store;journalLoaded=true
    }
    private func saveConfiguration()throws{try loadJournal();try journal?.saveConfiguration(["clipboard":Array(authorized),"notifications":Array(notificationAuthorized),"endpoints":endpoints.mapValues{["host":$0.0,"port":$0.1] as [String:Any]}])}
    func authorize(peerId:String,clipboard:Bool,notifications:Bool)throws->[String:Any]{try loadJournal();guard peerId.count<=128,authorized.union(notificationAuthorized).count<128||authorized.contains(peerId)||notificationAuthorized.contains(peerId) else{throw failure("授权设备过多")};if clipboard{authorized.insert(peerId)}else{authorized.remove(peerId)};if notifications{notificationAuthorized.insert(peerId)}else{notificationAuthorized.remove(peerId)};for record in journal?.forPeer(peerId) ?? [] where (record.type=="history" && !clipboard)||(record.type.hasPrefix("notif.") && !notifications){try journal?.remove(peer:peerId,hash:record.hash)};try saveConfiguration();return ["peerId":peerId,"clipboard":clipboard,"notifications":notifications]}
    func broadcast(text:String)throws->[String:Any]{try loadJournal();guard !text.isEmpty,text.utf8.count<=512*1024 else{throw failure("文本超过上限")};let hash=Self.hash(text);var frame=envelope("history");frame["hash"]=hash;frame["payload"]=try encrypt(Data(text.utf8));for peer in authorized{_ = try journal!.put(peer:peer,hash:hash,type:"history",frame:JSONSerialization.data(withJSONObject:frame));if let session=bestSession(peer){flushPending(session,force:true)}else if running{scheduleReconnect(peer)}};return ["queued":authorized.count,"confirmed":false]}
    func notification(peerId:String,type:String,payload:[String:Any],hash:String="")throws->[String:Any]{
        guard ["notif.post","notif.dismiss","notif.clear"].contains(type) else{throw failure("通知消息类型无效")};try loadJournal();let bytes=try JSONSerialization.data(withJSONObject:payload);guard bytes.count<=1024*1024 else{throw failure("通知过大")};var frame=envelope(type);frame["payload"]=try encrypt(bytes);if !hash.isEmpty{frame["hash"]=hash}
        let targets=peerId.isEmpty ? Array(notificationAuthorized) : [peerId]
        for target in targets {if !hash.isEmpty{_ = try journal!.put(peer:target,hash:hash,type:type,frame:JSONSerialization.data(withJSONObject:frame))};if let session=bestSession(target){if hash.isEmpty{send(frame,session)}else{flushPending(session,force:true)}}else if !hash.isEmpty,running{scheduleReconnect(target)}else{throw failure("设备离线，清除通知未发送")}}
        return ["queued":targets.count,"confirmed":false]
    }
    func replayHistory(peerId:String,texts:[String])async throws->[String:Any]{guard authorized.contains(peerId),let session=bestSession(peerId)else{throw failure("设备未授权同步历史")};var count=0;for text in texts.prefix(200) where text.utf8.count<=512*1024{var frame=envelope("history");frame["hash"]=Self.hash(text);frame["payload"]=try encrypt(Data(text.utf8));try await write(frame,session);count+=1};return ["replayed":count]}
    private func flushPending(_ session:Session,force:Bool=false,resetInFlight:Bool=false,at now:Date=Date()){guard let remote=session.peer,bestSession(remote)===session else{return};if resetInFlight{session.sentHashes.removeAll()};if now.timeIntervalSince(lastFlush[session.id] ?? .distantPast)>=120{session.sentHashes.removeAll();lastFlush[session.id]=now};let rows=journal?.forPeer(remote) ?? [];var outstanding=rows.filter{session.sentHashes.contains($0.hash)}.reduce(0){$0+$1.frame.count};for record in rows where !session.sentHashes.contains(record.hash)&&(record.type=="history.direct"||(record.type=="history"&&authorized.contains(remote))||(record.type.hasPrefix("notif.")&&notificationAuthorized.contains(remote))){guard session.sentHashes.count<32,outstanding+record.frame.count<=4*1024*1024 else{break};if let frame=try? JSONSerialization.jsonObject(with:record.frame) as? [String:Any]{session.sentHashes.insert(record.hash);outstanding+=record.frame.count;send(frame,session)}}}
    private func startMaintenance(){guard maintenance==nil else{return};maintenance=Task{[weak self]in while !Task.isCancelled{try? await Task.sleep(nanoseconds:30_000_000_000);guard !Task.isCancelled,let self,self.hasActiveTransport else{return};for session in Array(self.sessions.values) where session.peer != nil{if session.pending==0,Date().timeIntervalSince(session.lastActivity)>90{self.close(session,"保活超时")}else{self.send(self.envelope("ping"),session);self.flushPending(session)}}}}}
    func setAuthorizedPeers(_ peers:[String])throws->[String:Any]{try loadJournal();guard peers.count<=128 else{throw failure("授权设备过多")};authorized=Set(peers);try saveConfiguration();for (id,task) in reconnect where !authorized.contains(id){task.cancel();reconnect.removeValue(forKey:id)};return ["authorized":Array(authorized)]}
    func cancelScan(){scanGeneration+=1;scanActive=false}
    func scan(port:Int?=nil)async throws->[String:Any]{
        guard !scanActive else{throw failure("设备发现正在进行")};let scanPort=port ?? self.port;guard (1...65535).contains(scanPort)else{throw failure("端口无效")}
        let ranges=Self.physicalRanges();guard !ranges.isEmpty else{throw failure("没有可扫描的物理IPv4网络，请手动添加IP")}
        scanGeneration+=1;let generation=scanGeneration;scanActive=true;defer{if generation==scanGeneration{scanActive=false}}
        let addresses=ranges.flatMap{range in (1...254).map{"\(range.prefix).\($0)"}.filter{$0 != range.own}}
        var completed=0;var lastProgress=Date.distantPast
        emit("lan.scan",["completed":0,"total":addresses.count,"scanning":true])
        await withTaskGroup(of:Void.self){group in
            for worker in 0..<min(16,addresses.count){group.addTask { @MainActor [weak self] in guard let self else{return};for index in stride(from:worker,to:addresses.count,by:16){guard !Task.isCancelled,self.scanGeneration==generation else{return};let address=addresses[index];if !self.sessions.values.contains(where:{$0.host==address && $0.peer != nil}){_ = try? await self.connect(host:address,port:scanPort,timeout:0.8)};completed+=1;if Date().timeIntervalSince(lastProgress)>=0.1{lastProgress=Date();self.emit("lan.scan",["completed":completed,"total":addresses.count,"scanning":true])}} }}
        }
        let cancelled=generation != scanGeneration;emit("lan.scan",["completed":completed,"total":addresses.count,"scanning":false,"cancelled":cancelled]);var result=status();result["cancelled"]=cancelled;result["probed"]=completed;return result
    }
    private static func physicalRanges()->[(prefix:String,own:String)]{
        var head:UnsafeMutablePointer<ifaddrs>?;guard getifaddrs(&head)==0 else{return []};defer{freeifaddrs(head)};var cursor=head;var ranges:[(String,String)]=[];var seen=Set<String>()
        while let item=cursor{defer{cursor=item.pointee.ifa_next};let ifa=item.pointee;guard let address=ifa.ifa_addr,address.pointee.sa_family==UInt8(AF_INET),String(cString:ifa.ifa_name).hasPrefix("en"),ifa.ifa_flags&UInt32(IFF_UP) != 0,ifa.ifa_flags&UInt32(IFF_LOOPBACK)==0 else{continue};var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST));guard getnameinfo(address,socklen_t(address.pointee.sa_len),&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0 else{continue};let own=String(cString:buffer);let parts=own.split(separator:".");guard parts.count==4,!own.hasPrefix("169.254.") else{continue};let prefix=parts.prefix(3).joined(separator:".");if seen.insert(prefix).inserted{ranges.append((prefix,own))};if ranges.count>=2{break}}
        return ranges
    }
    private func scheduleReconnect(_ peer:String){
        guard running,reconnect[peer]==nil,bestSession(peer)?.connection==nil,let endpoint=endpoints[peer] else{return}
        let token=UUID();reconnectTokens[peer]=token
        reconnect[peer]=Task { [weak self] in
            defer{if self?.reconnectTokens[peer]==token{self?.reconnect.removeValue(forKey:peer);self?.reconnectTokens.removeValue(forKey:peer)}}
            for delay in [1,3,10,30,60] {try? await Task.sleep(nanoseconds:UInt64(delay)*1_000_000_000);guard !Task.isCancelled,let self,self.running,(self.authorized.contains(peer)||self.notificationAuthorized.contains(peer)||self.journal?.has(peer:peer)==true) else{return};if self.bestSession(peer)?.connection != nil{self.reconnect.removeValue(forKey:peer);return};if let result=try? await self.connect(host:endpoint.0,port:endpoint.1),result["id"] as? String==peer{self.reconnect.removeValue(forKey:peer);return}}
            self?.reconnect.removeValue(forKey:peer)
        }
    }
    /// Authenticated common-relay byte streams reuse this exact v3 codec and receipt pipeline.
    func openTunnel(id:String,initiator:Bool=true,send:@escaping(Data)async throws->Void,onClose:(()->Void)?=nil)throws->String {
        guard sessions.count<32 else{throw failure("连接数量已达上限")};try loadJournal()
        let session=Session(nil,host:"relay:"+id,outbound:initiator);session.tunnelSend=send;session.onClose=onClose;sessions[session.id]=session
        session.timeout=Task { [weak self,weak session] in try? await Task.sleep(nanoseconds:8_000_000_000);guard !Task.isCancelled,let self,let session,session.peer==nil else{return};self.close(session,"中继隧道握手超时") }
        startMaintenance();if initiator{self.send(envelope("hello"),session)};return session.id
    }
    func feedTunnel(sessionId:String,data:Data)async throws {
        guard let session=sessions[sessionId],!session.closed else{throw failure("中继隧道已关闭")}
        guard data.count<=256*1024 else{throw failure("中继输入块超过256 KiB")}
        let start=Date()
        while session.pending>=32||session.pendingBytes>=4*1024*1024||admittedBytes>=16*1024*1024 {guard !session.closed,!Task.isCancelled,Date().timeIntervalSince(start)<120 else{throw failure("中继背压等待已取消或超时")};try await Task.sleep(nanoseconds:20_000_000)}
        session.buffer.append(data);guard session.buffer.count<=2*1024*1024+256*1024 else{close(session,"中继缓冲超限");throw failure("中继缓冲超限")};do{try drain(session)}catch{close(session,"中继帧无效");throw error}
    }
    func closeTunnel(sessionId:String){if let session=sessions[sessionId]{close(session,"中继隧道已关闭")}}
    @discardableResult private func adopt(_ connection:NWConnection,host:String,outbound:Bool,timeout:Double=8)->Session {
        let session=Session(connection,host:host,outbound:outbound);sessions[session.id]=session
        session.timeout=Task { [weak self,weak session] in try? await Task.sleep(nanoseconds:UInt64(max(0.1,min(timeout,30))*1_000_000_000));guard !Task.isCancelled,let self,let session,session.peer==nil else{return};self.close(session,"握手超时") }
        connection.stateUpdateHandler={ [weak self,weak session] value in Task { @MainActor in guard let self,let session,!session.closed else{return};switch value {case .ready:if outbound {self.send(self.envelope("hello"),session)};self.read(session);case .failed,.cancelled:self.close(session,"连接已关闭");default:break} } }
        connection.start(queue:queue);return session
    }
    private func read(_ session:Session){
        guard !session.closed,!session.reading,session.pending<32,session.pendingBytes<4*1024*1024,admittedBytes<16*1024*1024 else{return}
        session.reading=true
        guard let connection=session.connection else{return}
        connection.receive(minimumIncompleteLength:1,maximumLength:256*1024){ [weak self,weak session] data,_,ended,error in Task { @MainActor in guard let self,let session,!session.closed else{return};session.reading=false;if let data {session.buffer.append(data)};do{try self.drain(session)}catch{self.close(session,"无效协议或加密数据");return};if ended||error != nil{self.close(session,"对端已断开")}else{self.read(session)} } }
    }
    private func drain(_ session:Session)throws {
        while session.buffer.count>=4 {
            let length=session.buffer.prefix(4).reduce(0){($0<<8)|Int($1)}
            guard length>0,length<=2*1024*1024,session.peer != nil||length<=64*1024 else {throw failure("帧长度无效")}
            guard session.buffer.count>=length+4 else{return}
            if session.pending>=32||session.pendingBytes+length>4*1024*1024||admittedBytes+length>16*1024*1024{return}
            let data=Data(session.buffer.dropFirst(4).prefix(length));session.buffer=Data(session.buffer.dropFirst(length+4))
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw failure("帧必须是JSON对象")}
            try receive(object,session,length)
        }
    }
    private func receive(_ frame:[String:Any],_ session:Session,_ size:Int)throws {
        session.lastActivity=Date()
        guard frame["v"] as? Int == 3,let type=frame["type"] as? String,let remote=frame["peerId"] as? String,let id=frame["msgId"] as? String,remote.count<=128,id.count<=128 else {throw failure("只支持协议v3")}
        if type=="hello"||type=="welcome" {
            guard remote != peerId else {throw failure("不能连接自身")}
            if let known=session.peer,known != remote {throw failure("会话身份变化")}
            let sameTransport=Array(sessions.values.filter{$0.peer==remote && $0.id != session.id && !$0.closed && ($0.connection != nil)==(session.connection != nil)})
            let preferredOutbound=peerId<remote
            if let existing=sameTransport.first(where:{$0.outbound==preferredOutbound || $0.outbound==session.outbound}){
                session.connectWait?.resume(returning:peer(existing));session.connectWait=nil;close(session,"保留现有首选会话");return
            }
            session.peer=remote;if session.connectedAt==nil{session.connectedAt=Date()};session.name=String((frame["name"] as? String ?? remote).prefix(128));session.remotePort=frame["port"] as? Int ?? 0
            for old in sameTransport{old.connectWait?.resume(returning:peer(session));old.connectWait=nil;close(old,"切换到字典序首选会话",preservingText:true)}
            if endpoints.count>=128,endpoints[remote]==nil,let obsolete=endpoints.keys.first(where:{!authorized.contains($0) && !notificationAuthorized.contains($0)}){endpoints.removeValue(forKey:obsolete)};if !session.host.hasPrefix("relay:"),let remotePort=frame["port"] as? Int,(1...65535).contains(remotePort),(endpoints.count<128||endpoints[remote] != nil){endpoints[remote]=(session.host,remotePort)};reconnect.removeValue(forKey:remote)?.cancel();session.name=String((frame["name"] as? String ?? remote).prefix(128));session.remotePort=frame["port"] as? Int ?? 0;session.timeout?.cancel();session.timeout=nil
            if type=="hello"{send(envelope("welcome"),session)}
            session.connectWait?.resume(returning:peer(session));session.connectWait=nil;try saveConfiguration();flushPending(session);if Date().timeIntervalSince(lastHistoryRequest[remote] ?? .distantPast)>=900{if lastHistoryRequest.count>=256,let oldest=lastHistoryRequest.min(by:{$0.value<$1.value})?.key{lastHistoryRequest.removeValue(forKey:oldest)};lastHistoryRequest[remote]=Date();send(envelope("history.fetch"),session)};publishPeers();return
        }
        guard session.peer==remote else {throw failure("先完成握手")}
        if type=="screen.query"{handleScreenQuery(session);return}
        if type=="screen.command"{try handleScreenCommand(frame,session);return}
        if type=="ping"{send(envelope("pong"),session);return}
        if type=="pong"{return};if type=="history.fetch" {if authorized.contains(remote),Date().timeIntervalSince(lastHistoryResponse[remote] ?? .distantPast)>=900{if lastHistoryResponse.count>=256,let oldest=lastHistoryResponse.min(by:{$0.value<$1.value})?.key{lastHistoryResponse.removeValue(forKey:oldest)};lastHistoryResponse[remote]=Date();emit("lan.history.fetch",["peerId":remote])};return} // No automatic history sharing authorization exists yet.
        if (type=="ack"||type=="notif.ack"),let hash=frame["hash"] as? String {
            do{try journal?.remove(peer:remote,hash:hash)}catch{emit("lan.error",["message":"确认已收到，但离线队列清理失败"])}
            for candidate in sessions.values where candidate.peer==remote{candidate.sentHashes.remove(hash)};if let chosen=bestSession(remote){flushPending(chosen)}
            let matched=receipts.filter{!$0.value.isFile && $0.value.peer==remote && $0.value.hash==hash}
            for (key,value) in matched {receipts.removeValue(forKey:key);value.timer.cancel();value.wait.resume(returning:["confirmed":true,"peerId":remote,"hash":hash])};return
        }
        if type=="history"||type=="history.direct" {
            guard incoming.count<128,let encrypted=frame["payload"] as? String,let hash=frame["hash"] as? String,hash.count==64 else {throw failure("入站历史无效或过多")}
            let plain=try decrypt(encrypted);guard plain.count<=512*1024,let text=String(data:plain,encoding:.utf8),Self.hash(text)==hash else {throw failure("历史文本校验失败")}
            if try duplicate(id,peer:remote,hash:hash,type:"ack",digest:Self.digest(plain),session:session){return};incoming[id]=Incoming(session:session.id,hash:hash,type:"ack",size:size,peer:remote,digest:Self.digest(plain));session.pending+=1;session.pendingBytes+=size;admittedBytes+=size
            emit("lan.history.received",["messageId":id,"peerId":remote,"hash":hash,"content":text,"sourceApp":session.name,"date":Date().timeIntervalSince1970*1000,"type":"text"])
            return
        }
        if type=="notif.post"||type=="notif.dismiss"||type=="notif.clear" {
            guard incoming.count<128 else{throw failure("通知入站任务过多")};var object:[String:Any]=[:];var notificationBytes=Data()
            if let encrypted=frame["payload"] as? String{let raw=try decrypt(encrypted);notificationBytes=raw;guard raw.count<=1024*1024 else{throw failure("通知过大")};if !raw.isEmpty{guard let value=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else{throw failure("通知JSON无效")};object=value}}
            let hash=frame["hash"] as? String ?? "";guard hash.count<=128 else{throw failure("通知hash过长")};if try duplicate(id,peer:remote,hash:hash,type:"notif.ack",digest:Self.digest(notificationBytes),session:session){return};incoming[id]=Incoming(session:session.id,hash:hash,type:"notif.ack",size:size,peer:remote,digest:Self.digest(notificationBytes));session.pending+=1;session.pendingBytes+=size;admittedBytes+=size
            emit("lan.notification.received",["messageId":id,"peerId":remote,"hash":hash,"operation":type,"notification":object,"sourceApp":session.name]);return
        }
        if type=="file.ack" {
            guard let encrypted=frame["payload"] as? String,let ack=try JSONSerialization.jsonObject(with:decrypt(encrypted)) as? [String:Any],let fileId=ack["fileId"] as? String else{throw failure("文件确认无效")}
            if let wait=receipts[fileId],wait.isFile,wait.peer==remote {receipts.removeValue(forKey:fileId);fileProgress.removeValue(forKey:fileId);wait.timer.cancel();if ack["ok"] as? Bool==true{wait.wait.resume(returning:["confirmed":true,"fileId":fileId,"peerId":remote])}else{wait.wait.resume(throwing:failure("对端拒收文件：\(ack["error"] as? String ?? "ioError")"))}};return
        }
        if type=="file.meta" {try receiveFileMeta(frame,session);return}
        if type=="file.chunk" {try receiveFileChunk(frame,session);return}
    }
    func acknowledge(messageId:String)throws {
        guard let entry=incoming.removeValue(forKey:messageId) else {throw failure("确认任务不存在或已断开")}
        admittedBytes=max(0,admittedBytes-entry.size)
        let routes=entry.routes.compactMap{sessions[$0]}.filter{!$0.closed && $0.peer==entry.peer}
        guard !routes.isEmpty else {throw failure("会话已断开，不能确认旧入站任务")}
        if let owner=sessions[entry.session]{owner.pending=max(0,owner.pending-1);owner.pendingBytes=max(0,owner.pendingBytes-entry.size)}
        var ack=envelope(entry.type);ack["hash"]=entry.hash;if entry.type=="file.ack"{ack["payload"]=try encrypt(JSONSerialization.data(withJSONObject:["fileId":messageId,"ok":true]))};if !entry.hash.isEmpty{for route in routes{send(ack,route)}}
        for candidate in Array(sessions.values){do{try drain(candidate)}catch{close(candidate,"无效协议数据")};read(candidate)}
    }
    private func duplicate(_ id:String,peer:String,hash:String,type:String,digest:String,session:Session)throws->Bool{guard var entry=incoming[id]else{return false};guard entry.peer==peer,entry.hash==hash,entry.type==type,entry.digest==digest else{throw failure("相同消息ID的数据或身份不一致")};entry.routes.insert(session.id);incoming[id]=entry;return true}

    func sendText(peerId:String,text:String)async throws->[String:Any]{
        guard !text.isEmpty,text.utf8.count<=512*1024 else {throw failure("文本必须为1–512 KiB")}
        guard let session=bestSession(peerId) else {throw failure("设备未连接")}
        guard receipts.count<32 else {throw failure("待确认发送已达32条")}
        try loadJournal();let hash=Self.hash(text),id=UUID().uuidString
        var frame=envelope("history.direct",id:id);frame["hash"]=hash;frame["payload"]=try encrypt(Data(text.utf8));let stored=try journal!.put(peer:peerId,hash:hash,type:"history.direct",frame:JSONSerialization.data(withJSONObject:frame));frame=(try JSONSerialization.jsonObject(with:stored.frame) as? [String:Any]) ?? frame
        return try await withCheckedThrowingContinuation { continuation in
            let timeout=Task { [weak self] in try? await Task.sleep(nanoseconds:12_000_000_000);guard !Task.isCancelled,let self,let wait=self.receipts.removeValue(forKey:id) else{return};wait.wait.resume(throwing:self.failure("发送未确认：12秒内未收到对端落库ACK")) }
            receipts[id]=Receipt(peer:peerId,hash:hash,wait:continuation,timer:timeout);session.sentHashes.insert(hash);send(frame,session)
        }
    }
    /// The caller must authorize the source path through its file picker before invoking this method.
    func sendFile(peerId:String,path:String) async throws->[String:Any]{
        let source=URL(fileURLWithPath:path);let attributes=try FileManager.default.attributesOfItem(atPath:path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let archive=try FolderTransferService.archive(source,temporaryDirectory:stateRoot.appendingPathComponent("folder-snapshots",isDirectory:true));defer{try? FileManager.default.removeItem(at:archive)}
            return try await sendPreparedFile(peerId:peerId,path:archive.path,folderName:source.lastPathComponent)
        }
        return try await sendPreparedFile(peerId:peerId,path:path,folderName:nil)
    }
    private func sendPreparedFile(peerId:String,path:String,folderName:String?) async throws->[String:Any]{
        guard let session=bestSession(peerId) else{throw failure("设备未连接")}
        guard receipts.count<32 else{throw failure("待确认任务过多")}
        let source=URL(fileURLWithPath:path);let values=try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=1024*1024*1024 else{throw failure("仅支持不超过1 GiB的普通文件")}
        let read=try FileHandle(forReadingFrom:source);defer{try? read.close()}
        var digest=SHA256();var counted=0
        while let data=try read.read(upToCount:1024*1024),!data.isEmpty{counted+=data.count;guard counted<=1024*1024*1024 else{throw failure("文件读取超限")};digest.update(data:data)}
        guard counted==size else{throw failure("文件在读取时发生变化")};try read.seek(toOffset:0)
        let hash=digest.finalize().map{String(format:"%02x",$0)}.joined(),fileId=UUID().uuidString,chunkSize=1024*1024,chunks=max(1,(size+chunkSize-1)/chunkSize)
        var meta:[String:Any]=["fileId":fileId,"name":folderName.map{$0+".zip"} ?? source.lastPathComponent,"size":size,"chunkSize":chunkSize,"chunks":chunks,"sha256":hash];if let folderName{meta["folderFormat"]="zip-store-v1";meta["folderName"]=folderName}
        var header=envelope("file.meta");header["hash"]=hash;header["payload"]=try encrypt(JSONSerialization.data(withJSONObject:meta))
        // Register the receipt before writing metadata, so a fast rejection cannot be missed.
        return try await withCheckedThrowingContinuation { continuation in
            let began=Date();fileProgress[fileId]=began
            let timeout=Task { [weak self,weak session] in while !Task.isCancelled{do{try await Task.sleep(nanoseconds:5_000_000_000)}catch{return};guard let self,self.receipts[fileId] != nil else{return};if Self.fileTransferExpired(started:began.timeIntervalSince1970,progress:(self.fileProgress[fileId] ?? began).timeIntervalSince1970,now:Date().timeIntervalSince1970){guard let wait=self.receipts.removeValue(forKey:fileId)else{return};self.fileProgress.removeValue(forKey:fileId);wait.wait.resume(throwing:self.failure("文件发送空闲120秒或总时长30分钟，结果未确认"));if let session{self.close(session,"文件传输超时")};return}} }
            receipts[fileId]=Receipt(peer:peerId,hash:hash,wait:continuation,timer:timeout,isFile:true)
            Task { @MainActor in
                do{try await self.write(header,session);if self.receipts[fileId] != nil{self.fileProgress[fileId]=Date()}
                    for index in 0..<chunks {
                        guard self.receipts[fileId] != nil,!session.closed else{break}
                        let bytes=try read.read(upToCount:chunkSize) ?? Data();var chunk=UInt32(index).bigEndian;var data=Data(bytes:&chunk,count:4);data.append(bytes)
                        var frame=self.envelope("file.chunk",id:fileId);frame["payload"]=try self.encrypt(data);try await self.write(frame,session);if self.receipts[fileId] != nil{self.fileProgress[fileId]=Date()}
                    }
                }catch{if let receipt=self.receipts.removeValue(forKey:fileId){self.fileProgress.removeValue(forKey:fileId);receipt.timer.cancel();receipt.wait.resume(throwing:error)}}
            }
        }
    }
    private func write(_ object:[String:Any],_ session:Session)async throws{
        guard !session.closed else{throw failure("会话已关闭")};let json=try JSONSerialization.data(withJSONObject:object);guard json.count<=2*1024*1024 else{throw failure("帧过大")};var length=UInt32(json.count).bigEndian;var data=Data(bytes:&length,count:4);data.append(json)
        if session.tunnelSend != nil {while session.outboundBytes+data.count>4*1024*1024||session.outboundFrames>=32{guard !session.closed,!Task.isCancelled else{throw failure("隧道发送取消")};try await Task.sleep(nanoseconds:1_000_000)};try await enqueueTunnel(data,session).value;return}
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in guard let connection=session.connection else{continuation.resume(throwing:failure("隧道未连接"));return};connection.send(content:data,completion:.contentProcessed({error in if let error{continuation.resume(throwing:error)}else{continuation.resume()}})) }
    }
    private func receiveFileMeta(_ frame:[String:Any],_ session:Session)throws{
        guard let encrypted=frame["payload"] as? String,let meta=try JSONSerialization.jsonObject(with:decrypt(encrypted)) as? [String:Any],let id=meta["fileId"] as? String,id.count<=128,let filename=meta["name"] as? String,let size=meta["size"] as? Int,let chunkSize=meta["chunkSize"] as? Int,let chunks=meta["chunks"] as? Int,let sha=meta["sha256"] as? String else{throw failure("文件元数据无效")}
        let folder=meta["folderName"] as? String
        if meta["folderFormat"] != nil||folder != nil {guard meta["folderFormat"] as? String=="zip-store-v1",let folder,!folder.isEmpty,size<=FolderTransferService.maximum else{sendFileReject(id,session,"ioError");return}}
        guard files[id]==nil,incoming[id]==nil,files.count<8,size>=0,size<=1024*1024*1024,chunkSize>0,chunkSize<=1024*1024,chunks==max(1,(size+chunkSize-1)/chunkSize),sha.count==64,filename.utf8.count<=255,!filename.isEmpty,!filename.contains("/"),!filename.contains("\\"),!filename.contains(":"),!filename.contains("\0"),filename != ".",filename != ".." else{sendFileReject(id,session,"tooLarge");return}
        do{try FileManager.default.createDirectory(at:receiveRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let path=receiveRoot.appendingPathComponent(UUID().uuidString+".part");guard FileManager.default.createFile(atPath:path.path,contents:nil,attributes:[.posixPermissions:0o600])else{throw failure("无法创建接收文件")};let handle=try FileHandle(forWritingTo:path);files[id]=IncomingFile(id:id,session:session.id,name:filename,path:path,handle:handle,size:size,chunks:chunks,chunkSize:chunkSize,sha:sha,folderName:folder);startFileExpiry()}catch{sendFileReject(id,session,"ioError")}
    }
    private func receiveFileChunk(_ frame:[String:Any],_ session:Session)throws{
        guard let id=frame["msgId"] as? String,let file=files[id] else{return};guard file.session==session.id,let encrypted=frame["payload"] as? String else{throw failure("文件分块缺少有效元数据")}
        do{let raw=try decrypt(encrypted);guard raw.count>=4 else{throw failure("分块无效")};let index=raw.prefix(4).reduce(0){($0<<8)|Int($1)};let bytes=Data(raw.dropFirst(4));let expected=min(file.chunkSize,file.size-file.written)
            guard index==file.index,bytes.count==expected,file.index<file.chunks else{throw failure("分块顺序或大小错误")}
            try file.handle.write(contentsOf:bytes);file.digest.update(data:bytes);file.index+=1;file.written+=bytes.count;file.last=Date()
            if file.index==file.chunks {
                try file.handle.synchronize();try file.handle.close();guard file.written==file.size,file.digest.finalize().map({String(format:"%02x",$0)}).joined()==file.sha else{throw failure("文件哈希不一致")}
                var destination:URL
                if let folder=file.folderName{destination=try FolderTransferService.extract(file.path,into:receiveRoot,expectedName:folder);try FileManager.default.removeItem(at:file.path)}else{destination=receiveRoot.appendingPathComponent(file.name);if FileManager.default.fileExists(atPath:destination.path){destination=receiveRoot.appendingPathComponent(UUID().uuidString+"-"+file.name)};try FileManager.default.moveItem(at:file.path,to:destination)}
                files.removeValue(forKey:id)
                incoming[id]=Incoming(session:session.id,hash:file.sha,type:"file.ack",size:0,peer:session.peer ?? "",digest:file.sha);session.pending+=1
                emit("lan.file.received",["messageId":id,"peerId":session.peer ?? "","path":destination.path,"name":destination.lastPathComponent,"isFolder":file.folderName != nil,"size":file.size,"sha256":file.sha,"sourceApp":session.name])
            }
        }catch{files.removeValue(forKey:id);try? file.handle.close();try? FileManager.default.removeItem(at:file.path);sendFileReject(id,session,"hashMismatch")}
    }
    private func sendFileReject(_ id:String,_ session:Session,_ error:String){var frame=envelope("file.ack");frame["payload"]=try? encrypt(JSONSerialization.data(withJSONObject:["fileId":id,"ok":false,"error":error]));send(frame,session)}
    private func startFileExpiry(){
        guard fileTimer==nil else{return};fileTimer=Task { [weak self] in
            while !Task.isCancelled {try? await Task.sleep(nanoseconds:5_000_000_000);guard !Task.isCancelled,let self else{return};for (id,file) in self.files.filter({Date().timeIntervalSince($0.value.last)>120}){self.files.removeValue(forKey:id);try? file.handle.close();try? FileManager.default.removeItem(at:file.path);if let session=self.sessions[file.session]{self.sendFileReject(id,session,"ioError")}};if self.files.isEmpty{self.fileTimer=nil;return}}
        }
    }
    /// A network-interface owner may invalidate LAN routes without shutting down relay failover.
    func disconnectLAN(peerId:String){for session in Array(sessions.values)where session.peer==peerId && session.connection != nil{close(session,"局域网连接已断开")}}
    static func fileTransferExpired(started:TimeInterval,progress:TimeInterval,now:TimeInterval)->Bool{now-progress>=120||now-started>=1800}
    func status()->[String:Any]{["peerId":peerId,"name":name,"port":port,"listening":listening,"lanEnabled":running,"relayRoutes":sessions.values.filter{$0.connection==nil && !$0.closed}.count,"maintenanceActive":maintenance != nil,"peers":visiblePeers(),"routeCount":sessions.values.filter{$0.peer != nil && !$0.closed}.count,"pendingReceipts":receipts.count,"pendingOffline":journal?.records.count ?? 0,"clipboardAuthorized":Array(authorized),"notificationAuthorized":Array(notificationAuthorized),"pendingInbound":incoming.count,"fileTransfer":true,"automaticDiscovery":true,"scanning":scanActive]}
    /// LAN preference is independent of the authenticated relay lifecycle.
    func stopLAN(){
        running=false;cancelScan();listener?.cancel();listener=nil;listening=false
        for task in reconnect.values{task.cancel()};reconnect.removeAll();reconnectTokens.removeAll()
        for session in Array(sessions.values)where session.connection != nil{close(session,"局域网同步已关闭")}
        updateMaintenance()
    }
    /// Compatibility for standalone probes; production shutdown should call stopAll explicitly.
    func stop(){stopAll()}
    private var hasActiveTransport:Bool{running||sessions.values.contains{$0.connection==nil && !$0.closed}}
    private func updateMaintenance(){if stoppingAll{maintenance?.cancel();maintenance=nil;return};if hasActiveTransport{startMaintenance()}else{maintenance?.cancel();maintenance=nil}}
    /// Explicit retry hook also lets connectivity owners wake stale pending work without dialing LAN.
    func retryPending(now:Date=Date()){for session in Array(sessions.values)where session.peer != nil{flushPending(session,at:now)}}
    func stopAll(){stoppingAll=true;for(_,task)in screenTasks.values{task.cancel()};screenTasks.removeAll();screenBusyOwner=nil;maintenance?.cancel();maintenance=nil;running=false;cancelScan();for task in reconnect.values{task.cancel()};reconnect.removeAll();reconnectTokens.removeAll();fileTimer?.cancel();fileTimer=nil;for file in files.values{try? file.handle.close();try? FileManager.default.removeItem(at:file.path)};files.removeAll();listener?.cancel();listener=nil;listening=false;for session in Array(sessions.values){close(session,"同步已停止")};for receipt in receipts.values{receipt.timer.cancel();receipt.wait.resume(throwing:failure("同步已停止，发送未确认"))};receipts.removeAll();fileProgress.removeAll();incoming.removeAll();admittedBytes=0;journal=nil;journalLoaded=false;lastFlush.removeAll();lastHistoryRequest.removeAll();lastHistoryResponse.removeAll();stoppingAll=false}
    private func close(_ session:Session,_ reason:String,preservingText:Bool=false){
        guard !session.closed else{return};session.closed=true;let onClose=session.onClose;session.onClose=nil;for(id,value)in screenTasks.filter({$0.value.0==session.id}){value.1.cancel();screenTasks.removeValue(forKey:id)};session.screenChallenge=nil;for (id,file) in files.filter({$0.value.session==session.id}){files.removeValue(forKey:id);try? file.handle.close();try? FileManager.default.removeItem(at:file.path)};lastFlush.removeValue(forKey:session.id);session.timeout?.cancel();session.writeTail?.cancel();session.writeTail=nil;session.connection?.cancel();sessions.removeValue(forKey:session.id);session.connectWait?.resume(throwing:failure(reason));session.connectWait=nil
        for (id,var entry) in incoming.filter({$0.value.routes.contains(session.id)}){entry.routes.remove(session.id);if entry.routes.isEmpty{incoming.removeValue(forKey:id);admittedBytes=max(0,admittedBytes-entry.size)}else{incoming[id]=entry}}
        if let remote=session.peer {let fallback=bestSession(remote);for (id,wait) in receipts.filter({$0.value.peer==remote}){if !wait.isFile,(preservingText||fallback != nil){continue};receipts.removeValue(forKey:id);fileProgress.removeValue(forKey:id);wait.timer.cancel();wait.wait.resume(throwing:failure(reason+"，发送未确认"))};if !stoppingAll,let fallback{flushPending(fallback,resetInFlight:true)}}
        if let remote=session.peer,running,(authorized.contains(remote)||notificationAuthorized.contains(remote)||journal?.has(peer:remote)==true),peerId<remote {scheduleReconnect(remote)}
        publishPeers();updateMaintenance();onClose?()
    }
    private func send(_ object:[String:Any],_ session:Session){
        guard !session.closed,let json=try? JSONSerialization.data(withJSONObject:object),json.count<=2*1024*1024 else{return}
        var length=UInt32(json.count).bigEndian;var data=Data(bytes:&length,count:4);data.append(json)
        if session.tunnelSend != nil {do{let task=try enqueueTunnel(data,session);Task { @MainActor [weak self,weak session] in do{try await task.value}catch{guard let self,let session else{return};self.close(session,"隧道发送失败")}}}catch{close(session,"隧道发送队列超限")};return}
        session.connection?.send(content:data,completion:.contentProcessed({ [weak self,weak session] error in if error != nil {Task { @MainActor in guard let self,let session else{return};self.close(session,"发送失败")}} }))
    }
    /// Serialize complete encoded frames: RelayStream record awaits must never interleave frame bytes.
    func broadcastScreenState()async{for session in Array(sessions.values)where session.peer != nil{handleScreenQuery(session)}}
    private func handleScreenQuery(_ session:Session){
        guard screenTasks.count<32 else{return};let taskId=UUID().uuidString
        let task=Task { @MainActor [weak self,weak session] in guard let self,let session else{return};defer{self.screenTasks.removeValue(forKey:taskId)};let state=await self.screenStateProvider?() ?? [:];guard !Task.isCancelled,!session.closed,self.sessions[session.id]===session else{return};let challenge=UUID().uuidString;session.screenChallenge=challenge;session.screenIssued=Date();let payload:[String:Any]=["controlMode":"connected-v1","configured":state["configured"] as? Bool ?? false,"locked":state["locked"] ?? NSNull(),"helper":state["helper"] as? Bool ?? state["accessibility"] as? Bool ?? false,"challenge":challenge];do{var frame=self.envelope("screen.state");frame["payload"]=try self.encrypt(JSONSerialization.data(withJSONObject:payload));self.send(frame,session)}catch{self.emit("lan.error",["message":"无法返回屏幕控制状态"])} }
        screenTasks[taskId]=(session.id,task)
    }
    private func handleScreenCommand(_ frame:[String:Any],_ session:Session)throws{
        guard let encrypted=frame["payload"] as? String,let object=try JSONSerialization.jsonObject(with:decrypt(encrypted)) as? [String:Any],let action=object["action"] as? String,let challenge=object["challenge"] as? String,let id=frame["msgId"] as? String,challenge.count<=128 else{throw failure("屏幕控制命令无效")}
        guard session.screenChallenge==challenge,Date().timeIntervalSince(session.screenIssued)<120 else{screenResult(session,id:id,challenge:challenge,status:"sessionUnavailable");return}
        session.screenChallenge=nil // Consume before all asynchronous checks and execution.
        guard ["lock","unlock"].contains(action)else{screenResult(session,id:id,challenge:challenge,status:"invalidAction");return}
        guard screenTasks.count<32,screenBusyOwner==nil else{screenResult(session,id:id,challenge:challenge,status:"busy");return}
        if action=="unlock",Date().timeIntervalSince(lastUnlock)<5{screenResult(session,id:id,challenge:challenge,status:"cooldown");return}
        let taskId=UUID().uuidString;screenBusyOwner=taskId
        let task=Task { @MainActor [weak self,weak session] in guard let self,let session else{return};defer{self.screenTasks.removeValue(forKey:taskId);if self.screenBusyOwner==taskId{self.screenBusyOwner=nil}};let state=await self.screenStateProvider?() ?? [:];guard !Task.isCancelled,!session.closed,self.sessions[session.id]===session else{return}
            guard state["configured"] as? Bool==true else{self.screenResult(session,id:id,challenge:challenge,status:"notConfigured");return};guard (state["helper"] as? Bool ?? state["accessibility"] as? Bool)==true else{self.screenResult(session,id:id,challenge:challenge,status:"accessibilityRequired");return};guard let handler=self.screenCommandHandler else{self.screenResult(session,id:id,challenge:challenge,status:"unavailable");return}
            if action=="unlock"{self.lastUnlock=Date()};let status=await handler(action);guard !Task.isCancelled,!session.closed,self.sessions[session.id]===session else{return};let allowed=Set(["ok","unavailable","helperMissing","permissionOrHelper","cancelled","notConfirmed","invalidAction","busy","cooldown","notConfigured","sessionUnavailable","accessibilityRequired","secureFieldUnavailable","secureFieldWriteFailed","secureConfirmFailed","credentialInvalid","credentialUnavailable"]);self.screenResult(session,id:id,challenge:challenge,status:allowed.contains(status) ? status:"notConfirmed")
        };screenTasks[taskId]=(session.id,task)
    }
    private func screenResult(_ session:Session,id:String,challenge:String,status:String){do{var frame=envelope("screen.result");frame["hash"]=id;frame["payload"]=try encrypt(JSONSerialization.data(withJSONObject:["status":status,"challenge":challenge]));send(frame,session)}catch{emit("lan.error",["message":"无法返回屏幕控制结果"])}}
    private func enqueueTunnel(_ data:Data,_ session:Session)throws->Task<Void,Error>{
        guard session.outboundFrames<32,session.outboundBytes+data.count<=4*1024*1024,let tunnel=session.tunnelSend else{throw failure("隧道发送队列超限")}
        let previous=session.writeTail;session.outboundFrames+=1;session.outboundBytes+=data.count
        let task=Task { @MainActor [weak session] in guard let session else{throw CancellationError()};defer{session.outboundFrames-=1;session.outboundBytes-=data.count};if let previous{try await previous.value};guard !session.closed,!Task.isCancelled else{throw CancellationError()};try await tunnel(data) };session.writeTail=task;return task
    }
    private func envelope(_ type:String,id:String=UUID().uuidString)->[String:Any]{var frame:[String:Any]=["v":3,"type":type,"msgId":id,"peerId":peerId,"name":name,"port":port,"ts":Date().timeIntervalSince1970];if type=="hello"||type=="welcome"{frame["sessionPolicy"]="peer-id-v1"};return frame}
    private func encrypt(_ data:Data)throws->String{let sealed=try AES.GCM.seal(data,using:key);guard let combined=sealed.combined else{throw failure("加密失败")};return combined.base64EncodedString()}
    private func decrypt(_ value:String)throws->Data{guard let data=Data(base64Encoded:value),data.count>=28 else {throw failure("无效密文")};return try AES.GCM.open(AES.GCM.SealedBox(combined:data),using:key)}
    private static func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func hash(_ text:String)->String{let normalized=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n");return SHA256.hash(data:Data(normalized.utf8)).map{String(format:"%02x",$0)}.joined()}
    private func bestSession(_ peer:String)->Session?{sessions.values.filter{$0.peer==peer && !$0.closed}.sorted{a,b in if (a.connection != nil) != (b.connection != nil){return a.connection != nil};let preferred=peerId<peer;if a.outbound != b.outbound{return a.outbound==preferred};return a.id<b.id}.first}
    private func visiblePeers()->[[String:Any]]{Set(sessions.values.compactMap{$0.closed ? nil:$0.peer}).sorted().compactMap{bestSession($0)}.map(peer)}
    private func peer(_ session:Session)->[String:Any]{let id=session.peer ?? "";return ["id":id,"name":session.name,"address":"\(session.host):\(session.remotePort)","online":true,"transport":session.connection==nil ? "relay" : "lan","outbound":session.outbound,"syncClipboard":authorized.contains(id),"syncNotifications":notificationAuthorized.contains(id),"pending":journal?.forPeer(id).count ?? 0,"pendingReceipts":receipts.values.filter{$0.peer==id}.count,"connectedAt":session.connectedAt.map{$0.timeIntervalSince1970*1000 as Any} ?? NSNull(),"recentSend":NSNull(),"recentAck":NSNull(),"recentReceive":NSNull(),"error":NSNull()]}
    private func publishPeers(){emit("lan.peers",["peers":visiblePeers()])}
    private func hostname(_ endpoint:NWEndpoint)->String{if case .hostPort(let host,_) = endpoint{return "\(host)"};return "\(endpoint)"}
    private func failure(_ message:String)->BridgeFailure{BridgeFailure(code:"LAN_ERROR",message:message)}
}
