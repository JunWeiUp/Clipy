import { View, Text, signal, effect } from "nsh";
import { Btn, Field, Setting, Card, Chips, cx } from "../ui/primitives";
import { t as tr } from "../ui/locale";

function NumberPreference(p: {
    label: string;
    value: number;
    min: number;
    max: number;
    step?: number;
    onChange: (value: number) => void;
}) {
    const draft = signal(String(p.value)),
        focused = signal(false);
    effect(() => {
        if (!focused()) draft.set(String(p.value));
    });
    const commit = () => {
        const number = Number(draft());
        if (!Number.isFinite(number)) {
            draft.set(String(p.value));
            return;
        }
        const value = Math.max(
            p.min,
            Math.min(p.max, p.step === 1 ? Math.round(number) : number),
        );
        draft.set(String(value));
        p.onChange(value);
    };
    return (
        <View class={cx.row}>
            <Text class="text-[13px] text-foreground flex-1">
                {tr(p.label)}
            </Text>
            <Field
                label={p.label}
                value={draft()}
                class="w-[130px]"
                onFocus={() => focused.set(true)}
                onChange={(value: string) => draft.set(value)}
                onBlur={() => {
                    focused.set(false);
                    commit();
                }}
                onSubmit={commit}
            />
        </View>
    );
}
export function CapturePreferences(p: {
    section: string;
    settings: any;
    save: (key: string, value: any) => void;
    invoke: (name: string, payload?: any) => unknown;
}) {
    const settings = () => p.settings;
    return (
        <View class="gap-5">
            <If when={p.section === "截图"}>
                <Card title={tr("截图")}>
                    <Setting
                        label={tr("截图放大镜")}
                        value={settings().captureMagnifier !== false}
                        onChange={(value: boolean) =>
                            p.save("captureMagnifier", value)
                        }
                    />
                    <Setting
                        label={tr("UI 元素吸附")}
                        description={tr(
                            "需要辅助功能权限；未授权时降级为窗口吸附。",
                        )}
                        value={settings().captureSnapping !== false}
                        onChange={(value: boolean) =>
                            p.save("captureSnapping", value)
                        }
                    />
                    <Setting
                        label={tr("自动保存截图")}
                        value={settings().autoSave}
                        onChange={(value: boolean) => p.save("autoSave", value)}
                    />
                    <Text class={cx.muted}>
                        {tr("截图分辨率：屏幕原生像素")}
                    </Text>
                    <Chips
                        items={[
                            { id: "region", label: "区域" },
                            { id: "window", label: "窗口" },
                            { id: "fullscreen", label: "全屏" },
                        ]}
                        value={settings().captureMode || "region"}
                        onChange={(value: string) =>
                            p.save("captureMode", value)
                        }
                    />
                    <Text class={cx.muted}>{tr("截图后默认动作")}</Text>
                    <Chips
                        items={[
                            { id: "copy", label: "复制" },
                            { id: "save", label: "保存" },
                            { id: "saveAndCopy", label: "保存并复制" },
                            { id: "pin", label: "贴图" },
                        ]}
                        value={settings().captureAction || "copy"}
                        onChange={(value: string) =>
                            p.save("captureAction", value)
                        }
                    />
                    <Field
                        label={tr("保存路径")}
                        readonly
                        value={
                            settings().captureDirectory ||
                            tr("系统图片文件夹 / Screenshots")
                        }
                    />
                    <Btn
                        label={tr("选择保存文件夹")}
                        onPress={() => p.invoke("capture.chooseDirectory")}
                    />
                </Card>
            </If>
            <If when={p.section === "输出与预览"}>
                <Card title={tr("输出与预览")}>
                    <Setting
                        label={tr("完成后显示浮动缩略图")}
                        value={settings().thumbnailEnabled !== false}
                        onChange={(value: boolean) =>
                            p.save("thumbnailEnabled", value)
                        }
                    />
                    <Setting
                        label={tr("连续截图堆叠缩略图")}
                        value={settings().stackThumbnails !== false}
                        onChange={(value: boolean) =>
                            p.save("stackThumbnails", value)
                        }
                    />
                    <Text class={cx.muted}>{tr("缩略图位置")}</Text>
                    <Chips
                        items={[
                            { id: "bottomRight", label: "右下" },
                            { id: "bottomLeft", label: "左下" },
                            { id: "topRight", label: "右上" },
                            { id: "topLeft", label: "左上" },
                        ]}
                        value={settings().thumbnailPosition || "bottomRight"}
                        onChange={(value: string) =>
                            p.save("thumbnailPosition", value)
                        }
                    />
                    <NumberPreference
                        label="缩略图尺寸"
                        value={Number(settings().thumbnailScale || 1)}
                        min={0.5}
                        max={2}
                        onChange={(value) => p.save("thumbnailScale", value)}
                    />
                    <Setting
                        label={tr("捕获鼠标光标")}
                        value={settings().captureCursor}
                        onChange={(value: boolean) =>
                            p.save("captureCursor", value)
                        }
                    />
                    <Setting
                        label={tr("完成后播放提示音")}
                        value={settings().captureSound}
                        onChange={(value: boolean) =>
                            p.save("captureSound", value)
                        }
                    />
                    <Setting
                        label={tr("缩小 Retina 截图到 1×")}
                        value={settings().downscaleRetina}
                        onChange={(value: boolean) =>
                            p.save("downscaleRetina", value)
                        }
                    />
                    <Text class={cx.muted}>{tr("保存格式")}</Text>
                    <Chips
                        items={[
                            { id: "png", label: "PNG" },
                            { id: "jpeg", label: "JPEG" },
                            { id: "tiff", label: "TIFF" },
                            { id: "heic", label: "HEIC" },
                        ]}
                        value={settings().saveFormat || "png"}
                        onChange={(value: string) =>
                            p.save("saveFormat", value.toLowerCase())
                        }
                    />
                    <NumberPreference
                        label="图片质量（0–100）"
                        value={Number(settings().saveQuality ?? 85)}
                        min={0}
                        max={100}
                        step={1}
                        onChange={(value) => p.save("saveQuality", value)}
                    />
                </Card>
            </If>
            <If when={p.section === "滚动与标注"}>
                <Card title={tr("滚动截图")}>
                    <NumberPreference
                        label="最大高度（像素）"
                        value={Number(settings().scrollMaxHeight || 20000)}
                        min={1000}
                        max={40000}
                        step={1}
                        onChange={(value) => p.save("scrollMaxHeight", value)}
                    />
                    <Setting
                        label={tr("自动滚动")}
                        value={settings().scrollAutomatic}
                        onChange={(value: boolean) =>
                            p.save("scrollAutomatic", value)
                        }
                    />
                    <NumberPreference
                        label="自动滚动速度"
                        value={Number(settings().scrollSpeed || 3)}
                        min={1}
                        max={10}
                        step={1}
                        onChange={(value) => p.save("scrollSpeed", value)}
                    />
                    <Setting
                        label={tr("冻结表头检测")}
                        value={settings().scrollFreezeHeader !== false}
                        onChange={(value: boolean) =>
                            p.save("scrollFreezeHeader", value)
                        }
                    />
                    <Setting
                        label={tr("显示对齐辅助线")}
                        value={settings().showGuides}
                        onChange={(value: boolean) =>
                            p.save("showGuides", value)
                        }
                    />
                    <Setting
                        label={tr("记住上次使用的工具")}
                        value={settings().rememberTool}
                        onChange={(value: boolean) =>
                            p.save("rememberTool", value)
                        }
                    />
                    <Setting
                        label={tr("工具提示中显示快捷键")}
                        value={settings().showTooltips}
                        onChange={(value: boolean) =>
                            p.save("showTooltips", value)
                        }
                    />
                    <Setting
                        label={tr("画笔压感")}
                        value={settings().stylusPressure}
                        onChange={(value: boolean) =>
                            p.save("stylusPressure", value)
                        }
                    />
                    <Setting
                        label={tr("智能荧光笔")}
                        value={settings().smartHighlighter}
                        onChange={(value: boolean) =>
                            p.save("smartHighlighter", value)
                        }
                    />
                </Card>
            </If>
            <If when={p.section === "美化与特效"}>
                <Card title={tr("美化与特效")}>
                    <Setting
                        label={tr("默认启用美化包裹")}
                        value={settings().beautify}
                        onChange={(value: boolean) => p.save("beautify", value)}
                    />
                    <Each
                        of={[
                            {
                                key: "beautifyPadding",
                                label: "边距",
                                value: 48,
                                min: 0,
                                max: 200,
                            },
                            {
                                key: "beautifyRadius",
                                label: "圆角",
                                value: 12,
                                min: 0,
                                max: 200,
                            },
                            {
                                key: "beautifyShadow",
                                label: "阴影",
                                value: 20,
                                min: 0,
                                max: 100,
                            },
                            {
                                key: "brightness",
                                label: "亮度",
                                value: 0,
                                min: -1,
                                max: 1,
                            },
                            {
                                key: "contrast",
                                label: "对比度",
                                value: 1,
                                min: 0,
                                max: 4,
                            },
                            {
                                key: "saturation",
                                label: "饱和度",
                                value: 1,
                                min: 0,
                                max: 4,
                            },
                            {
                                key: "sharpness",
                                label: "锐度",
                                value: 0,
                                min: 0,
                                max: 4,
                            },
                        ]}
                    >
                        {(item) => (
                            <NumberPreference
                                label={item().label}
                                value={Number(
                                    settings()[item().key] ?? item().value,
                                )}
                                min={item().min}
                                max={item().max}
                                onChange={(value) => p.save(item().key, value)}
                            />
                        )}
                    </Each>
                </Card>
            </If>
        </View>
    );
}
