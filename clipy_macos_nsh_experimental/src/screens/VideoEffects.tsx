import { t as tr } from "../ui/locale";
import { View, Text } from "nsh";
import { Btn, Field, Chips, Card, cx } from "../ui/primitives";
export function VideoEffects(p: {
    items: () => any[];
    actions: any;
    start: () => number;
    end: () => number;
}) {
    const update = (id: string, patch: any) =>
        p.actions.set?.(
            "videoEffects",
            p
                .items()
                .map((effect) =>
                    effect.id === id ? { ...effect, ...patch } : effect,
                ),
        );
    const numeric = (effect: any, key: string, value: string) => {
        let number = Number(value);
        if (!Number.isFinite(number)) return;
        if (key === "start")
            number = Math.max(
                p.start(),
                Math.min(Number(effect.end) || p.end(), number),
            );
        if (key === "end")
            number = Math.max(
                Number(effect.start) || p.start(),
                Math.min(p.end(), number),
            );
        if (["x", "y", "width", "height"].includes(key))
            number = Math.max(0, Math.min(1, number));
        if (["speed", "zoom"].includes(key))
            number = Math.max(0.1, Math.min(10, number));
        if (key === "duration") number = Math.max(0.1, Math.min(30, number));
        update(effect.id, { [key]: number });
    };
    const is = (effect: any, kind: string) =>
        [
            kind,
            (
                {
                    cut: "剪切",
                    speed: "变速",
                    freeze: "定格",
                    zoom: "缩放",
                    mask: "遮挡",
                    text: "文字",
                } as any
            )[kind],
        ].includes(effect.type);
    return (
        <View class="gap-3">
            <Each of={p.items()} key={(e: any) => e.id}>
                {(get: any) => (
                    <Card>
                        <View class={cx.row}>
                            <Text class="text-[14px] font-semibold text-foreground flex-1">
                                {tr(
                                    (
                                        {
                                            cut: "剪切",
                                            speed: "变速",
                                            freeze: "定格",
                                            zoom: "缩放",
                                            mask: "遮挡",
                                            text: "文字",
                                        } as any
                                    )[get().type] || get().type,
                                )}
                            </Text>
                            <Btn
                                label={tr("删除效果")}
                                danger
                                onPress={() =>
                                    p.actions.set?.(
                                        "videoEffects",
                                        p
                                            .items()
                                            .filter((e) => e.id !== get().id),
                                    )
                                }
                            />
                        </View>
                        <View class={cx.row}>
                            <Field
                                label={tr("开始（秒）")}
                                value={String(get().start ?? p.start())}
                                onChange={(v: string) =>
                                    numeric(get(), "start", v)
                                }
                            />
                            <Field
                                label={tr("结束（秒）")}
                                value={String(get().end ?? p.end())}
                                onChange={(v: string) =>
                                    numeric(get(), "end", v)
                                }
                            />
                        </View>
                        <If when={is(get(), "speed")}>
                            <Field
                                label={tr("播放倍速")}
                                value={String(get().speed || 2)}
                                onChange={(v: string) =>
                                    numeric(get(), "speed", v)
                                }
                            />
                        </If>
                        <If when={is(get(), "freeze")}>
                            <Field
                                label={tr("定格时长（秒）")}
                                value={String(get().duration || 1)}
                                onChange={(v: string) =>
                                    numeric(get(), "duration", v)
                                }
                            />
                            <Text class={cx.muted}>
                                {tr("定格插入静音帧，随后继续原视频音轨。")}
                            </Text>
                        </If>
                        <If when={is(get(), "zoom")}>
                            <Field
                                label={tr("缩放倍数")}
                                value={String(get().zoom || 2)}
                                onChange={(v: string) =>
                                    numeric(get(), "zoom", v)
                                }
                            />
                        </If>
                        <If when={is(get(), "mask")}>
                            <Chips
                                items={[
                                    { id: "solid", label: "纯色遮罩" },
                                    { id: "mosaic", label: "马赛克" },
                                    { id: "blur", label: "模糊" },
                                ]}
                                value={get().mode || "mosaic"}
                                onChange={(v: string) =>
                                    update(get().id, { mode: v })
                                }
                            />
                        </If>
                        <If when={is(get(), "text")}>
                            <Field
                                label={tr("文字内容")}
                                multiline
                                value={get().text || ""}
                                onChange={(v: string) =>
                                    update(get().id, { text: v })
                                }
                            />
                            <Field
                                label={tr("字体大小")}
                                value={String(get().fontSize || 24)}
                                onChange={(v: string) =>
                                    numeric(get(), "fontSize", v)
                                }
                            />
                        </If>
                        <If
                            when={
                                is(get(), "zoom") ||
                                is(get(), "mask") ||
                                is(get(), "text")
                            }
                        >
                            <Text class={cx.muted}>
                                {tr("画面区域（0–1，相对于画面宽高）")}
                            </Text>
                            <View class="flex-row flex-wrap gap-2">
                                <Each of={["x", "y", "width", "height"]}>
                                    {(key) => (
                                        <Field
                                            label={key()}
                                            value={String(
                                                get()[key()] ??
                                                    (key() === "width" ||
                                                    key() === "height"
                                                        ? 0.5
                                                        : 0.25),
                                            )}
                                            onChange={(v: string) =>
                                                numeric(get(), key(), v)
                                            }
                                        />
                                    )}
                                </Each>
                            </View>
                        </If>
                        <If when={is(get(), "cut")}>
                            <Text class={cx.muted}>
                                {tr("删除选中时间段，后续片段向前拼接。")}
                            </Text>
                        </If>
                    </Card>
                )}
            </Each>
        </View>
    );
}
