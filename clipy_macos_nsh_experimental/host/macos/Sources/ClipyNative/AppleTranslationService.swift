import Foundation
import NaturalLanguage
import Translation

/// Explicit on-device translation only. This owner never reads API keys, performs HTTP,
/// presents SwiftUI, requests downloads or silently selects another provider.
@MainActor final class AppleTranslationService {
    private var owner:UUID?
    private var cancelSession:(()->Void)?
    func cancel(){let cancellation=cancelSession;cancelSession=nil;owner=nil;cancellation?()}
    func invoke(_ method:String,_ params:[String:Any])async throws->Any{
        switch method{
        case "status","systemTranslation.status":return try await status(params)
        case "translate","systemTranslation.translate":return try await translate(params)
        case "cancel","systemTranslation.cancel":cancel();return true
        default:throw BridgeFailure(code:"UNSUPPORTED",message:"未知系统翻译接口")
        }
    }
    static func normalizeLanguage(_ raw:String)throws->String{
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"_",with:"-").lowercased()
        let aliases:[String:String]=["中文":"zh-Hans","简体":"zh-Hans","简体中文":"zh-Hans","chinese":"zh-Hans","simplified chinese":"zh-Hans","chinese (simplified)":"zh-Hans","zh":"zh-Hans","zh-cn":"zh-Hans","zh-hans":"zh-Hans","zh-hans-cn":"zh-Hans","繁體":"zh-Hant","繁体":"zh-Hant","繁體中文":"zh-Hant","繁体中文":"zh-Hant","traditional chinese":"zh-Hant","chinese (traditional)":"zh-Hant","zh-tw":"zh-Hant","zh-hk":"zh-Hant","zh-mo":"zh-Hant","zh-hant":"zh-Hant","zh-hant-tw":"zh-Hant","英文":"en","英语":"en","english":"en","en-us":"en","en-gb":"en","en":"en","日本語":"ja","日语":"ja","日文":"ja","japanese":"ja","ja-jp":"ja","ja":"ja","한국어":"ko","韩语":"ko","韩文":"ko","korean":"ko","ko-kr":"ko","ko":"ko"]
        if let canonical=aliases[value]{return canonical}
        guard value.range(of:"^[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,3}$",options:.regularExpression) != nil else{throw BridgeFailure(code:"INVALID_LANGUAGE",message:"请选择有效的源语言和目标语言")}
        // Installed assets are shared by these common script/language region variants.
        // Validate the BCP shape above before collapsing, so malformed prefixes are not accepted.
        if value.hasPrefix("zh-hant-"){return "zh-Hant"}
        if value.hasPrefix("zh-hans-"){return "zh-Hans"}
        if value.hasPrefix("en-"){return "en"}
        if value.hasPrefix("ja-"){return "ja"}
        if value.hasPrefix("ko-"){return "ko"}
        return Locale.Language(identifier:value).minimalIdentifier
    }
    private func languages(_ params:[String:Any],requireText:Bool)throws->(text:String,source:String?,target:String){
        let text=params["text"] as? String ?? ""
        if requireText{guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw BridgeFailure(code:"NOTHING_TO_TRANSLATE",message:"没有可翻译的文字")};guard text.count<=10000,text.utf8.count<=64*1024 else{throw BridgeFailure(code:"TOO_LARGE",message:"系统翻译支持1–10000字，最多64KiB")}}
        let target=try Self.normalizeLanguage(params["target"] as? String ?? "zh-CN"),raw=params["source"] as? String ?? "auto"
        if raw.isEmpty||raw.lowercased()=="auto"{guard !text.isEmpty else{return(text,nil,target)};guard let detected=NLLanguageRecognizer.dominantLanguage(for:text),detected != .undetermined else{throw BridgeFailure(code:"SOURCE_LANGUAGE_UNIDENTIFIED",message:"无法识别原文语言，请明确选择源语言")};return(text,try Self.normalizeLanguage(detected.rawValue),target)}
        return(text,try Self.normalizeLanguage(raw),target)
    }
    private func status(_ params:[String:Any])async throws->[String:Any]{
        guard #available(macOS 26.0,*)else{return["available":false,"minimumMacOS":"26.0","provider":"apple-on-device","pairStatus":"unavailable","canRequestDownloads":false,"requiresDownload":false]}
        let input=try languages(params,requireText:false);guard let source=input.source else{return["available":true,"provider":"apple-on-device","pairStatus":"needs-source-text","target":input.target,"canRequestDownloads":false,"requiresDownload":false]}
        if source==input.target{return["available":true,"provider":"apple-on-device","pairStatus":"not-required","source":source,"target":input.target,"sameLanguage":true,"canRequestDownloads":false,"requiresDownload":false]}
        let availability=await LanguageAvailability().status(from:Locale.Language(identifier:source),to:Locale.Language(identifier:input.target));let name:String
        switch availability{case .installed:name="installed";case .supported:name="supported";case .unsupported:name="unsupported";@unknown default:name="unsupported"}
        return["available":true,"provider":"apple-on-device","pairStatus":name,"source":source,"target":input.target,"canRequestDownloads":false,"requiresDownload":availability == .supported]
    }
    private func translate(_ params:[String:Any])async throws->[String:Any]{
        guard #available(macOS 26.0,*)else{throw BridgeFailure(code:"SYSTEM_TRANSLATION_UNAVAILABLE",message:"无界面系统翻译需要macOS26或更新版本；可明确选择模型翻译，不会自动发送到外部接口")}
        let input=try languages(params,requireText:true);guard let source=input.source else{throw BridgeFailure(code:"SOURCE_LANGUAGE_UNIDENTIFIED",message:"无法识别原文语言")};cancel();let token=UUID();owner=token
        defer{if owner==token{cancelSession=nil;owner=nil}}
        if source==input.target{return["text":input.text,"source":source,"target":input.target,"provider":"apple-on-device","sameLanguage":true]}
        let availability=LanguageAvailability();let sourceLanguage=Locale.Language(identifier:source),targetLanguage=Locale.Language(identifier:input.target)
        let state=await availability.status(from:sourceLanguage,to:targetLanguage);guard !Task.isCancelled,owner==token else{throw cancellation()}
        if state == .supported{throw notInstalled()}
        if state == .unsupported{let supported=Set((await availability.supportedLanguages).compactMap{try? Self.normalizeLanguage($0.minimalIdentifier)});guard owner==token,!Task.isCancelled else{throw cancellation()};if !supported.contains(source){throw BridgeFailure(code:"UNSUPPORTED_SOURCE_LANGUAGE",message:"系统翻译不支持该源语言")};if !supported.contains(input.target){throw BridgeFailure(code:"UNSUPPORTED_TARGET_LANGUAGE",message:"系统翻译不支持该目标语言")};throw BridgeFailure(code:"UNSUPPORTED_LANGUAGE_PAIR",message:"系统翻译不支持该语言组合")}
        let session=TranslationSession(installedSource:sourceLanguage,target:targetLanguage);cancelSession={session.cancel()}
        do{return try await withTaskCancellationHandler(operation:{try Task.checkCancellation();let response=try await session.translate(input.text);try Task.checkCancellation();guard self.owner==token else{throw self.cancellation()};return["text":response.targetText,"source":source,"target":input.target,"provider":"apple-on-device"]},onCancel:{Task{@MainActor [weak self]in if self?.owner==token{self?.cancel()}}})}
        catch TranslationError.notInstalled{throw notInstalled()}
        catch TranslationError.unsupportedSourceLanguage{throw BridgeFailure(code:"UNSUPPORTED_SOURCE_LANGUAGE",message:"系统翻译不支持该源语言")}
        catch TranslationError.unsupportedTargetLanguage{throw BridgeFailure(code:"UNSUPPORTED_TARGET_LANGUAGE",message:"系统翻译不支持该目标语言")}
        catch TranslationError.unsupportedLanguagePairing{throw BridgeFailure(code:"UNSUPPORTED_LANGUAGE_PAIR",message:"系统翻译不支持该语言组合")}
        catch TranslationError.unableToIdentifyLanguage{throw BridgeFailure(code:"SOURCE_LANGUAGE_UNIDENTIFIED",message:"无法识别原文语言")}
        catch TranslationError.nothingToTranslate{throw BridgeFailure(code:"NOTHING_TO_TRANSLATE",message:"没有可翻译的文字")}
        catch TranslationError.alreadyCancelled{throw cancellation()}
        catch is CancellationError{throw cancellation()}
        catch let error as BridgeFailure{throw error}
        catch{throw BridgeFailure(code:"SYSTEM_TRANSLATION_FAILED",message:"系统设备端翻译失败，请检查语言包后重试；未发送到模型接口")}
    }
    private func notInstalled()->BridgeFailure{BridgeFailure(code:"LANGUAGE_NOT_INSTALLED",message:"请到系统设置→通用→语言与地区→翻译语言，下载源语言与目标语言后重试；当前不会自动下载或调用模型接口")}
    private func cancellation()->BridgeFailure{BridgeFailure(code:"SYSTEM_TRANSLATION_CANCELLED",message:"系统翻译已取消")}
}
