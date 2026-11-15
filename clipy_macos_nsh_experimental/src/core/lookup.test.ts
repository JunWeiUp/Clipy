import { test, expect } from "nsh/test";
import { parseDictionary } from "./lookup";
test("dictionary returns all definitions, IPA and bilingual examples", () => {
    const result = parseDictionary(
        {
            ec: {
                word: [
                    {
                        usphone: "wɜːrd",
                        trs: [
                            { tr: [{ l: { i: ["n. 单词"] } }] },
                            { tr: [{ l: { i: ["v. 措辞"] } }] },
                        ],
                    },
                ],
            },
            blng_sents_part: {
                "sentence-pair": [
                    {
                        sentence: "A word.",
                        "sentence-translation": "一个单词。",
                    },
                ],
            },
        },
        "word",
    );
    expect(result.definition).toBe("n. 单词\nv. 措辞");
    expect(result.phonetic).toBe("wɜːrd");
    expect(result.examples[0]?.translation).toBe("一个单词。");
});
test("dictionary empty result is an explicit error rather than saved blank word", () => {
    let failed = false;
    try {
        parseDictionary({}, "missing");
    } catch {
        failed = true;
    }
    expect(failed).toBe(true);
});
