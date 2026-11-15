import { signal } from "nsh";
import en from "./locale/en.json";
import zh from "./locale/zh-CN.json";
export type AppLocale = "zh-CN" | "en";
const current = signal<AppLocale>("zh-CN");
const english = en as Record<string, string>;
export const locale = () => current();
export function setLocale(value: string) {
    current.set(value.toLowerCase().startsWith("en") ? "en" : "zh-CN");
}
const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const buildPatterns = () =>
    Object.keys(english)
        .filter((key) => /\{\d+\}/.test(key))
        .map((key) => {
            const indexes: string[] = [];
            const expression = key
                .split(/(\{\d+\})/g)
                .map((part) =>
                    /^\{\d+\}$/.test(part)
                        ? (indexes.push(part.slice(1, -1)), "([\\s\\S]*?)")
                        : escape(part),
                )
                .join("");
            return {
                key,
                indexes,
                pattern: new RegExp("^" + expression + "$"),
            };
        });
let patterns = buildPatterns();
export function t(text: unknown, params?: Record<string, unknown>): string {
    const input = text == null ? "" : String(text);
    const isEnglish = current() === "en";
    let result = isEnglish
        ? english[input] || input
        : (zh as Record<string, string>)[input] || input;
    if (isEnglish && result === input && !params) {
        for (const item of patterns) {
            const match = item.pattern.exec(input);
            if (!match) continue;
            result = english[item.key]!;
            params = Object.fromEntries(
                item.indexes.map((index, i) => [index, match[i + 1]]),
            );
            break;
        }
    }
    if (params)
        result = result.replace(/\{([^}]+)\}/g, (_all, key) => {
            const value = String(params?.[key] ?? "");
            return value;
        });
    return result;
}
/** Allows platform menus/controllers to extend translations without changing UI ownership. */
export function registerEnglish(messages: Record<string, string>) {
    Object.assign(english, messages);
    patterns = buildPatterns();
}
export const messages = { "zh-CN": zh, en };
