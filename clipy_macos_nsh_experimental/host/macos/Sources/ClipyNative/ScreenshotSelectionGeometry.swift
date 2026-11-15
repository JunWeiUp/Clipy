import Foundation
import CoreGraphics

enum ScreenshotResizeHandle:Int,CaseIterable {
    case bottomLeft,bottom,bottomRight,right,topRight,top,topLeft,left
    var axes:(CGFloat,CGFloat) {
        switch self { case .bottomLeft:return(0,0);case .bottom:return(0.5,0);case .bottomRight:return(1,0);case .right:return(1,0.5);case .topRight:return(1,1);case .top:return(0.5,1);case .topLeft:return(0,1);case .left:return(0,0.5) }
    }
    func point(in rect:CGRect)->CGPoint { let a=axes;return CGPoint(x:rect.minX+rect.width*a.0,y:rect.minY+rect.height*a.1) }
}
/// Pure point-space geometry; no window, permission, or desktop pixels required.
enum ScreenshotSelectionGeometry {
    static func clamped(_ point:CGPoint,to bounds:CGRect)->CGPoint { CGPoint(x:min(max(point.x,bounds.minX),bounds.maxX),y:min(max(point.y,bounds.minY),bounds.maxY)) }
    static func drawn(from anchor:CGPoint,to point:CGPoint,ratio:CGFloat?,bounds:CGRect)->CGRect {
        let anchor=clamped(anchor,to:bounds),point=clamped(point,to:bounds)
        guard let ratio,ratio.isFinite,ratio>0 else { return CGRect(x:min(anchor.x,point.x),y:min(anchor.y,point.y),width:abs(point.x-anchor.x),height:abs(point.y-anchor.y)) }
        let sx:CGFloat=point.x<anchor.x ? -1:1,sy:CGFloat=point.y<anchor.y ? -1:1
        let availableX=sx<0 ? anchor.x-bounds.minX:bounds.maxX-anchor.x,availableY=sy<0 ? anchor.y-bounds.minY:bounds.maxY-anchor.y
        let width=min(max(abs(point.x-anchor.x),abs(point.y-anchor.y)*ratio),availableX,availableY*ratio),height=width/ratio
        return CGRect(x:sx<0 ? anchor.x-width:anchor.x,y:sy<0 ? anchor.y-height:anchor.y,width:width,height:height)
    }
    static func resized(_ rect:CGRect,handle:ScreenshotResizeHandle,to point:CGPoint,ratio:CGFloat?,bounds:CGRect)->CGRect {
        let point=clamped(point,to:bounds),a=handle.axes
        if a.0 != 0.5,a.1 != 0.5 {
            let anchor=CGPoint(x:a.0==0 ? rect.maxX:rect.minX,y:a.1==0 ? rect.maxY:rect.minY)
            return drawn(from:anchor,to:point,ratio:ratio,bounds:bounds)
        }
        var x0=rect.minX,x1=rect.maxX,y0=rect.minY,y1=rect.maxY
        if a.0==0{x0=point.x};if a.0==1{x1=point.x};if a.1==0{y0=point.y};if a.1==1{y1=point.y}
        var result=CGRect(x:min(x0,x1),y:min(y0,y1),width:abs(x1-x0),height:abs(y1-y0))
        if let ratio,ratio>0,ratio.isFinite {
            if a.0 != 0.5 {
                let maxHeight=2*min(rect.midY-bounds.minY,bounds.maxY-rect.midY)
                let width=min(result.width,maxHeight*ratio),height=width/ratio,anchorX=a.0==0 ? rect.maxX:rect.minX
                result=CGRect(x:point.x<anchorX ? anchorX-width:anchorX,y:rect.midY-height/2,width:width,height:height)
            } else {
                let maxWidth=2*min(rect.midX-bounds.minX,bounds.maxX-rect.midX)
                let height=min(result.height,maxWidth/ratio),width=height*ratio,anchorY=a.1==0 ? rect.maxY:rect.minY
                result=CGRect(x:rect.midX-width/2,y:point.y<anchorY ? anchorY-height:anchorY,width:width,height:height)
            }
        }
        return result.intersection(bounds)
    }
    static func sized(_ rect:CGRect,width:CGFloat,height:CGFloat,bounds:CGRect)->CGRect {
        let width=min(max(width,2),bounds.width),height=min(max(height,2),bounds.height)
        return CGRect(x:min(max(rect.minX,bounds.minX),bounds.maxX-width),y:min(max(rect.minY,bounds.minY),bounds.maxY-height),width:width,height:height)
    }
    static func aspectFitted(_ rect:CGRect,width:CGFloat,height:CGFloat,ratio:CGFloat?,bounds:CGRect)->CGRect {
        guard let ratio,ratio.isFinite,ratio>0 else{return sized(rect,width:width,height:height,bounds:bounds)}
        let requestedWidth=max(2,width,2*ratio),requestedHeight=requestedWidth/ratio
        let factor=min(1,bounds.width/requestedWidth,bounds.height/requestedHeight)
        return sized(rect,width:requestedWidth*factor,height:requestedHeight*factor,bounds:bounds)
    }
    static func handle(at point:CGPoint,rect:CGRect,radius:CGFloat=7)->ScreenshotResizeHandle? {
        ScreenshotResizeHandle.allCases.first { h in let p=h.point(in:rect);return abs(point.x-p.x)<=radius && abs(point.y-p.y)<=radius }
    }
}
