import AppKit
import Foundation
import CoreImage
import ImageIO
import Vision
import MachO
import Darwin

/// Renders the TSX scene into a new PNG at the source's pixel dimensions.
/// The caller checks the source path against its user-selected file allowlist.
enum ImageEditorService {
    private static let foregroundCache=ForegroundMaskCache()
    static func closeCaches(){foregroundCache.clear()}
    /// Invoked only by the short-lived helper worker before NSApplication/Keychain startup.
    static func foregroundMaskWorker(sourcePath:String,maskPath:String)throws{
        guard #available(macOS 14.0,*)else{throw BridgeFailure(code:"PLATFORM_VERSION",message:"移除背景需要macOS14")}
        guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:sourcePath) as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,Int64(w)*Int64(h)<=80_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil)else{throw BridgeFailure(code:"INVALID_IMAGE",message:"无法读取前景图像")}
        let handler=VNImageRequestHandler(cgImage:image),request=VNGenerateForegroundInstanceMaskRequest();try handler.perform([request]);guard let observation=request.results?.first,!observation.allInstances.isEmpty else{throw BridgeFailure(code:"NO_FOREGROUND",message:"未检测到可分离前景")};let mask=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler);let ci=CIImage(cvPixelBuffer:mask);guard let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(ci,from:ci.extent),let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:maskPath) as CFURL,"public.png" as CFString,1,nil)else{throw BridgeFailure(code:"IMAGE_MASK",message:"无法生成前景蒙版")};CGImageDestinationAddImage(destination,cg,nil);guard CGImageDestinationFinalize(destination)else{throw BridgeFailure(code:"IMAGE_MASK",message:"无法编码前景蒙版")};try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:maskPath)
    }
    static func render(_ payload: [String: Any], directory: URL) throws -> [String: Any] {
        try Task.checkCancellation()
        guard let path = payload["imagePath"] as? String,
              let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0, rawWidth <= 120000, rawHeight <= 120000,
              Int64(rawWidth) * Int64(rawHeight) <= 80_000_000,
              var source = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BridgeFailure(code: "INVALID_IMAGE", message: "无法读取图片或超出 8000 万像素上限")
        }
        let effects = payload["effects"] as? [String: Any] ?? [:]
        let preset=(effects["preset"] as? String ?? "None").lowercased()
        let filters=["noir":"CIPhotoEffectNoir","mono":"CIPhotoEffectMono","chrome":"CIPhotoEffectChrome","fade":"CIPhotoEffectFade","instant":"CIPhotoEffectInstant"]
        var base=CIImage(cgImage:source)
        if let filter=filters[preset]{base=base.applyingFilter(filter)}else if preset=="sepia"{base=base.applyingFilter("CISepiaTone",parameters:[kCIInputIntensityKey:0.8])}else if preset=="vivid"{base=base.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:1.35,kCIInputContrastKey:1.1])}else if preset != "none" && !preset.isEmpty{throw BridgeFailure(code:"INVALID_PRESET",message:"不支持的图像滤镜")}
        if effects["invert"] as? Bool==true{base=base.applyingFilter("CIColorInvert")}
        if effects["removeBackground"] as? Bool==true{let mask=try foregroundCache.mask(for:URL(fileURLWithPath:path));guard let image=CIImage(contentsOf:mask)else{throw BridgeFailure(code:"IMAGE_MASK",message:"无法读取前景蒙版")};base=base.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:base.extent),kCIInputMaskImageKey:image])}

        if preset != "none" || effects["invert"] as? Bool==true || effects["removeBackground"] as? Bool==true{guard let rendered=CIContext(options:[.cacheIntermediates:false]).createCGImage(base,from:base.extent)else{throw BridgeFailure(code:"IMAGE_EFFECT",message:"无法应用图像特效")};source=rendered}
        let brightness = try number(effects["brightness"], fallback: 0, min: -1, max: 1)
        let contrast = try number(effects["contrast"], fallback: 1, min: 0, max: 4)
        let saturation = try number(effects["saturation"], fallback: 1, min: 0, max: 4)
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let filtered = CIImage(cgImage: source).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
            if let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(filtered, from: filtered.extent) { source = rendered }
        }
        let sharpness = try number(effects["sharpness"], fallback: 0, min: 0, max: 4)
        if sharpness > 0 {
            let filtered = CIImage(cgImage: source).applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness])
            if let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(filtered, from: filtered.extent) { source = rendered }
        }
        let width = source.width, height = source.height
        guard width > 0, height > 0, width <= 120000, height <= 120000,
              Int64(width) * Int64(height) <= 80_000_000,
              let rows = payload["annotations"] as? [[String: Any]], rows.count <= 500,
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: output) else {
            throw BridgeFailure(code: "IMAGE_LIMIT", message: "图片超出 8000 万像素上限或标注超过 500 项")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.clear(CGRect(x: 0, y: 0, width: width, height: height))
        c.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        c.translateBy(x: 0, y: CGFloat(height))
        c.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        do {
            for row in rows { try Task.checkCancellation(); try draw(row, source: source, context: c) }
        } catch {
            NSGraphicsContext.restoreGraphicsState()
            throw error
        }
        NSGraphicsContext.restoreGraphicsState()
        var result = output
        if payload["preview"] as? Bool != true, var final = output.cgImage {
            if let crop = payload["crop"] as? [String: Any] {
                let rectangle = CGRect(x: try number(crop["x"], fallback: 0), y: try number(crop["y"], fallback: 0), width: try number(crop["width"], fallback: 0, min: 1, max: 120000), height: try number(crop["height"], fallback: 0, min: 1, max: 120000)).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
                guard !rectangle.isEmpty, let cropped = final.cropping(to: rectangle) else { throw BridgeFailure(code: "INVALID_CROP", message: "裁剪区域无效") }; final = cropped
            }
            var transformed = CIImage(cgImage: final)
            let rotation = payload["rotation"] as? Int ?? 0
            switch ((rotation % 360) + 360) % 360 { case 90: transformed = transformed.oriented(.right); case 180: transformed = transformed.oriented(.down); case 270: transformed = transformed.oriented(.left); default: break }
            if payload["flipH"] as? Bool == true { transformed = transformed.oriented(.upMirrored) }
            if payload["flipV"] as? Bool == true { transformed = transformed.oriented(.downMirrored) }
            if let finalImage = CIContext(options: [.cacheIntermediates: false]).createCGImage(transformed, from: transformed.extent) { result = NSBitmapImageRep(cgImage: finalImage) }
        }
        let padding = Int(try number(effects["padding"], fallback: 48, min: 0, max: 200))
        if effects["beautify"] as? Bool == true, payload["preview"] as? Bool != true, let base = result.cgImage {
            result = try beautified(base, padding: padding, radius: try number(effects["radius"], fallback: 12, min: 0, max: 200), shadow: try number(effects["shadow"], fallback: 20, min: 0, max: 100),mode:effects["beautifyMode"] as? String ?? "rounded",effects:effects)
        }
        if payload["preview"] as? Bool == true, let image = result.cgImage {
            let ratio = min(1, 4096 / CGFloat(max(image.width, image.height)), sqrt(4_000_000 / CGFloat(image.width * image.height)))
            if ratio < 1 {
                let w = max(1, Int(CGFloat(image.width) * ratio)), h = max(1, Int(CGFloat(image.height) * ratio))
                guard let buffer = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BridgeFailure(code:"IMAGE_MEMORY",message:"无法创建预览图片") }
                buffer.interpolationQuality = .high; buffer.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
                if let reduced = buffer.makeImage() { result = NSBitmapImageRep(cgImage:reduced) }
            }
        }
        try Task.checkCancellation()
        guard let png = result.representation(using: .png, properties: [:]) else {
            throw BridgeFailure(code: "ENCODING_FAILED", message: "无法生成 PNG 图片")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if payload["preview"] as? Bool == true {
            let previews = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]).filter { $0.lastPathComponent.hasPrefix("Preview-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let preserved = Set(payload["preservePreviewPaths"] as? [String] ?? []);let deletable = previews.filter { !preserved.contains($0.path) };for old in deletable.prefix(max(0, previews.count - 10)) { try? FileManager.default.removeItem(at: old) }
        }
        let target = directory.appendingPathComponent((payload["preview"] as? Bool == true ? "Preview-" : "Clipy-") + UUID().uuidString + ".png")
        try Task.checkCancellation()
        try png.write(to: target, options: .atomic)
        do{try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path);try Task.checkCancellation()}catch{try? FileManager.default.removeItem(at:target);throw error}
        return ["path": target.path, "width": result.pixelsWide, "height": result.pixelsHigh, "annotations": rows.count]
    }

    static func smartHighlight(_ payload: [String:Any]) throws -> [String:Any] {
        try Task.checkCancellation()
        guard let path=payload["imagePath"] as? String,let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,width<=120000,height<=120000,Int64(width)*Int64(height)<=80_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil),let area=payload["rect"] as? [String:Any] else {throw BridgeFailure(code:"INVALID_IMAGE",message:"无法读取荧光笔选区")}
        let rect=CGRect(x:try number(area["x"],fallback:0),y:try number(area["y"],fallback:0),width:try number(area["width"],fallback:0,min:0),height:try number(area["height"],fallback:0,min:0)).insetBy(dx:-4,dy:-20)
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US","zh-Hans"]
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);try Task.checkCancellation()
        let annotations:[[String:Any]]=(request.results ?? []).prefix(500).compactMap { observation in
            let box=observation.boundingBox,line=CGRect(x:box.minX*CGFloat(width),y:(1-box.maxY)*CGFloat(height),width:box.width*CGFloat(width),height:box.height*CGFloat(height))
            guard line.intersects(rect) else{return nil};let left=max(line.minX,rect.minX),right=min(line.maxX,rect.maxX);guard right>left else{return nil}
            return ["id":UUID().uuidString,"tool":"highlighter","filled":true,"color":payload["color"] as? String ?? "#FFCC00","opacity":payload["opacity"] as? Double ?? 1,"width":3,"points":[["x":left,"y":line.minY],["x":right,"y":line.maxY]]]
        }
        return ["annotations":annotations,"count":annotations.count]
    }

    static func redact(_ payload: [String: Any]) throws -> [String: Any] {
        try Task.checkCancellation()
        guard let path = payload["imagePath"] as? String, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width <= 120000, height <= 120000, Int64(width) * Int64(height) <= 80_000_000, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BridgeFailure(code: "INVALID_IMAGE", message: "无法读取图片") }
        let categories=Set(payload["categories"] as? [String] ?? ["privacy","faces"])
        guard !categories.isEmpty,categories.isSubset(of:["text","privacy","faces","persons"])else{throw BridgeFailure(code:"INVALID_REDACTION",message:"请选择文字、隐私、人脸或人物")}
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US","zh-Hans"]
        let faces=VNDetectFaceRectanglesRequest(),persons=VNDetectHumanRectanglesRequest();persons.upperBodyOnly=false
        var jobs:[VNRequest]=[];if categories.contains("text")||categories.contains("privacy"){jobs.append(request)};if categories.contains("faces"){jobs.append(faces)};if categories.contains("persons"){jobs.append(persons)}
        try Task.checkCancellation();try VNImageRequestHandler(cgImage:image,options:[:]).perform(jobs);try Task.checkCancellation()
        let detector=try NSRegularExpression(pattern:"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}|(?<![0-9])(?:\\+?[0-9][ -]?){7,15}(?![0-9])",options:[.caseInsensitive]);var rectangles:[CGRect]=[]
        for observation in request.results ?? []{try Task.checkCancellation();guard let candidate=observation.topCandidates(1).first else{continue};if categories.contains("text"){rectangles.append(observation.boundingBox);continue};let text=candidate.string;for match in detector.matches(in:text,range:NSRange(text.startIndex...,in:text)){guard let range=Range(match.range,in:text),let box=try? candidate.boundingBox(for:range)else{continue};rectangles.append(box.boundingBox)}}
        if categories.contains("faces"){rectangles += (faces.results ?? []).map(\.boundingBox)};if categories.contains("persons"){rectangles += (persons.results ?? []).map(\.boundingBox)}
        let annotations: [[String: Any]] = rectangles.prefix(500).map { r in
            let x = r.minX * CGFloat(width), y = (1 - r.maxY) * CGFloat(height), w = r.width * CGFloat(width), h = r.height * CGFloat(height)
            return ["id": UUID().uuidString, "tool": "mosaic", "points": [["x": max(0, x - 3), "y": max(0, y - 3)], ["x": min(CGFloat(width), x + w + 3), "y": min(CGFloat(height), y + h + 3)]], "color": "#000000", "width": 5, "opacity": 1]
        }
        return ["annotations": annotations, "count": annotations.count]
    }

    static func sample(_ payload: [String: Any]) throws -> [String: Any] {
        guard let path = payload["imagePath"] as? String, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 120000, height <= 120000, Int64(width) * Int64(height) <= 80_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BridgeFailure(code: "INVALID_IMAGE", message: "无法读取图片") }
        let x = Int(try number(payload["x"], fallback: 0)), y = Int(try number(payload["y"], fallback: 0))
        guard x >= 0, x < image.width, y >= 0, y < image.height, let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { throw BridgeFailure(code: "INVALID_POINT", message: "取色位置超出图片") }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BridgeFailure(code: "RENDER_FAILED", message: "无法读取颜色") }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return ["color": String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])]
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, context c: CGContext) {
        c.saveGState(); c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
        c.draw(image, in: CGRect(origin: .zero, size: rect.size)); c.restoreGState()
    }

    private static func beautified(_ image: CGImage, padding: Int, radius: CGFloat, shadow: CGFloat,mode:String,effects:[String:Any]) throws -> NSBitmapImageRep {
        guard ["window","rounded","plain"].contains(mode)else{throw BridgeFailure(code:"INVALID_BEAUTIFY",message:"美化模式无效")};let header=mode=="window" ? 32:0
        let w = image.width + padding * 2, h = image.height + padding * 2+header
        guard Int64(w) * Int64(h) <= 80_000_000, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let g = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BridgeFailure(code: "IMAGE_LIMIT", message: "美化后的图片超出像素上限") }
        let c = g.cgContext
        c.clear(CGRect(x:0,y:0,width:w,height:h))
        let gradientMode=effects["gradientMode"] as? String ?? "gradient"
        if gradientMode=="solid"{c.setFillColor(try strictColor(effects["gradientSolid"]).cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))}
        else if gradientMode=="gradient"{let raw=effects["gradientColors"] as? [String] ?? ["#738CF2","#B366D9"];guard raw.count>=2,raw.count<=8,(effects["gradientColors"]==nil||effects["gradientColors"] is [String])else{throw BridgeFailure(code:"INVALID_GRADIENT",message:"渐变需要2–8个颜色")};let colors=try raw.map{try strictColor($0).cgColor};guard let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors as CFArray,locations:nil)else{throw BridgeFailure(code:"INVALID_GRADIENT",message:"无法生成渐变")};let angle=(effects["gradientAngle"] as? NSNumber)?.doubleValue ?? 45;guard angle.isFinite else{throw BridgeFailure(code:"INVALID_GRADIENT",message:"渐变角度无效")};let radians=angle.truncatingRemainder(dividingBy:360)*Double.pi/180,dx=cos(radians),dy=sin(radians),length=abs(Double(w)*dx)+abs(Double(h)*dy);let center=CGPoint(x:Double(w)/2,y:Double(h)/2);c.drawLinearGradient(gradient,start:CGPoint(x:center.x-dx*length/2,y:center.y-dy*length/2),end:CGPoint(x:center.x+dx*length/2,y:center.y+dy*length/2),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])}
        else{throw BridgeFailure(code:"INVALID_GRADIENT",message:"背景模式无效")}
        let rect = CGRect(x: padding, y: padding, width: image.width, height: image.height),card=CGRect(x:padding,y:padding,width:image.width,height:image.height+header);let rounding=mode=="plain" ? CGFloat(0):radius
        c.saveGState(); if shadow > 0 { c.setShadow(offset: CGSize(width: 0, height: -shadow * 0.3), blur: shadow, color: NSColor.black.withAlphaComponent(0.3).cgColor) }; c.setFillColor(NSColor.white.cgColor); c.addPath(CGPath(roundedRect: card, cornerWidth: rounding, cornerHeight: rounding, transform: nil)); c.fillPath(); c.restoreGState()
        c.addPath(CGPath(roundedRect: card, cornerWidth: rounding, cornerHeight: rounding, transform: nil)); c.clip(); c.draw(image, in: rect);if header>0{c.setFillColor(NSColor(deviceWhite:0.96,alpha:1).cgColor);c.fill(CGRect(x:padding,y:padding+image.height,width:image.width,height:header));for(index,tint)in ["#FF5F57","#FFBD2E","#28C840"].map({color($0)}).enumerated(){c.setFillColor(tint.cgColor);c.fillEllipse(in:CGRect(x:CGFloat(padding)+14+CGFloat(index)*18,y:CGFloat(padding+image.height)+11,width:10,height:10))}}
        return bitmap
    }

    private static func number(_ value: Any?, fallback: Double, min lower: Double = -1_000_000, max upper: Double = 1_000_000) throws -> CGFloat {
        let n = (value as? NSNumber)?.doubleValue ?? fallback
        guard n.isFinite, n >= lower, n <= upper else {
            throw BridgeFailure(code: "INVALID_SCENE", message: "标注包含无效数值")
        }
        return CGFloat(n)
    }

    static func wrapText(_ text:String,font:NSFont,width:CGFloat)throws->[String]{var lines:[String]=[];for paragraph in text.components(separatedBy:"\n"){try Task.checkCancellation();var line="",index=0;for character in paragraph{index+=1;if index%64==0{try Task.checkCancellation()};let next=line+String(character);if !line.isEmpty,(next as NSString).size(withAttributes:[.font:font]).width>width{lines.append(line);line=String(character)}else{line=next}};lines.append(line)};return lines}
    static func fitText(_ text:String,font:NSFont,width:CGFloat,height:CGFloat)throws->(font:NSFont,lines:[String]){var size=font.pointSize;while true{try Task.checkCancellation();let resized=NSFont(descriptor:font.fontDescriptor,size:size) ?? NSFont.systemFont(ofSize:size),lines=try wrapText(text,font:resized,width:width);if (CGFloat(lines.count)*size*1.2<=height && lines.allSatisfy{($0 as NSString).size(withAttributes:[.font:resized]).width<=width})||size<=4{return (resized,lines)};size=max(4,size-0.5)}}
    /// Two already-rendered PNGs, native pixels, no scaling or re-reading editor scene state.
    static func compose(_ payload:[String:Any],directory:URL)throws->[String:Any]{guard let paths=payload["paths"] as? [String],paths.count==2 else{throw BridgeFailure(code:"INVALID_COMPOSE",message:"请选择两张已渲染PNG")};let axis=payload["axis"] as? String ?? "vertical";guard ["vertical","horizontal"].contains(axis)else{throw BridgeFailure(code:"INVALID_COMPOSE",message:"拼接方向无效")};let gap=try number(payload["gap"],fallback:0,min:0,max:200);guard gap.rounded()==gap else{throw BridgeFailure(code:"INVALID_COMPOSE",message:"拼接间距必须为整数像素")};let images=try paths.map{path->CGImage in guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let type=CGImageSourceGetType(source),(type as String)=="public.png",let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,Int64(w)*Int64(h)<=80_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil)else{throw BridgeFailure(code:"INVALID_COMPOSE",message:"输入必须是有效PNG")};return image};let w=axis=="vertical" ? max(images[0].width,images[1].width):images[0].width+images[1].width+Int(gap),h=axis=="vertical" ? images[0].height+images[1].height+Int(gap):max(images[0].height,images[1].height);guard w<=120000,h<=120000,Int64(w)*Int64(h)<=80_000_000,let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let graphics=NSGraphicsContext(bitmapImageRep:bitmap)else{throw BridgeFailure(code:"IMAGE_LIMIT",message:"拼接图片超过8000万像素")};let c=graphics.cgContext;c.clear(CGRect(x:0,y:0,width:w,height:h));if payload["background"] != nil{c.setFillColor(try strictColor(payload["background"]).cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))};c.interpolationQuality = .none;c.setShouldAntialias(false);for(index,image)in images.enumerated(){try Task.checkCancellation();let x=axis=="vertical" ? (w-image.width)/2:(index==0 ? 0:images[0].width+Int(gap)),y=axis=="vertical" ? (index==0 ? h-image.height:0):(h-image.height)/2;c.draw(image,in:CGRect(x:x,y:y,width:image.width,height:image.height))};guard let bytes=bitmap.representation(using:.png,properties:[:])else{throw BridgeFailure(code:"ENCODING",message:"无法编码拼接图片")};try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let output=directory.appendingPathComponent("Clipy-"+UUID().uuidString+".png");try bytes.write(to:output,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path);return ["path":output.path,"width":w,"height":h]}
    static func counter(_ value:Int,format:String)->String{if format=="roman"{var number=value,result="";for(amount,symbol)in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]{while number>=amount{result+=symbol;number-=amount}};return result};if format=="upper"||format=="lower"{var n=value,result="";while n>0{n-=1;result=String(UnicodeScalar(65+n%26)!)+result;n/=26};return format=="lower" ? result.lowercased():result};return String(value)}
    private static func strictColor(_ value:Any?)throws->NSColor{guard let text=value as? String,text.hasPrefix("#"),(text.count==7||text.count==9),let raw=UInt64(text.dropFirst(),radix:16)else{throw BridgeFailure(code:"INVALID_COLOR",message:"颜色必须为#RRGGBB或#RRGGBBAA")};let rgba=text.count==9 ? raw:(raw<<8)|255;return NSColor(deviceRed:CGFloat((rgba>>24)&255)/255,green:CGFloat((rgba>>16)&255)/255,blue:CGFloat((rgba>>8)&255)/255,alpha:CGFloat(rgba&255)/255)}
    private static func color(_ value:Any?)->NSColor{(try? strictColor(value)) ?? NSColor(deviceRed:1,green:59.0/255,blue:48.0/255,alpha:1)}

    private static func draw(_ row: [String: Any], source: CGImage, context c: CGContext) throws {
        guard let tool = row["tool"] as? String,
              let raw = row["points"] as? [[String: Any]], !raw.isEmpty, raw.count <= 4096 else {
            throw BridgeFailure(code: "INVALID_SCENE", message: "标注点无效")
        }
        var points = try raw.map { CGPoint(x: try number($0["x"], fallback: 0), y: try number($0["y"], fallback: 0)) }
        if tool=="arrow",row["arrowFlip"] as? Bool==true{points.reverse()}
        let first = points[0], last = points[points.count - 1]
        let xs = points.map(\.x), ys = points.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let width = try number(row["width"], fallback: 3, min: 0.1, max: 200)
        let opacity = try number(row["opacity"], fallback: 1, min: 0, max: 1)
        let ink = color(row["color"])
        c.saveGState()
        defer { c.restoreGState() }
        c.setStrokeColor(ink.cgColor); c.setFillColor(ink.cgColor)
        c.setAlpha(opacity); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
        let lineStyle=row["lineStyle"] as? String ?? "solid"
        guard ["solid","dash","dot"].contains(lineStyle)else{throw BridgeFailure(code:"INVALID_STYLE",message:"线型无效")}
        if lineStyle=="dash"{c.setLineDash(phase:0,lengths:[width*3,width*2])}else if lineStyle=="dot"{c.setLineDash(phase:0,lengths:[max(0.1,width*0.2),width*2])}
        func stroke(_ path:CGPath,_ strokeWidth:CGFloat=width){if row["outline"] as? Bool==true{c.saveGState();c.setStrokeColor(NSColor.white.cgColor);c.setLineWidth(strokeWidth+2);c.addPath(path);c.strokePath();c.restoreGState()};c.setStrokeColor(ink.cgColor);c.setLineWidth(strokeWidth);c.addPath(path);c.strokePath()}
        func shape(_ path:CGPath)throws{let mode=row["fillMode"] as? String ?? ((row["filled"] as? Bool==true) ? "fill":"stroke");guard ["stroke","mixed","fill"].contains(mode)else{throw BridgeFailure(code:"INVALID_STYLE",message:"填充模式无效")};if mode != "stroke"{c.saveGState();c.setFillColor(ink.withAlphaComponent(ink.alphaComponent*(mode=="mixed" ? 0.25:1)).cgColor);c.addPath(path);c.fillPath();c.restoreGState()};if mode != "fill"{stroke(path)}else if row["outline"] as? Bool==true{c.setStrokeColor(NSColor.white.cgColor);c.setLineWidth(max(1,width*0.5));c.addPath(path);c.strokePath()}}

        switch tool {
        case "solid": c.fill(rect)
        case "erase":
            c.saveGState(); c.clip(to: rect); drawImage(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height), context: c); c.restoreGState()
        case "blur":
            let image = CIImage(cgImage: source)
            let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, width * 3)]).cropped(to: image.extent)
            if let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: image.extent) {
                c.saveGState(); c.clip(to: rect); drawImage(output, in: CGRect(x: 0, y: 0, width: source.width, height: source.height), context: c); c.restoreGState()
            }
        case "spotlight":
            c.setFillColor(NSColor.black.cgColor);c.setAlpha(try number(row["spotlightOpacity"],fallback:0.55,min:0,max:1)*opacity);let shade=CGMutablePath();shade.addRect(CGRect(x:0,y:0,width:source.width,height:source.height));shade.addRect(rect);c.addPath(shade);c.fillPath(using:.evenOdd);if row["outline"] as? Bool==true{c.setAlpha(opacity);c.setStrokeColor(NSColor.white.cgColor);c.stroke(rect)}
        case "magnifier":
            let zoom=try number(row["magnifierZoom"],fallback:2,min:1,max:8),w=min(CGFloat(source.width),rect.width/zoom),h=min(CGFloat(source.height),rect.height/zoom);let crop=CGRect(x:max(0,min(rect.midX-w/2,CGFloat(source.width)-w)),y:max(0,min(rect.midY-h/2,CGFloat(source.height)-h)),width:w,height:h)
            c.saveGState();c.addEllipse(in:rect);c.clip();if let detail=source.cropping(to:crop){drawImage(detail,in:rect,context:c)};c.restoreGState();if row["outline"] as? Bool==true{c.setStrokeColor(NSColor.white.cgColor);c.strokeEllipse(in:rect)}
        case "rectangle":let radius=try number(row["cornerRadius"],fallback:0,min:0,max:200);try shape(CGPath(roundedRect:rect,cornerWidth:min(radius,rect.width/2),cornerHeight:min(radius,rect.height/2),transform:nil))
        case "ellipse":try shape(CGPath(ellipseIn:rect,transform:nil))
        case "stamp" where row["imagePath"] != nil:
            guard points.count>=2,rect.width>0,rect.height>0,let path=row["imagePath"] as? String,path.hasPrefix("/"),path.utf8.count<=4096,let provider=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(provider,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? Int,let h=properties[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,Int64(w)*Int64(h)<=80_000_000 else{throw BridgeFailure(code:"INVALID_STAMP",message:"图片图章路径或目标范围无效")}
            let maximum=min(max(w,h),max(1,Int(max(rect.width,rect.height).rounded(.up))));guard let stamp=CGImageSourceCreateThumbnailAtIndex(provider,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maximum,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)else{throw BridgeFailure(code:"INVALID_STAMP",message:"无法读取图片图章")};let angle=(row["imageRotation"] as? NSNumber)?.doubleValue ?? 0;guard angle.isFinite else{throw BridgeFailure(code:"INVALID_STAMP",message:"图章旋转角度无效")};c.translateBy(x:rect.midX,y:rect.midY);c.rotate(by:CGFloat(angle.truncatingRemainder(dividingBy:360)*Double.pi/180));c.interpolationQuality = .high;drawImage(stamp,in:CGRect(x:-rect.width/2,y:-rect.height/2,width:rect.width,height:rect.height),context:c)
        case "text", "stamp":
            let text = row["text"] as? String ?? "文字"
            guard text.utf8.count <= 16_384 else { throw BridgeFailure(code: "TEXT_LIMIT", message: "标注文字过长") }
            let size = try number(row["fontSize"], fallback: 24, min: 8, max: 200)
            let family=row["fontFamily"] as? String
            let named = family.flatMap { $0.utf8.count<=128 ? NSFont(name:$0,size:size):nil }
            var font = named ?? NSFont.systemFont(ofSize: size, weight: row["bold"] as? Bool == true ? .bold : .regular)
            if named != nil, row["bold"] as? Bool == true {font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask)}
            if row["italic"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            if row["outline"] as? Bool==true{attributes[.strokeColor]=NSColor.white;attributes[.strokeWidth] = -200/size}
            if row["underline"] as? Bool == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if row["strike"] as? Bool == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let background = row["background"] as? String, !background.isEmpty { attributes[.backgroundColor] = color(background) }
            if let box=row["textBox"] as? [String:Any]{let w=try number(box["width"],fallback:0,min:1,max:120000),h=try number(box["height"],fallback:0,min:1,max:120000),area=CGRect(x:first.x,y:first.y,width:w,height:h);c.saveGState();defer{c.restoreGState()};c.setFillColor(color((row["background"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "#FFFFFF").cgColor);c.fill(area);c.clip(to:area);let inner=area.insetBy(dx:2,dy:2);guard inner.width>0,inner.height>0 else{return};let layout=try fitText(text,font:font,width:inner.width,height:inner.height);attributes[.font]=layout.font;if row["outline"] as? Bool==true{attributes[.strokeWidth] = -200/layout.font.pointSize};attributes.removeValue(forKey:.backgroundColor);let align=row["align"] as? String ?? "left";for(index,line)in layout.lines.enumerated(){let measured=(line as NSString).size(withAttributes:attributes).width,x=inner.minX+(align=="center" ? max(0,(inner.width-measured)/2):align=="right" ? max(0,inner.width-measured):0);(line as NSString).draw(at:CGPoint(x:x,y:inner.minY+CGFloat(index)*layout.font.pointSize*1.2),withAttributes:attributes)};break}
            let dimensions = (text as NSString).size(withAttributes: attributes)
            let align = row["align"] as? String ?? "left"
            (text as NSString).draw(at: CGPoint(x: first.x - (align == "center" ? dimensions.width / 2 : align == "right" ? dimensions.width : 0), y: first.y), withAttributes: attributes)
        case "number":
            let radius = max(14, width * 4)
            c.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            let value=(row["number"] as? Int) ?? (row["numberStart"] as? Int) ?? 1;guard value>=1,value<=9999 else{throw BridgeFailure(code:"INVALID_COUNTER",message:"编号范围为1–9999")};let format=row["numberFormat"] as? String ?? "decimal";guard ["decimal","roman","upper","lower"].contains(format)else{throw BridgeFailure(code:"INVALID_COUNTER",message:"编号格式无效")};let text = counter(value,format:format) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: radius * 1.2, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2), withAttributes: attrs)
        case "mosaic":
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            if clipped.isNull || clipped.isEmpty { return }
            let tile = max(8, width * 4)
            c.interpolationQuality = .none
            var y = clipped.minY
            while y < clipped.maxY {
                try Task.checkCancellation()
                var x = clipped.minX
                while x < clipped.maxX {
                    let w = min(tile, clipped.maxX - x), h = min(tile, clipped.maxY - y)
                    if let pixel = source.cropping(to: CGRect(x: floor(x + w / 2), y: floor(y + h / 2), width: 1, height: 1)) {
                        c.draw(pixel, in: CGRect(x: x, y: y, width: w, height: h))
                    }
                    x += tile
                }
                y += tile
            }
        case "highlighter" where row["filled"] as? Bool == true:
            c.setBlendMode(.multiply);c.setAlpha(opacity * 0.35);c.fill(rect)
        case "pen", "line", "arrow", "highlighter", "measure":
            if tool == "highlighter" { c.setBlendMode(.multiply);c.setAlpha(opacity * 0.35); c.setLineWidth(max(12, width * 5)) }
            let style = row["arrowStyle"] as? String ?? "line"
            if tool == "arrow", style == "dash" { c.setLineDash(phase: 0, lengths: [width * 3, width * 2]) }
            if ["pen","highlighter"].contains(tool),raw.contains(where:{$0["pressure"] != nil}) {
                let pressures=try raw.map {try number($0["pressure"],fallback:1,min:0,max:1)};let base=tool == "highlighter" ? max(12,width*5):width
                for index in 1..<points.count {try Task.checkCancellation();c.setLineWidth(max(0.1,base*(pressures[index-1]+pressures[index])/2));let segment=CGMutablePath();segment.move(to:points[index-1]);segment.addLine(to:points[index]);stroke(segment,max(0.1,base*(pressures[index-1]+pressures[index])/2))}
            }else{
            c.beginPath(); c.move(to: first)
            if tool == "arrow", style == "curve" { c.addQuadCurve(to: last, control: CGPoint(x: (first.x + last.x) / 2 - (last.y - first.y) * 0.2, y: (first.y + last.y) / 2 + (last.x - first.x) * 0.2)) }
            else { for point in points.dropFirst() { c.addLine(to: point) } }
            if let path=c.path{c.beginPath();stroke(path,tool=="highlighter" ? max(12,width*5):width)};c.setLineDash(phase:0,lengths:[])
            }
            if tool == "measure" {
                let unit=row["measureUnit"] as? String ?? "px";guard ["px","pt"].contains(unit)else{throw BridgeFailure(code:"INVALID_UNIT",message:"测距单位无效")};let scale=try number(row["imageScale"],fallback:1,min:0.25,max:8),distance=hypot(last.x-first.x,last.y-first.y)/(unit=="pt" ? scale:1);let text = "\(Int(distance.rounded())) \(unit)" as NSString
                text.draw(at: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2 - 20), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: ink])
            }
            if tool == "arrow" {
                let angle = atan2(last.y - first.y, last.x - first.x), length = max(style == "long" ? 20 : 12, width * (style == "long" ? 6 : 4))
                c.beginPath()
                c.move(to: CGPoint(x: last.x - length * cos(angle - 0.45), y: last.y - length * sin(angle - 0.45)))
                c.addLine(to: last)
                c.addLine(to: CGPoint(x: last.x - length * cos(angle + 0.45), y: last.y - length * sin(angle + 0.45)))
                if let path=c.path{c.beginPath();stroke(path)}
                if style == "double" {
                    let reverse = atan2(first.y - last.y, first.x - last.x)
                    c.beginPath(); c.move(to: CGPoint(x: first.x - length * cos(reverse - 0.45), y: first.y - length * sin(reverse - 0.45))); c.addLine(to: first); c.addLine(to: CGPoint(x: first.x - length * cos(reverse + 0.45), y: first.y - length * sin(reverse + 0.45))); if let path=c.path{c.beginPath();stroke(path)}
                }
                if style == "bar" {
                    let perpendicular = angle + .pi / 2, size = max(8, width * 3)
                    c.beginPath(); c.move(to: CGPoint(x: last.x - cos(perpendicular) * size, y: last.y - sin(perpendicular) * size)); c.addLine(to: CGPoint(x: last.x + cos(perpendicular) * size, y: last.y + sin(perpendicular) * size)); if let path=c.path{c.beginPath();stroke(path)}
                }
            }
        default: throw BridgeFailure(code: "UNSUPPORTED_TOOL", message: "不支持的标注工具：\(tool)")
        }
    }
}

/// File-only cache: Vision and CVPixelBuffer owners live in an expendable child process.
private final class ForegroundMaskCache:@unchecked Sendable {
    private let lock=NSLock()
    private var entries:[String:(URL,Int,Date)]=[:]
    private var directory:URL?
    private var active:UUID?
    private var process:Process?
    func mask(for source:URL)throws->URL{
        let props=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);let key=source.resolvingSymlinksInPath().path+"|\(props.fileSize ?? 0)|\(props.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        lock.lock()
        if let item=entries[key],FileManager.default.fileExists(atPath:item.0.path){entries[key]=(item.0,item.1,Date());lock.unlock();return item.0}
        guard active==nil else{lock.unlock();throw BridgeFailure(code:"BUSY",message:"正在处理另一张图片的背景，请稍后重试")}
        let token=UUID();active=token
        let folder=directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("clipy-foreground-mask-"+UUID().uuidString,isDirectory:true);directory=folder;lock.unlock()
        defer{lock.lock();if active==token{active=nil;process=nil};lock.unlock()}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let target=folder.appendingPathComponent("mask-"+UUID().uuidString+".png");var success=false;defer{if !success{try? FileManager.default.removeItem(at:target)}}
        var size:UInt32=0;_NSGetExecutablePath(nil,&size);var buffer=[CChar](repeating:0,count:Int(size));guard _NSGetExecutablePath(&buffer,&size)==0 else{throw BridgeFailure(code:"WORKER",message:"无法定位图像处理程序")};let worker=Process();worker.executableURL=URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath();worker.arguments=["--image-foreground-worker",source.path,target.path];worker.standardInput=FileHandle.nullDevice;worker.standardOutput=FileHandle.nullDevice;worker.standardError=FileHandle.nullDevice
        lock.lock();guard active==token else{lock.unlock();throw CancellationError()};process=worker;lock.unlock();try worker.run();let began=ProcessInfo.processInfo.systemUptime
        while worker.isRunning{lock.lock();let valid=active==token;lock.unlock();if Task.isCancelled || !valid||ProcessInfo.processInfo.systemUptime-began>30{worker.terminate();let deadline=ProcessInfo.processInfo.systemUptime+0.5;while worker.isRunning&&ProcessInfo.processInfo.systemUptime<deadline{Thread.sleep(forTimeInterval:0.01)};if worker.isRunning{kill(worker.processIdentifier,SIGKILL)};worker.waitUntilExit();if Task.isCancelled || !valid{throw CancellationError()};throw BridgeFailure(code:"WORKER_TIMEOUT",message:"背景分离超时，请缩小图片后重试")};Thread.sleep(forTimeInterval:0.02)}
        worker.waitUntilExit();try Task.checkCancellation();guard worker.terminationStatus==0,let bytes=try? target.resourceValues(forKeys:[.fileSizeKey]).fileSize,bytes>0,bytes<=16*1024*1024 else{throw BridgeFailure(code:"NO_FOREGROUND",message:"未检测到可分离前景或蒙版超出限制，原图保持不变")}
        lock.lock();guard active==token else{lock.unlock();throw CancellationError()};entries[key]=(target,bytes,Date());var used=entries.values.reduce(0){$0+$1.1};for(old,item)in entries.sorted(by:{$0.value.2<$1.value.2})where entries.count>4||used>32*1024*1024{if old==key{continue};entries.removeValue(forKey:old);used-=item.1;try? FileManager.default.removeItem(at:item.0)};lock.unlock();success=true;return target
    }
    func clear(){lock.lock();let old=process,folder=directory;process=nil;active=nil;directory=nil;entries.removeAll();lock.unlock();if let old,old.isRunning{old.terminate()};if let folder{try? FileManager.default.removeItem(at:folder)}}
}
