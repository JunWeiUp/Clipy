import { View, Text, Scroll, signal, cleanup } from "nsh";
import { Window } from "nsh/desktop";
import { Btn, Field, Setting, Empty, cx } from "../ui/primitives";
import { t } from "../ui/locale";

export function openExcludedApps(model: any, actions: any) {
    const window = Window.open(
        () => <ExcludedApps model={model} actions={actions} />,
        {
            id: "excluded-apps",
            title: t("排除应用"),
            kind: "normal",
            defaultSize: { width: 560, height: 620 },
            minSize: { width: 450, height: 450 },
            defaultPosition: "center",
        },
    );
    window.focus();
    return window;
}
function ExcludedApps(p: { model: any; actions: any }) {
    const apps = signal<any[]>([]),
        query = signal(""),
        manual = signal(""),
        error = signal(""),
        loading = signal(true);
    let closed = false;
    const excluded = () => p.model.state().settings.excludedApps || [];
    const save = (ids: string[]) =>
        p.actions.saveSettings({ excludedApps: [...new Set(ids)] });
    const toggle = (id: string, value: boolean) =>
        save(
            value
                ? [...excluded(), id]
                : excluded().filter((existing: string) => existing !== id),
        );
    const load = async () => {
        loading.set(true);
        try {
            const rows = await p.actions.invoke("system.listApps");
            if (!closed && Array.isArray(rows)) apps.set(rows);
        } catch (e) {
            if (!closed) error.set(String(e));
        } finally {
            if (!closed) loading.set(false);
        }
    };
    void load();
    cleanup(() => {
        closed = true;
    });
    const add = () => {
        const value = manual().trim();
        if (
            !/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(value) ||
            value.length > 255
        ) {
            error.set(t("请输入有效的 Bundle ID"));
            return;
        }
        void save([...excluded(), value]);
        manual.set("");
        error.set("");
    };
    return (
        <View class="flex-1 bg-background p-5 gap-4">
            <Text class="text-[20px] font-semibold text-foreground">
                {t("排除应用")}
            </Text>
            <Text class="text-[12px] leading-[19px] text-muted-foreground">
                {t(
                    "在这些应用中复制的内容不会写入历史，也不会同步到其他设备。",
                )}
            </Text>
            <View class={cx.row}>
                <Field
                    class="flex-1"
                    label={t("搜索应用或 Bundle ID")}
                    value={query()}
                    onChange={(value: string) => query.set(value)}
                />
                <Btn label={t("刷新")} onPress={() => void load()} />
            </View>
            <Scroll class="flex-1">
                <Each
                    of={excluded().filter(
                        (id: string) => !apps().some((a) => a.bundleId === id),
                    )}
                >
                    {(id: any) => (
                        <Setting
                            label={id()}
                            description={t("自定义应用")}
                            translateLabel={false}
                            value
                            onChange={() => void toggle(id(), false)}
                        />
                    )}
                </Each>
                <Each
                    of={apps().filter(
                        (app) =>
                            !query() ||
                            `${app.name} ${app.bundleId}`
                                .toLowerCase()
                                .includes(query().toLowerCase()),
                    )}
                >
                    {(app: any) => (
                        <Setting
                            label={app().name}
                            description={app().bundleId}
                            translateLabel={false}
                            value={excluded().includes(app().bundleId)}
                            onChange={(value: boolean) =>
                                void toggle(app().bundleId, value)
                            }
                        />
                    )}
                </Each>
                <If when={!apps().length && !loading()}>
                    <Empty
                        title={t("暂无应用")}
                        description={t("你也可以手动填写 Bundle ID。")}
                    />
                </If>
                <If when={loading()}>
                    <Text class={cx.muted}>{t("正在加载…")}</Text>
                </If>
            </Scroll>
            <View class="border-t border-border pt-4 gap-2">
                <Text class={cx.muted}>{t("手动添加 Bundle ID")}</Text>
                <View class={cx.row}>
                    <Field
                        class="flex-1"
                        placeholder="com.example.app"
                        value={manual()}
                        onChange={(value: string) => manual.set(value)}
                        onSubmit={add}
                    />
                    <Btn label={t("添加")} primary onPress={add} />
                </View>
            </View>
            <If when={error()}>
                <Text class="text-[12px] text-red-500">{error()}</Text>
            </If>
        </View>
    );
}
