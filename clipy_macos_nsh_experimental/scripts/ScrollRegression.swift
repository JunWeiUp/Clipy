import Foundation
import CoreGraphics
struct BridgeFailure:Error { let code:String;let message:String }
enum BridgeOutput { static func write(_ value:[String:Any]) {} }
@main struct ScrollRegression {
    static func main() throws {
        let global=CGRect(x:-1900,y:-200,width:700,height:600),app=ScrollRegionSelector.appKitRect(fromCG:global,mainTop:982)
        assert(app==CGRect(x:-1900,y:582,width:700,height:600),"preselected negative-screen CG/AppKit conversion")
        let width = 480,height = 1600
        var seed:UInt32 = 1234567
        var bytes = [UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width { seed = seed &* 1664525 &+ 1013904223;let p = (y*width+x)*4;bytes[p] = UInt8((seed>>16)&255);bytes[p+1] = UInt8((seed>>8)&255);bytes[p+2] = UInt8(seed&255) } }
        let space = CGColorSpaceCreateDeviceRGB()
        let data = Data(bytes),provider = CGDataProvider(data:data as CFData)!
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let a = image.cropping(to:CGRect(x:0,y:0,width:width,height:400))!,b = image.cropping(to:CGRect(x:0,y:120,width:width,height:400))!,far = image.cropping(to:CGRect(x:0,y:700,width:width,height:400))!
        assert(ScrollStitcher.match(a,a) == .duplicate)
        let match = ScrollStitcher.match(a,b)
        guard case .append(let delta,let footer) = match else { fatalError("overlap not detected: \(match)") }
        assert(abs(delta-120)<=2 && footer == 0,"wrong delta \(delta), footer \(footer)")
        let result = try ScrollStitcher.append(canvas:a,frame:b,delta:delta,footer:footer,maxHeight:20000)
        assert(result.height == 520 && result.width == width)
        guard case .reject = ScrollStitcher.match(a,far) else { fatalError("gap accepted") }
        let shifted = image.cropping(to:CGRect(x:10,y:120,width:width-10,height:400))!
        guard case .reject = ScrollStitcher.match(a,shifted) else { fatalError("horizontal/size change accepted") }
        do { _ = try ScrollStitcher.append(canvas:a,frame:b,delta:120,footer:0,maxHeight:500);fatalError("limit ignored") } catch {}
        func footerImage(_ source:CGImage) -> CGImage {
            let c = CGContext(data:nil,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(source,in:CGRect(x:0,y:0,width:source.width,height:source.height));c.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));c.fill(CGRect(x:0,y:0,width:source.width,height:40));return c.makeImage()!
        }
        let stickyA = footerImage(a),stickyB = footerImage(b)
        guard case .append(let stickyDelta,let stickyFooter) = ScrollStitcher.match(stickyA,stickyB) else { fatalError("sticky footer rejected") }
        switch ScrollStitcher.match(stickyA,stickyB,freezeHeader:false) { case .append(_,let footer):assert(footer == 0);case .reject:break;case .duplicate:fatalError("changed frame treated as duplicate") }
        assert(stickyDelta == 120 && stickyFooter == 40,"sticky dimensions \(stickyDelta)/\(stickyFooter)")
        let stickyResult = try ScrollStitcher.append(canvas:stickyA,frame:stickyB,delta:stickyDelta,footer:stickyFooter,maxHeight:20000);assert(stickyResult.height == 520)
        let odd = image.cropping(to:CGRect(x:0,y:121,width:width,height:400))!
        guard case .append(let oddDelta,_) = ScrollStitcher.match(a,odd),oddDelta == 121 else { fatalError("odd pixel offset lost") }
        print("Scroll regression passed: overlap, duplicate, gap, horizontal/size reject, dimensions and limit")
    }
}
