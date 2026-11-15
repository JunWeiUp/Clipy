import Foundation
struct BridgeFailure:Error{let code:String;let message:String}
@main struct AppleTranslationRegression{
 @MainActor static func main()async throws{
  guard try AppleTranslationService.normalizeLanguage("简体中文")=="zh-Hans",try AppleTranslationService.normalizeLanguage("zh_TW")=="zh-Hant",try AppleTranslationService.normalizeLanguage("EN_us")=="en",try AppleTranslationService.normalizeLanguage("日本語")=="ja",try AppleTranslationService.normalizeLanguage("Korean")=="ko"else{fatalError("language normalization")}
  guard try AppleTranslationService.normalizeLanguage("en-CA")=="en",try AppleTranslationService.normalizeLanguage("en-Latn-AU")=="en",try AppleTranslationService.normalizeLanguage("zh-Hant-HK")=="zh-Hant",try AppleTranslationService.normalizeLanguage("zh-Hans-SG")=="zh-Hans",try AppleTranslationService.normalizeLanguage("ko-Kore-KR")=="ko"else{fatalError("regional BCP normalization")}
  var malformedRegion=false;do{_=try AppleTranslationService.normalizeLanguage("en-not/a/language")}catch{malformedRegion=true};guard malformedRegion else{fatalError("malformed regional prefix accepted")}
  var invalid=false;do{_=try AppleTranslationService.normalizeLanguage("https://not-a-language")}catch{invalid=true};guard invalid else{fatalError("invalid language accepted")}
  let service=AppleTranslationService();let status=try await service.invoke("status",["source":"en","target":"简体中文"]) as! [String:Any];guard status["canRequestDownloads"] as? Bool==false,status["provider"] as? String=="apple-on-device"else{fatalError("status privacy contract")}
  if #available(macOS 26.0,*){
   guard status["available"] as? Bool==true else{fatalError("direct system API unavailable on mac26")}
   let same=try await service.invoke("translate",["text":"synthetic identity fixture","source":"en-US","target":"English"]) as! [String:Any];guard same["sameLanguage"] as? Bool==true,same["text"] as? String=="synthetic identity fixture"else{fatalError("same language should not request model or system translation")}
   if status["pairStatus"] as? String=="supported"{var missing=false;do{_=try await service.invoke("translate",["text":"synthetic missing-pack fixture","source":"en","target":"zh-CN"])}catch let error as BridgeFailure{missing=error.code=="LANGUAGE_NOT_INSTALLED"};guard missing else{fatalError("missing languages not fail-closed")}}
  }else{guard status["available"] as? Bool==false else{fatalError("old OS claimed unsupported API available")}}
  service.cancel();print("PASS: Apple language normalization, target13-compatible weak API guard, real installed-pair status with downloads disabled, same-language no-op and missing-pack preflight; no real user text/model HTTP/download")
 }
}
