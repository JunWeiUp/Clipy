import { expect, open, test } from "nsh/test";

test("empty library offers real navigation without demo content",async()=>{
 const app=await open("./App.tsx",{width:1140,height:760});
 expect(app.texts()).toContain("暂无历史记录");
 await app.press("片段");expect(app.texts()).toContain("片段库");
 await app.press("设备");expect(app.texts()).toContain("我的设备");
 await app.press("通知");expect(app.texts()).toContain("手机通知");
});
test("password generation is available without native service",async()=>{
 const app=await open("./App.tsx",{width:1140,height:760});
 await app.press("工具");
 expect(app.texts()).toContain("生成密码");
 await app.press("重新生成");
 expect(app.texts().some((text:string)=>text.length===20&&!text.includes(" "))).toBe(true);
});
