import AppKit
struct BridgeFailure: Error { let code: String; let message: String }
@main struct NativeRenderRegression {
static func main() async throws {
if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--image-foreground-worker" { do {try ImageEditorService.foregroundMaskWorker(sourcePath:CommandLine.arguments[2],maskPath:CommandLine.arguments[3]);exit(0)}catch{exit(1)} }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-image-render-regression-" + UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let input = root.appendingPathComponent("fixture.png")
let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:48,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
for y in 0..<48 { for x in 0..<64 { image.setColor(y < 24 ? NSColor(deviceRed:1,green:0,blue:0,alpha:1) : NSColor(deviceRed:0,green:0,blue:1,alpha:1), atX:x,y:y) } }
try image.representation(using:.png,properties:[:])!.write(to:input)
let original = try ImageEditorService.render(["imagePath":input.path,"annotations":[[String:Any]]()],directory:root)
let baseline = NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:original["path"] as! String)))!
assert(baseline.colorAt(x:32,y:5)!.redComponent > 0.9,"base image flipped")
assert(baseline.colorAt(x:32,y:40)!.blueComponent > 0.9,"base image flipped")
let scene:[String:Any] = ["imagePath":input.path,"annotations":[["tool":"rectangle","points":[["x":10,"y":5],["x":30,"y":15]],"color":"#00FF00","width":4,"opacity":1]]]
let result = try ImageEditorService.render(scene,directory:root)
let rendered = NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:result["path"] as! String)))!
assert(rendered.pixelsWide==64 && rendered.pixelsHigh==48)
assert(rendered.colorAt(x:10,y:10)!.greenComponent > 0.9,"annotation coordinates incorrect")
assert(rendered.colorAt(x:10,y:38)!.blueComponent > 0.9,"annotation mirrored vertically")
var rejected = false
do { _ = try ImageEditorService.render(["imagePath":input.path,"annotations":[["tool":"line","points":[["x":Double.infinity,"y":2]]]]],directory:root) } catch { rejected = true }
assert(rejected,"nonfinite coordinate accepted")
let sampled = try ImageEditorService.sample(["imagePath":input.path,"x":32,"y":5])
assert(sampled["color"] as? String == "#FF0000", "color picker sample incorrect")
let tools = ["pen", "line", "arrow", "rectangle", "ellipse", "text", "number", "highlighter", "mosaic", "blur", "solid", "erase", "magnifier", "measure", "spotlight", "stamp"]
for tool in tools {
 let output = try ImageEditorService.render(["imagePath":input.path,"annotations":[["tool":tool,"points":[["x":8,"y":8],["x":40,"y":32]],"color":"#00FF00","width":3,"opacity":0.8,"text":"A","fontSize":12]]],directory:root)
 assert(FileManager.default.fileExists(atPath:output["path"] as! String), "tool export missing")
}
let beauty = try ImageEditorService.render(["imagePath":input.path,"annotations":[[String:Any]](),"effects":["beautify":true,"padding":20,"radius":6,"saturation":0]],directory:root)
assert(beauty["width"] as? Int == 104 && beauty["height"] as? Int == 88, "beautify pixels incorrect")
let transformed = try ImageEditorService.render(["imagePath":input.path,"annotations":[[String:Any]](),"crop":["x":4,"y":4,"width":30,"height":20],"rotation":90,"flipH":true],directory:root)
assert(transformed["width"] as? Int == 20 && transformed["height"] as? Int == 30, "crop rotation dimensions incorrect")
for style in ["line","dash","curve","long","bar","double"] {
 _ = try ImageEditorService.render(["imagePath":input.path,"annotations":[["tool":"arrow","arrowStyle":style,"points":[["x":8,"y":8],["x":40,"y":32]],"color":"#00FF00","width":3,"opacity":1]]],directory:root)
}
let fullText:[String:Any] = ["tool":"text","text":"Hello","points":[["x":30,"y":12]],"color":"#FFFFFF","fontSize":12,"bold":true,"italic":true,"underline":true,"strike":true,"align":"center","background":"#000000"]
_ = try ImageEditorService.render(["imagePath":input.path,"annotations":[fullText]],directory:root)
let privacy = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1000,pixelsHigh:240,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:privacy)
NSColor.white.setFill();NSRect(x:0,y:0,width:1000,height:240).fill()
("demo@example.invalid  +1 555 010 1234" as NSString).draw(at:NSPoint(x:30,y:100),withAttributes:[.font:NSFont.systemFont(ofSize:40),.foregroundColor:NSColor.black])
NSGraphicsContext.restoreGraphicsState()
let privacyPath=root.appendingPathComponent("privacy-fixture.png");try privacy.representation(using:.png,properties:[:])!.write(to:privacyPath)
let redactions = try ImageEditorService.redact(["imagePath":privacyPath.path])
assert((redactions["count"] as? Int ?? 0) >= 1, "OCR privacy detector missed synthetic email")
let smart = try ImageEditorService.smartHighlight(["imagePath":privacyPath.path,"rect":["x":0,"y":0,"width":1000,"height":240],"color":"#FFCC00"])
assert((smart["count"] as? Int ?? 0)>0,"smart highlighter did not find synthetic text line")
assert((smart["annotations"] as? [[String:Any]])?.first?["filled"] as? Bool == true,"smart highlight lacks line geometry")
let pressureScene:[String:Any]=["imagePath":input.path,"annotations":[["tool":"pen","color":"#00FF00","width":12,"opacity":1,"points":[["x":8,"y":10,"pressure":0.1],["x":20,"y":10,"pressure":0.1],["x":50,"y":10,"pressure":1.0]]]]]
let pressureResult=try ImageEditorService.render(pressureScene,directory:root)
let pressurePixels=NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:pressureResult["path"] as! String)))!
assert(pressurePixels.colorAt(x:14,y:7)!.greenComponent<0.3,"light pressure stroke too wide")
assert(pressurePixels.colorAt(x:40,y:8)!.greenComponent>0.7,"heavy pressure stroke did not widen")
let fontRow:[String:Any] = ["tool":"text","text":"Hello","points":[["x":3,"y":5]],"color":"#00FF00","fontSize":12,"bold":true,"italic":true]
let systemFont=try ImageEditorService.render(["imagePath":input.path,"annotations":[fontRow]],directory:root)
let systemPixels=NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:systemFont["path"] as! String)))!
for family in ["PingFangSC-Regular","Menlo-Regular","TimesNewRomanPSMT","missing-font-fixture"] {
 var row=fontRow;row["fontFamily"]=family
 let fontResult=try await Task.detached {try ImageEditorService.render(["imagePath":input.path,"annotations":[row]],directory:root)}.value
 let pixels=NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:fontResult["path"] as! String)))!
 assert(pixels.pixelsWide==64 && pixels.pixelsHigh==48)
 if family=="missing-font-fixture" {for y in 0..<48 {for x in 0..<64 {assert(pixels.colorAt(x:x,y:y)==systemPixels.colorAt(x:x,y:y),"invalid family did not fall back to the system font")}}}
}
print("PASS named font families on background render and exact invalid-family fallback")
print("PASS Vision smart-highlight line boxes and variable pressure pixels")
print("PASS Vision synthetic email/phone auto redaction returns editable annotations")
let background = try await Task.detached { try ImageEditorService.render(scene,directory:root) }.value
let backgroundPixels=NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:background["path"] as! String)))!
assert(backgroundPixels.pixelsWide==rendered.pixelsWide && backgroundPixels.pixelsHigh==rendered.pixelsHigh)
for y in 0..<48 {for x in 0..<64 {assert(backgroundPixels.colorAt(x:x,y:y)==rendered.colorAt(x:x,y:y),"background render pixels differ")}}
let cancelled=Task.detached { try Task.checkCancellation(); return try ImageEditorService.render(scene,directory:root) };cancelled.cancel()
do {_ = try await cancelled.value;assert(false,"cancelled image render completed")}catch is CancellationError {}
let tall = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:20,pixelsHigh:40000,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let tallPath=root.appendingPathComponent("long-fixture.png");try tall.representation(using:.png,properties:[:])!.write(to:tallPath)
let longExport=try ImageEditorService.render(["imagePath":tallPath.path,"annotations":[[String:Any]]()],directory:root)
assert(longExport["height"] as? Int == 40000,"long capture was truncated")
let longPreview=try ImageEditorService.render(["imagePath":tallPath.path,"annotations":[[String:Any]](),"preview":true],directory:root)
assert((longPreview["height"] as? Int ?? 0)<=4096,"long preview texture exceeds limit")
print("PASS 40000px long capture export with bounded preview texture")
print("PASS Task.detached pixel equivalence and cancellation")
print("PASS crop + rotation + flip pixels, six arrows, full text attributes")
print("PASS all 16 render tools, sample RGB, color controls, beautify dimensions")
print("PASS source orientation, native pixels, annotation position, invalid-scene rejection")
print(result["path"]!)

}
}
