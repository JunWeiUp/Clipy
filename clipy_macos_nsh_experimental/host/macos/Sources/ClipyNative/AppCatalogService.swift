import AppKit
import Foundation
import CryptoKit

/// Application metadata and lazily requested system icons only; never reads application user data.
@MainActor enum AppCatalogService {
    static func list()->[[String:Any]]{
        var found:[String:[String:Any]]=[:]
        for app in NSWorkspace.shared.runningApplications{if let url=app.bundleURL,let value=info(url),let id=value["bundleId"] as? String{found[id]=value;if found.count>=512{break}}}
        let roots=[URL(fileURLWithPath:"/Applications",isDirectory:true),URL(fileURLWithPath:"/System/Applications",isDirectory:true),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true)]
        for root in roots where found.count<512{scan(root,depth:0,found:&found)}
        return limited(found.values.sorted{($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending})
    }
    static func appInfo(paths:[String])->[[String:Any]]{var result:[String:[String:Any]]=[:];for path in paths.prefix(128){if let value=info(URL(fileURLWithPath:path)),let id=value["bundleId"] as? String{result[id]=value}};return limited(Array(result.values).sorted{($0["name"] as? String ?? "")<($1["name"] as? String ?? "")})}
    private static func limited(_ values:[[String:Any]])->[[String:Any]]{var bytes=2,result:[[String:Any]]=[];for value in values.prefix(512){guard let data=try? JSONSerialization.data(withJSONObject:value),bytes+data.count+1<=512*1024 else{break};result.append(value);bytes+=data.count+1};return result}
    private static func scan(_ root:URL,depth:Int,found:inout [String:[String:Any]]){
        guard depth<=1,let entries=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])else{return}
        for url in entries.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}){if found.count>=512{return};if url.pathExtension.lowercased()=="app"{if let value=info(url),let id=value["bundleId"] as? String{found[id]=value};continue};guard depth<1,let attrs=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),attrs.isDirectory==true,attrs.isSymbolicLink != true else{continue};scan(url,depth:depth+1,found:&found)}
    }
    private static func info(_ path:URL)->[String:Any]?{
        guard path.pathExtension.lowercased()=="app" else{return nil};let file=path.appendingPathComponent("Contents/Info.plist");guard let attrs=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? Int.max)<=1024*1024,let data=try? Data(contentsOf:file),let dictionary=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],let id=dictionary["CFBundleIdentifier"] as? String,!id.isEmpty,id.count<=256 else{return nil};let name=(dictionary["CFBundleDisplayName"] as? String) ?? (dictionary["CFBundleName"] as? String) ?? path.deletingPathExtension().lastPathComponent;return ["bundleId":id,"name":String(name.prefix(256)),"path":path.standardizedFileURL.path]
    }
    /// Called for a source application on demand; full catalog scans never export icons.
    static func icon(root:URL,bundleId:String)throws->String?{
        guard !bundleId.isEmpty,bundleId.count<=256,let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleId) ?? NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier==bundleId})?.bundleURL else{return nil}
        let directory=root.appendingPathComponent("app-icons",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let digest=SHA256.hash(data:Data(bundleId.utf8)).map{String(format:"%02x",$0)}.joined();let output=directory.appendingPathComponent("app-"+digest+".png")
        if FileManager.default.fileExists(atPath:output.path){try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:output.path);try prune(directory);return output.path}
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:256,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap)else{return nil}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context;NSColor.clear.setFill();CGRect(x:0,y:0,width:64,height:64).fill();NSWorkspace.shared.icon(forFile:app.path).draw(in:CGRect(x:0,y:0,width:64,height:64),from:.zero,operation:.sourceOver,fraction:1);NSGraphicsContext.restoreGraphicsState();guard let png=bitmap.representation(using:.png,properties:[:]),png.count<=128*1024 else{return nil};try png.write(to:output,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path);try prune(directory);return output.path
    }
    private static func prune(_ directory:URL)throws{var entries=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]).filter{$0.lastPathComponent.hasPrefix("app-")&&$0.pathExtension=="png"}.map{url in (url,try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]))};entries.sort{($0.1.contentModificationDate ?? .distantPast)<($1.1.contentModificationDate ?? .distantPast)};var total=entries.reduce(0){$0+($1.1.fileSize ?? 0)},count=entries.count;for(url,attrs)in entries where total>8*1024*1024||count>128{try FileManager.default.removeItem(at:url);total-=attrs.fileSize ?? 0;count-=1}}
}
