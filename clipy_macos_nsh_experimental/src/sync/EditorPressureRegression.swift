import Foundation
struct BridgeFailure:Error{let code:String;let message:String}
@main struct PressureRegression{
 static func main(){
  var gate=EditorPressureFilter();gate.configure(enabled:true,visible:false);guard gate.sample(pressure:1,tilt:.zero,screenPoint:.zero,timestamp:0)==nil else{fatalError("hidden editor emitted")};gate.configure(enabled:true,visible:true)
  let first=gate.sample(pressure:2,tilt:CGPoint(x:-3,y:4),screenPoint:CGPoint(x:-100,y:200),timestamp:1);guard first?["pressure"] as? Double==1,let tilt=first?["tilt"] as? [String:CGFloat],tilt["x"] == -1,tilt["y"]==1 else{fatalError("pressure/tilt clamp")}
  guard gate.sample(pressure:0.2,tilt:.zero,screenPoint:.zero,timestamp:1.01)==nil,gate.sample(pressure:0.3,tilt:.zero,screenPoint:.zero,timestamp:1.017) != nil else{fatalError("60Hz limit")};guard gate.sample(pressure:.nan,tilt:.zero,screenPoint:.zero,timestamp:2)==nil,gate.sample(pressure:0.4,tilt:.zero,screenPoint:CGPoint(x:CGFloat.infinity,y:0),timestamp:3)==nil else{fatalError("invalid float admitted")};gate.stop();guard !gate.active,gate.sample(pressure:0.4,tilt:.zero,screenPoint:.zero,timestamp:4)==nil else{fatalError("close emitted")}
  print("PASS: editor-only pressure gate, 0...1/tilt clamp, <=60Hz throttle, invalid floats rejected and close disables; no stylus hardware claim")
 }
}
