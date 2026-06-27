# Clipy macOS UI 规范（Rust ↔ Swift 对照）

## 验收方式

每个窗口在相同数据与语言下，与 Swift 版并排截图对比。基准截图存放于本目录。

## Design Tokens（与 `Sources/UI/DesignTokens.swift` 一致）

| Token | 值 |
|-------|-----|
| spacing xs/sm/md/lg | 8 / 12 / 16 / 20 pt |
| font caption/body/secondary/emptyState | 11 / 13 / 12 / 16 pt |
| row compact/standard/group | 28 / 36 / 40 pt |
| radius small/badge | 4 / 10 pt |
| toolbar height | 40 pt |

## 窗口尺寸

| 窗口 | Default | Min | Resizable |
|------|---------|-----|-----------|
| Search | 1200×800 | 800×680 | yes |
| Settings | 420×640 | 420×640 | no |
| SnippetEditor | 800×600 | 640×480 | yes |
| Logs | 800×500 | 480×320 | yes |
| Collector | 720×500 | 480×320 | yes |
| Notifications | 720×500 | 560×360 | yes |

## Search 布局树

```
AppListWindowLayout
├── AppWindowHeader (padding 12h/8v, spacing 8)
│   ├── Row1: SearchField + Regex Checkbox
│   ├── Row2: Segmented(5) + Source Menu(180) + Date Menu(120)
│   ├── Row3: Category chips (All/URL/Email/Code)
│   └── Row4: Load More (optional, right)
├── HSplitView (left min 420, right min 280)
│   ├── Table: Content | Location | Source | Time
│   └── HistoryPreviewView
└── StatusBar (right, caption 11pt secondary)
```

## 主题

- macOS 系统浅色语义色
- 禁止 GPUI Dark PopUp 风格
- 无 Tab 栏
