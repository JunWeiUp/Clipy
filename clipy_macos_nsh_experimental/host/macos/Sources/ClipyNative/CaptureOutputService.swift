import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum CaptureOutputService {
    static func export(_ p:[String:Any]) throws -> [String:Any] {
        guard let path=p["path"] as? String,let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width*image.height<=80_000_000 else {throw BridgeFailure(code:"INVALID_IMAGE",message:"无法读取截图")}
        let format=(p["format"] as? String ?? "png").lowercased()
        let types:[String:(UTType,String)]=["png":(.png,"png"),"jpeg":(.jpeg,"jpg"),"jpg":(.jpeg,"jpg"),"tiff":(.tiff,"tiff"),"heic":(.heic,"heic")]
        guard let type=types[format] else{throw BridgeFailure(code:"UNSUPPORTED_FORMAT",message:"请选择 PNG、JPEG、TIFF 或 HEIC")}
        let directory:URL
        if let target=p["directory"] as? String,!target.isEmpty {guard target.hasPrefix("/") else{throw BridgeFailure(code:"INVALID_DIRECTORY",message:"保存目录必须为完整路径")};directory=URL(fileURLWithPath:target,isDirectory:true)}
        else {directory=FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask)[0].appendingPathComponent("Screenshots",isDirectory:true)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let output=directory.appendingPathComponent("Screenshot-"+UUID().uuidString).appendingPathExtension(type.1)
        let temporary=directory.appendingPathComponent(".clipy-"+UUID().uuidString)
        guard let destination=CGImageDestinationCreateWithURL(temporary as CFURL,type.0.identifier as CFString,1,nil) else{throw BridgeFailure(code:"ENCODER_UNAVAILABLE",message:"系统不支持此图片格式")}
        let scale=p["scale"] as? Double ?? 1
        guard scale.isFinite,scale>0,scale<=1 else{throw BridgeFailure(code:"INVALID_SCALE",message:"缩放参数无效")}
        let width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
        var rendered=image
        if scale != 1 || type.0 == .jpeg {
            guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw BridgeFailure(code:"IMAGE_MEMORY",message:"无法创建图片输出缓冲区")}
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height));context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));guard let bitmap=context.makeImage() else{throw BridgeFailure(code:"IMAGE_MEMORY",message:"图片输出失败")};rendered=bitmap
        }
        let quality=max(0,min(1,(p["quality"] as? Double ?? 85)/100))
        CGImageDestinationAddImage(destination,rendered,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else{try? FileManager.default.removeItem(at:temporary);throw BridgeFailure(code:"ENCODING_FAILED",message:"截图编码失败")}
        do {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path);try FileManager.default.moveItem(at:temporary,to:output)}catch{try? FileManager.default.removeItem(at:temporary);throw error}
        if p["sound"] as? Bool == true {NSSound(named:"Tink")?.play()}
        return ["path":output.path,"format":format,"width":width,"height":height]
    }
}
