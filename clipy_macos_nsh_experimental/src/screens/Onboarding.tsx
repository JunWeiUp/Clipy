import { t as tr } from "../ui/locale";
import { View, Text, signal } from "nsh";
import { Btn, Card, Setting, cx } from "../ui/primitives";
import { Icon } from "../ui/Icon";
export function Onboarding(p: { state: () => any; actions: any }) {
    const step = signal(1),
        permissions = signal<Record<string, boolean>>({});
    const done = () => {
        void p.actions.saveSettings?.({ onboardingComplete: true });
        p.actions.navigate?.("history");
    };
    const request = async (kind: string) => {
        await p.actions.invoke?.("permissions.request", { kind });
        const status = await p.actions.invoke?.("permissions.status");
        if (status) permissions.set(status);
    };
    return (
        <View class="flex-1 flex-row bg-background">
            <View class="w-[340px] bg-[#176BEB] p-[30px] gap-5">
                <View class="h-[70px]" />
                <View class="w-[104px] h-[104px] rounded-[28px] bg-white/15 items-center justify-center">
                    <Icon name="clipboard" size={64} color="#FFFFFF" />
                </View>
                <Text class="text-[30px] font-bold text-white mt-2">
                    {tr("欢迎使用 Clipy")}
                </Text>
                <Text class="text-[14px] leading-[23px] text-white/85">
                    {tr(
                        "复制过的内容随手可取，常用文字一键输入，手机和 Mac 之间自由流转。",
                    )}
                </Text>
                <View class="flex-1" />
                <View class="gap-4">
                    <Each
                        of={[
                            { icon: "history", text: "剪贴板历史与片段" },
                            {
                                icon: "devices",
                                text: "与 Android、iOS、Windows 同步",
                            },
                            {
                                icon: "capture",
                                text: "截图、标注、录屏与文字识别",
                            },
                        ]}
                    >
                        {(f) => (
                            <View class={cx.row}>
                                <Icon name={f().icon} color="#FFFFFF" />
                                <Text class="text-[12px] text-white">
                                    {tr(f().text)}
                                </Text>
                            </View>
                        )}
                    </Each>
                </View>
            </View>
            <View class="flex-1 px-10 py-9 gap-3">
                <Text class="text-[12px] text-blue-500 font-semibold">
                    {tr("第")}
                    {step()}
                    {tr("步，共 3 步")}
                </Text>
                <If when={step() === 1}>
                    <Text class="text-[23px] font-bold text-foreground">
                        {tr("随时唤起 Clipy")}
                    </Text>
                    <Text class="text-[13px] text-muted-foreground leading-[22px] mb-5">
                        {tr(
                            "Clipy 常驻菜单栏。点按菜单栏图标，打开面板，查看最近复制、片段、设备与工具。",
                        )}
                    </Text>
                    <Card translateTitle={false} title={tr("全局搜索快捷键")}>
                        <Text class="text-[13px] text-muted-foreground">
                            {tr("在任何应用中打开历史搜索窗口。")}
                        </Text>
                        <Text class="text-[24px] text-foreground font-semibold">
                            {p.state().settings?.searchShortcut || "⇧⌘F"}
                        </Text>
                    </Card>
                    <Card>
                        <Setting
                            label={tr("登录时启动")}
                            description={tr("开机后自动在菜单栏常驻")}
                            value={p.state().settings?.launchAtLogin}
                            onChange={(v: boolean) =>
                                p.actions.saveSettings?.({ launchAtLogin: v })
                            }
                        />
                    </Card>
                    <Text class={cx.muted}>
                        {tr("快捷键与开机启动可随时在偏好设置中修改。")}
                    </Text>
                </If>
                <If when={step() === 2}>
                    <Text class="text-[23px] font-bold text-foreground">
                        {tr("开启需要的权限")}
                    </Text>
                    <Text class="text-[13px] text-muted-foreground leading-[22px] mb-4">
                        {tr(
                            "权限可以现在授权，也会在首次用到时请求；之后可在偏好设置中查看。",
                        )}
                    </Text>
                    <Each
                        of={[
                            {
                                id: "accessibility",
                                label: "辅助功能",
                                hint: "自动粘贴；未授权时仍能复制内容",
                                icon: "clipboard",
                            },
                            {
                                id: "screen",
                                label: "屏幕录制",
                                hint: "截图与录屏必需",
                                icon: "capture",
                            },
                            {
                                id: "notifications",
                                label: "通知",
                                hint: "收到文件与手机通知时提醒",
                                icon: "notifications",
                            },
                        ]}
                    >
                        {(r) => (
                            <Card>
                                <View class={cx.row}>
                                    <Icon
                                        name={r().icon}
                                        color="#087BFF"
                                        size={24}
                                    />
                                    <View class="flex-1 gap-1">
                                        <Text class="text-[14px] font-semibold text-foreground">
                                            {tr(r().label)}
                                        </Text>
                                        <Text class={cx.muted}>
                                            {tr(r().hint)}
                                        </Text>
                                    </View>
                                    <Btn
                                        label={tr(
                                            permissions()[r().id]
                                                ? "已授权"
                                                : "去授权",
                                        )}
                                        disabled={permissions()[r().id]}
                                        onPress={() => void request(r().id)}
                                    />
                                </View>
                            </Card>
                        )}
                    </Each>
                    <Text class="text-[11px] text-muted-foreground leading-[19px]">
                        {tr(
                            "输入监控、麦克风和摄像头只在使用相应录屏功能时请求。",
                        )}
                    </Text>
                </If>
                <If when={step() === 3}>
                    <Text class="text-[23px] font-bold text-foreground">
                        {tr("连接你的设备（可选）")}
                    </Text>
                    <Text class="text-[13px] text-muted-foreground leading-[22px] mb-4">
                        {tr(
                            "在其他设备上打开 Clipy，与这台 Mac 连接同一局域网，即可同步剪贴板和互传文件。",
                        )}
                    </Text>
                    <Card
                        translateTitle={false}
                        title={p.state().settings?.deviceName || tr("这台 Mac")}
                    >
                        <Text class={cx.muted}>
                            {tr("局域网端口")}
                            {p.state().settings?.port || 5567}
                        </Text>
                        <Btn
                            label={tr("刷新设备")}
                            onPress={() => p.actions.invoke?.("lan.status")}
                        />
                        <Each of={p.state().devices || []}>
                            {(d: any) => (
                                <View class={cx.row}>
                                    <Icon name="devices" />
                                    <Text class="text-[13px] text-foreground flex-1">
                                        {d().name || d().id}
                                    </Text>
                                    <Text class={cx.muted}>
                                        {tr(d().online ? "在线" : "离线")}
                                    </Text>
                                </View>
                            )}
                        </Each>
                        <If when={!(p.state().devices || []).length}>
                            <Text class={cx.muted}>
                                {tr("未发现设备，可稍后在设备页面手动添加。")}
                            </Text>
                        </If>
                    </Card>
                    <Text class="text-[12px] text-muted-foreground leading-[20px]">
                        {tr("不在同一网络？稍后可在「公网设备组」中加入。")}
                    </Text>
                </If>
                <View class="flex-1" />
                <View class="flex-row items-center gap-2">
                    <Each of={[1, 2, 3]}>
                        {(n) => (
                            <View
                                class={`h-[7px] rounded-full ${step() === n() ? "w-[20px] bg-blue-500" : "w-[7px] bg-secondary"}`}
                            />
                        )}
                    </Each>
                    <View class="flex-1" />
                    <Btn label={tr("跳过")} onPress={done} />
                    <If when={step() > 1}>
                        <Btn
                            label={tr("上一步")}
                            onPress={() => step.set(step() - 1)}
                        />
                    </If>
                    <Btn
                        label={tr(step() === 3 ? "开始使用" : "继续")}
                        primary
                        onPress={() =>
                            step() === 3 ? done() : step.set(step() + 1)
                        }
                    />
                </View>
            </View>
        </View>
    );
}
