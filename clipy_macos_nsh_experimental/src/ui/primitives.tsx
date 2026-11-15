import { t as tr } from "./locale";
import { Text, View } from "nsh";
import { Input, Switch } from "nsh/base";

export const cx = {
    root: "flex-1 flex-row bg-background text-foreground",
    side: "w-[220px] bg-sidebar border-r border-border p-3 gap-1",
    pane: "flex-1 min-w-0 bg-background",
    bar: "h-[56px] flex-row items-center gap-2 px-5 border-b border-border",
    row: "flex-row items-center gap-3",
    muted: "text-[12px] text-muted-foreground",
    text: "text-[13px] text-foreground",
    group: "rounded-xl bg-card border border-border p-4 gap-3",
};
export function Btn(p: any) {
    return (
        <View
            role="button"
            disabled={!!p.disabled}
            accessibilityLabel={
                p.accessibilityLabel ||
                (p.translateLabel === false ? p.label : tr(p.label))
            }
            onPress={() => {
                if (!p.disabled) p.onPress?.();
            }}
            class={`${p.primary ? "bg-[#087BFF]" : p.danger ? "bg-red-500/10" : "bg-secondary"} rounded-md px-3 py-[6px] items-center justify-center ${p.disabled ? "opacity-40" : "hover:opacity-80 active:opacity-60"}`}
        >
            <Text
                class={`${p.primary ? "text-white" : p.danger ? "text-red-500" : "text-foreground"} text-[12px] font-medium`}
            >
                {p.translateLabel === false ? p.label : tr(p.label)}
            </Text>
        </View>
    );
}
export function Label(p: any) {
    return (
        <Text class="text-[11px] font-semibold text-muted-foreground mt-4 mb-1 px-2">
            {typeof p.children === "string" ? tr(p.children) : p.children}
        </Text>
    );
}
export function Nav(p: any) {
    return (
        <View
            role="button"
            accessibilityLabel={
                p.translateLabel === false ? p.label : tr(p.label)
            }
            onPress={p.onPress}
            class={`flex-row items-center gap-2 h-[33px] px-[10px] rounded-lg ${p.active ? "bg-blue-500/15" : "hover:bg-secondary"}`}
        >
            <Text
                class={`${p.active ? "text-[#087BFF]" : "text-muted-foreground"} text-[15px] w-[20px]`}
            >
                {p.icon || "○"}
            </Text>
            <Text
                style={{ numberOfLines: 1 }}
                class={`text-[13px] flex-1 min-w-0 ${p.active ? "text-[#087BFF] font-medium" : "text-foreground"}`}
            >
                {p.translateLabel === false ? p.label : tr(p.label)}
            </Text>
            <If when={p.count !== undefined}>
                <Text class={cx.muted}>{p.count}</Text>
            </If>
        </View>
    );
}
export function Field(p: any) {
    return (
        <Input
            accessibilityLabel={tr(p.label || p.placeholder)}
            value={p.value ?? ""}
            placeholder={tr(p.placeholder || p.label)}
            masked={p.masked}
            maxLength={p.maxLength}
            multiline={p.multiline}
            readonly={p.readonly}
            onFocus={() => p.onFocus?.()}
            onBlur={() => p.onBlur?.()}
            onChange={(e) => p.onChange?.(e.value)}
            onSubmit={() => p.onSubmit?.()}
            class={`bg-secondary rounded-lg px-3 py-2 text-[13px] text-foreground ${p.class || ""}`}
        />
    );
}
export function Setting(p: any) {
    return (
        <View class="flex-row items-center gap-4 py-2">
            <View class="flex-1 gap-1">
                <Text class={cx.text}>
                    {p.translateLabel === false ? p.label : tr(p.label)}
                    {tr(p.disabled ? " · 待实现" : "")}
                </Text>
                <If
                    when={
                        p.translateDescription === false
                            ? p.description
                            : tr(p.description)
                    }
                >
                    <Text class="text-[11px] leading-[17px] text-muted-foreground">
                        {p.translateDescription === false
                            ? p.description
                            : tr(p.description)}
                    </Text>
                </If>
            </View>
            <Switch
                disabled={!!p.disabled}
                checked={!!p.value}
                onChange={(e) => p.onChange?.(e.checked)}
                accessibilityLabel={
                    p.translateLabel === false ? p.label : tr(p.label)
                }
                class="flex-row"
                trackClass="w-[32px] h-[19px] rounded-full bg-muted checked:bg-blue-500 p-[2px]"
                thumbClass="w-[15px] h-[15px] rounded-full bg-white checked:translate-x-[13px]"
            />
        </View>
    );
}
export function Empty(p: any) {
    return (
        <View class="flex-1 items-center justify-center px-10 py-16 gap-3">
            <Text class="text-[34px] text-muted-foreground">
                {p.icon || "▤"}
            </Text>
            <Text class="text-[17px] font-semibold text-foreground">
                {p.translateTitle === false ? p.title : tr(p.title)}
            </Text>
            <Text class="text-[12px] text-center text-muted-foreground leading-[19px]">
                {tr(p.description || "")}
            </Text>
            <If when={p.action}>
                <Btn label={p.action} primary onPress={p.onPress} />
            </If>
        </View>
    );
}
export function Header(p: any) {
    return (
        <View class={cx.bar}>
            <Text class="text-[17px] font-semibold text-foreground flex-1">
                {p.translateTitle === false ? p.title : tr(p.title)}
            </Text>
            {typeof p.children === "string" ? tr(p.children) : p.children}
        </View>
    );
}
export function Card(p: any) {
    return (
        <View class={cx.group}>
            <If when={p.translateTitle === false ? p.title : tr(p.title)}>
                <Text class="text-[14px] font-semibold text-foreground">
                    {p.translateTitle === false ? p.title : tr(p.title)}
                </Text>
            </If>
            {typeof p.children === "string" ? tr(p.children) : p.children}
        </View>
    );
}
export function Chips(p: any) {
    return (
        <View class="flex-row items-center gap-1 flex-wrap">
            <Each of={p.items}>
                {(getItem: any) => (
                    <View
                        role="button"
                        accessibilityLabel={
                            p.translateLabels === false
                                ? typeof getItem() === "string"
                                    ? getItem()
                                    : getItem().label
                                : tr(
                                      typeof getItem() === "string"
                                          ? getItem()
                                          : getItem().label,
                                  )
                        }
                        onPress={() =>
                            p.onChange(
                                typeof getItem() === "string"
                                    ? getItem()
                                    : getItem().id,
                            )
                        }
                        class={`rounded-md px-2 py-1 ${p.value === (typeof getItem() === "string" ? getItem() : getItem().id) ? "bg-blue-500/15" : "bg-secondary"}`}
                    >
                        <Text
                            class={`text-[11px] ${p.value === (typeof getItem() === "string" ? getItem() : getItem().id) ? "text-[#087BFF]" : "text-muted-foreground"}`}
                        >
                            {p.translateLabels === false
                                ? typeof getItem() === "string"
                                    ? getItem()
                                    : getItem().label
                                : tr(
                                      typeof getItem() === "string"
                                          ? getItem()
                                          : getItem().label,
                                  )}
                        </Text>
                    </View>
                )}
            </Each>
        </View>
    );
}
export const read = (v: any) => (typeof v === "function" ? v() : v);
export const textOf = (v: any) =>
    String(v?.content ?? v?.text ?? v?.body ?? "");
export const titleOf = (value: any) => {
    const title = String(
        value?.title || value?.name || textOf(value).split("\n")[0] || "未命名",
    );
    if (
        value?.mediaId &&
        ["image", "pdf"].includes(value.type) &&
        title === value.content &&
        title.startsWith("media:")
    )
        return value.type === "pdf" ? tr("PDF 文档") : tr("图片预览");
    return title;
};
