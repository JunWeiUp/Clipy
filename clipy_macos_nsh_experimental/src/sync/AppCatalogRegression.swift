import Foundation
import AppKit
import ImageIO
@main struct CatalogRegression{
 @MainActor static func main()throws{
  _=NSApplication.shared;let root=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-app-catalog-"+UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  for name in ["Example","Duplicate"]{let contents=root.appendingPathComponent(name+".app/Contents",isDirectory:true);try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true);let data=try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"dev.clipy.fixture.catalog","CFBundleDisplayName":"Fixture App"],format:.xml,options:0);try data.write(to:contents.appendingPathComponent("Info.plist"))}
  let selected=AppCatalogService.appInfo(paths:[root.appendingPathComponent("Example.app").path,root.appendingPathComponent("Duplicate.app").path,root.appendingPathComponent("not-an-app").path]);guard selected.count==1,selected[0]["bundleId"] as? String=="dev.clipy.fixture.catalog" else{fatalError("metadata dedup failed")}
  let all=AppCatalogService.list();guard all.count<=512,Set(all.compactMap{$0["bundleId"] as? String}).count==all.count,try JSONSerialization.data(withJSONObject:all).count<=512*1024 else{fatalError("catalog limits failed")}
  guard let icon=try AppCatalogService.icon(root:root,bundleId:"com.apple.finder"),let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:icon) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width==64,image.height==64 else{fatalError("64px native system icon failed")}
  let cache=root.appendingPathComponent("app-icons",isDirectory:true),fake=Data(repeating:0,count:65536);for i in 0..<129{let url=cache.appendingPathComponent("app-fixture-\(i).png");try fake.write(to:url);try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-86400)],ofItemAtPath:url.path)};_=try AppCatalogService.icon(root:root,bundleId:"com.apple.finder");let files=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:[.fileSizeKey]);let total=try files.reduce(0){$0+(try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)};guard files.count<=128,total<=8*1024*1024,FileManager.default.fileExists(atPath:icon)else{fatalError("icon LRU limits failed")}
  print("PASS: Info-only app metadata/dedup, installed catalog <=512/512KiB, lazy 64px Finder icon, cache <=128/8MiB; no user data read")
 }
}
