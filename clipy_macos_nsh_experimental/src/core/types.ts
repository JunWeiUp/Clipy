export type Page =
    | "history"
    | "snippets"
    | "devices"
    | "notifications"
    | "settings"
    | "words"
    | "tools"
    | "capture"
    | "recording"
    | "video"
    | "onboarding"
    | "relay";
export type HistoryType = "text" | "richText" | "image" | "file" | "pdf";
export interface HistoryEntry {
    id: string;
    type: HistoryType;
    content: string;
    title: string;
    sourceApp: string;
    sourceBundleId?: string;
    sourceIconPath?: string;
    date: number;
    isPinned: boolean;
    mediaPath?: string;
    files?: string[];
    mediaId?: string;
    ocrText?: string;
}
export interface Snippet {
    id: string;
    title: string;
    content: string;
    folderId: string;
    shortcut?: string;
}
export interface Folder {
    id: string;
    name: string;
    shortcut?: string;
}
export interface PhoneNotification {
    id: string;
    title: string;
    content: string;
    app: string;
    date: number;
    deviceId: string;
    clearable: boolean;
    packageName?: string;
    notificationKey?: string;
    groupKey?: string;
}
export interface Device {
    id: string;
    name: string;
    address: string;
    online: boolean;
    transport?: "lan" | "relay";
}
export interface Settings {
    language: string;
    theme: "system" | "light" | "dark";
    historyLimit: number;
    historyRetentionDays: number;
    excludedApps: string[];
    encryptHistory: boolean;
    ocrEnabled: boolean;
    syncEnabled: boolean;
    deviceName: string;
    port: number;
    relayEnabled: boolean;
    relayEndpoint: string;
    notificationsEnabled: boolean;
    notificationSound: boolean;
    keywords: string;
    blockedKeywords: string;
    lookupShortcut: string;
    searchShortcut: string;
    screenshotShortcut: string;
    launchAtLogin: boolean;
    captureMode: string;
    captureAction: string;
    autoSave: boolean;
    captureDirectory: string;
    fps: number;
    systemAudio: boolean;
    microphone: boolean;
    camera: boolean;
    [key: string]: unknown;
}
export interface WordRecord {
    id: string;
    text: string;
    definition: string;
    familiar: boolean;
    count: number;
    date: number;
}
export interface AppState {
    page: Page;
    query: string;
    history: HistoryEntry[];
    snippets: Snippet[];
    folders: Folder[];
    notifications: PhoneNotification[];
    settings: Settings;
    devices: Device[];
    selection: string | null;
    selectedFolder: string;
    message: string;
    busy: boolean;
    word: string;
    wordResult: unknown;
    words: WordRecord[];
    translation: string;
    password: string;
    passwordEntropy: number;
    undoAvailable: boolean;
    ready: boolean;
    hostAvailable: boolean;
    [key: string]: unknown;
}
export interface StorageAdapter {
    maxStateBytes?: number;
    getItem(key: string): Promise<string | null>;
    setItem(key: string, value: string): Promise<void>;
}
export interface HostAdapter {
    call<T = unknown>(name: string, payload?: unknown): Promise<T>;
}
export interface ModelOptions {
    storage: StorageAdapter;
    host: HostAdapter;
    now?: () => number;
}
