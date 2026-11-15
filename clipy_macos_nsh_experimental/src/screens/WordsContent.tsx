import { t as tr } from "../ui/locale";
import { View, Text, signal } from "nsh";
import { Btn, Card, Field, Chips, Setting, Empty, cx } from "../ui/primitives";
export function DictionaryCard(p: {
    result: () => any;
    onSpeak: (text: string) => void;
    onBook: () => void;
}) {
    const definitions = () =>
        p.result()?.definitions || [
            p.result()?.definition ||
                p.result()?.translation ||
                String(p.result() || ""),
        ];
    return (
        <Card>
            <View class={cx.row}>
                <Text class="text-[28px] font-semibold text-foreground flex-1">
                    {p.result()?.word || ""}
                </Text>
                <Btn
                    label={tr("朗读")}
                    onPress={() => p.onSpeak(p.result()?.word || "")}
                />
                <Btn label={tr("查看单词表")} onPress={p.onBook} />
            </View>
            <Text class={cx.muted}>
                {p.result()?.phonetic || p.result()?.ipa || ""} ·{" "}
                {tr(p.result()?.provider || "词典")}
            </Text>
            <Each of={definitions()}>
                {(d: any) => (
                    <Text class="text-[14px] leading-[24px] text-foreground">
                        {d()}
                    </Text>
                )}
            </Each>
            <If when={p.result()?.phrases?.length}>
                <Text class="text-[15px] font-semibold text-foreground mt-3">
                    {tr("常用短语")}
                </Text>
                <Each of={(p.result()?.phrases || []).slice(0, 100)}>
                    {(phrase: any) => (
                        <View class="gap-1 border-t border-border pt-3">
                            <Text class="text-[14px] font-medium text-foreground">
                                {phrase().text}
                            </Text>
                            <Text class="text-[13px] text-muted-foreground">
                                {phrase().translation}
                            </Text>
                        </View>
                    )}
                </Each>
            </If>
            <If when={p.result()?.examples?.length}>
                <Text class="text-[15px] font-semibold text-foreground mt-3">
                    {tr("双语例句")}
                </Text>
                <Each of={(p.result()?.examples || []).slice(0, 20)}>
                    {(example: any) => (
                        <View class="gap-1 border-t border-border pt-3">
                            <View class={cx.row}>
                                <Text class="text-[14px] leading-[22px] text-foreground flex-1">
                                    {example().text}
                                </Text>
                                <Btn
                                    label={tr("朗读例句")}
                                    onPress={() => p.onSpeak(example().text)}
                                />
                            </View>
                            <Text class="text-[13px] leading-[21px] text-muted-foreground">
                                {example().translation}
                            </Text>
                        </View>
                    )}
                </Each>
            </If>
        </Card>
    );
}
export function WordBook(p: {
    words: () => any[];
    onQuery: (word: string) => void;
    onFamiliar: (id: string) => void;
}) {
    const familiar = signal("unfamiliar"),
        hidden = signal(false),
        query = signal("");
    const rows = () =>
        p
            .words()
            .filter(
                (w) =>
                    (familiar() === "all" ||
                        !!w.familiar === (familiar() === "familiar")) &&
                    (!query() ||
                        `${w.text} ${w.definition}`
                            .toLowerCase()
                            .includes(query().toLowerCase())),
            );
    return (
        <View class="gap-4">
            <Text class="text-[24px] font-semibold text-foreground">
                {tr("单词表")}
            </Text>
            <View class={cx.row}>
                <Chips
                    items={[
                        {
                            id: "unfamiliar",
                            label: tr("不熟悉 ({0})", {
                                "0": p.words().filter((w) => !w.familiar)
                                    .length,
                            }),
                        },
                        {
                            id: "familiar",
                            label: tr("熟悉 ({0})", {
                                "0": p.words().filter((w) => w.familiar).length,
                            }),
                        },
                        { id: "all", label: "全部" },
                    ]}
                    value={familiar()}
                    onChange={(v: string) => familiar.set(v)}
                />
                <View class="flex-1" />
                <Setting
                    label={tr("隐藏中文释义")}
                    value={hidden()}
                    onChange={(v: boolean) => hidden.set(v)}
                />
            </View>
            <Field
                placeholder={tr("搜索单词与释义")}
                value={query()}
                onChange={(v: string) => query.set(v)}
            />
            <Text class={cx.muted}>
                {tr("勾选表示熟悉，取消勾选移回不熟悉。")}
            </Text>
            <Each of={rows()} key={(w: any) => w.id}>
                {(w: any) => (
                    <Card>
                        <Setting
                            translateLabel={false}
                            translateDescription={false}
                            label={w().text}
                            description={hidden() ? "" : w().definition || ""}
                            value={w().familiar}
                            onChange={() => p.onFamiliar(w().id)}
                        />
                        <View class={cx.row}>
                            <Text class="text-[11px] text-muted-foreground flex-1">
                                {tr("查询次数:")}
                                {w().count || 0}
                                {tr("· 最近查询:")}
                                {w().date
                                    ? new Date(w().date).toLocaleString()
                                    : ""}
                            </Text>
                            <Btn
                                label={tr("查询")}
                                onPress={() => p.onQuery(w().text)}
                            />
                        </View>
                    </Card>
                )}
            </Each>
            <If when={!rows().length}>
                <Empty
                    title={tr(
                        p.words().length
                            ? "这个分组还没有单词"
                            : "还没有收藏单词",
                    )}
                    description={tr(
                        p.words().length
                            ? "试试切换分组或修改搜索关键词。"
                            : "查询单词后会自动保存到单词表。",
                    )}
                />
            </If>
        </View>
    );
}
