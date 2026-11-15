// Dictionary and word-book UI fixtures, no network calls or production data.
import { mount, View, signal } from "nsh";
import { DictionaryCard, WordBook } from "./WordsContent";
function Harness() {
    const words = signal([
        {
            id: "w",
            text: "hello",
            definition: "你好",
            familiar: false,
            count: 2,
            date: 1,
        },
    ]);
    return (
        <View class="flex-1">
            <DictionaryCard
                result={() => ({
                    word: "hello",
                    phonetic: "həˈloʊ",
                    definitions: ["Definition one", "Definition two"],
                    phrases: [{ text: "hello world", translation: "短语释义" }],
                    examples: [
                        { text: "Hello, friend.", translation: "例句译文" },
                    ],
                })}
                onSpeak={() => {}}
                onBook={() => {}}
            />
            <WordBook
                words={words}
                onQuery={() => {}}
                onFamiliar={(id: string) =>
                    words.set(
                        words().map((w) =>
                            w.id === id ? { ...w, familiar: !w.familiar } : w,
                        ),
                    )
                }
            />
        </View>
    );
}
mount(Harness);
