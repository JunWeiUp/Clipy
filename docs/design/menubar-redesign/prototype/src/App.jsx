import { useEffect, useRef, useState } from "react";
import {
    ClipboardText,
    PushPin,
    GearSix,
    MagnifyingGlass,
    Camera,
    Translate,
    ArrowsLeftRight,
    Bell,
    DotsThree,
    FileText,
    TextAlignLeft,
    ImageSquare,
    CaretRight,
    CaretLeft,
    Copy,
    Check,
    X,
    Laptop,
    DeviceMobile,
    Folder,
    Key,
    BookOpen,
    VideoCamera,
    Selection,
    Monitor,
    Scan,
    ArrowSquareOut,
    Clock,
    Link,
    WarningCircle,
    ArrowClockwise,
    Sun,
    Moon,
    PaperPlaneTilt,
    Plus,
    Power,
    FunnelSimple,
    WifiHigh,
} from "@phosphor-icons/react";

const history = [
    {
        id: 1,
        type: "文字",
        title: "把想法留住，让工作继续。",
        source: "Notes",
        time: "4 分钟前",
        icon: FileText,
    },
    {
        id: 2,
        type: "文字",
        title: "developer.apple.com",
        source: "Safari",
        time: "6 分钟前",
        icon: Link,
    },
    {
        id: 3,
        type: "文字",
        title: "设计讨论：入口更清晰，操作更直接",
        source: "Mail",
        time: "9 分钟前",
        icon: TextAlignLeft,
    },
    {
        id: 4,
        type: "图片",
        title: "灵感参考.png",
        source: "预览",
        time: "11 分钟前",
        icon: ImageSquare,
        image: true,
    },
    {
        id: 5,
        type: "文件",
        title: "项目说明.pdf",
        source: "Finder",
        time: "14 分钟前",
        icon: FileText,
    },
    {
        id: 6,
        type: "文字",
        title: "hello@example.com",
        source: "Mail",
        time: "16 分钟前",
        icon: TextAlignLeft,
    },
    {
        id: 7,
        type: "文字",
        title: "少一点切换，多一点专注。",
        source: "Notes",
        time: "28 分钟前",
        icon: FileText,
    },
    {
        id: 8,
        type: "文件",
        title: "设计草稿.fig",
        source: "Finder",
        time: "35 分钟前",
        icon: FileText,
    },
    {
        id: 9,
        type: "文字",
        title: "https://swift.org/documentation/",
        source: "Safari",
        time: "1 小时前",
        icon: Link,
    },
];
const snippets = [
    {
        id: "s1",
        title: "邮件落款",
        text: "谢谢，祝工作顺利！\nAlex · Product Design",
        folder: "工作",
        icon: FileText,
    },
    {
        id: "s2",
        title: "会议邀请",
        text: "你好，想和你约一次简短的设计讨论。方便时请告诉我你的时间。",
        folder: "工作",
        icon: FileText,
    },
    {
        id: "s3",
        title: "项目地址",
        text: "https://example.com/project",
        folder: "工作",
        icon: Link,
    },
    {
        id: "s4",
        title: "收件信息",
        text: "Alex · 示例工作室",
        folder: "个人",
        icon: FileText,
    },
];
const tools = [
    {
        id: "capture",
        title: "截图与录屏",
        desc: "区域、窗口、长截图与视频",
        icon: Camera,
        group: "创作",
    },
    {
        id: "word",
        title: "查词",
        desc: "词义、发音与中英翻译",
        icon: Translate,
        group: "语言",
    },
    {
        id: "book",
        title: "单词本",
        desc: "复习收藏的单词",
        icon: BookOpen,
        group: "语言",
    },
    {
        id: "smart",
        title: "智能切换",
        desc: "打开应用、搜索与翻译",
        icon: ArrowsLeftRight,
        group: "效率",
    },
    {
        id: "password",
        title: "生成密码",
        desc: "选择长度与字符类型",
        icon: Key,
        group: "效率",
    },
];
const icons = ["Tailscale", "Dropbox", "Docker"];
const viewTitles = {
    devices: "局域网设备",
    notifications: "通知",
    settings: "偏好设置",
    history: "全部历史",
};
const captureModes = [
    { name: "区域截图", icon: Selection, detail: "拖动选择需要截取的区域" },
    { name: "窗口截图", icon: Monitor, detail: "选择一个应用窗口" },
    { name: "全屏截图", icon: ImageSquare, detail: "截取当前屏幕" },
    { name: "滚动长截图", icon: Scan, detail: "连续捕获可滚动的内容" },
    { name: "录制视频 / GIF", icon: VideoCamera, detail: "选择区域后开始录制" },
];

function IconButton({
    label,
    icon: Icon,
    onClick,
    active = false,
    children,
    ...props
}) {
    return (
        <button
            className={"icon-button " + (active ? "active" : "")}
            aria-label={label}
            title={label}
            onClick={onClick}
            {...props}
        >
            <Icon size={21} />
            {children}
        </button>
    );
}
function Empty({ title, description, icon: Icon = MagnifyingGlass }) {
    return (
        <div className="empty">
            <Icon size={32} weight="light" />
            <strong>{title}</strong>
            <p>{description}</p>
        </div>
    );
}
function Switch({ label, checked, onChange }) {
    return (
        <button
            role="switch"
            aria-checked={checked}
            aria-label={label}
            className={"switch " + (checked ? "on" : "")}
            onClick={() => onChange(!checked)}
        >
            <span />
        </button>
    );
}

export function App() {
    const [theme, setTheme] = useState("light");
    const [visible, setVisible] = useState(true);
    const [pinned, setPinned] = useState(false);
    const [tab, setTab] = useState("剪贴板");
    const [view, setView] = useState("home");
    const [query, setQuery] = useState("");
    const [filter, setFilter] = useState("全部");
    const [folder, setFolder] = useState("全部");
    const [selected, setSelected] = useState(1);
    const [toast, setToast] = useState("");
    const [copied, setCopied] = useState(null);
    const [overflow, setOverflow] = useState("normal");
    const [hiddenEnabled, setHiddenEnabled] = useState(true);
    const [more, setMore] = useState(false);
    const [dialog, setDialog] = useState(null);
    const [tool, setTool] = useState(null);
    const [notifications, setNotifications] = useState([
        {
            id: 1,
            app: "日历",
            title: "设计评审即将开始",
            body: "10 分钟后 · 会议室 A",
            time: "刚刚",
        },
        {
            id: 2,
            app: "消息",
            title: "Alex",
            body: "新版设计稿已经整理好了，方便时看一下。",
            time: "3 分钟前",
        },
        {
            id: 3,
            app: "文件传输",
            title: "文件接收完成",
            body: "项目说明.pdf · 来自 Pixel 9",
            time: "8 分钟前",
        },
    ]);
    const [sync, setSync] = useState(true);
    const [toolInput, setToolInput] = useState("");
    const [wordResult, setWordResult] = useState(false);
    const [length, setLength] = useState(16);
    const [password, setPassword] = useState("");
    const [previewEmpty, setPreviewEmpty] = useState(false);
    const searchRef = useRef(null),
        panelRef = useRef(null),
        dialogRef = useRef(null),
        dialogTrigger = useRef(null),
        toastTimer = useRef(null);
    const notify = (message) => {
        clearTimeout(toastTimer.current);
        setToast(message);
        toastTimer.current = setTimeout(() => setToast(""), 2400);
    };
    useEffect(() => () => clearTimeout(toastTimer.current), []);
    const go = (next) => {
        setView(next);
        setQuery("");
        setMore(false);
        setSelected(null);
        setToolInput("");
        setWordResult(false);
    };
    const openTool = (item) => {
        setTool(item);
        go("tool");
    };
    const copy = (item) => {
        setCopied(item.id);
        setSelected(item.id);
        notify("已复制 · 演示反馈");
    };
    const q = query.trim().toLowerCase();
    const match = (item) =>
        `${item.title} ${item.text || ""} ${item.source || ""} ${item.desc || ""}`
            .toLowerCase()
            .includes(q);
    const rows = previewEmpty
        ? []
        : history.filter(
              (item) =>
                  ((q && view === "home") ||
                      filter === "全部" ||
                      item.type === filter) &&
                  match(item),
          );
    const shownRows = view === "history" || q ? rows : rows.slice(0, 6);
    const shownSnippets = previewEmpty
        ? []
        : snippets.filter(
              (item) =>
                  (q || folder === "全部" || folder === item.folder) &&
                  match(item),
          );
    const shownTools = tools.filter(match);
    const globalSearch = q && view === "home";
    const mainHistory =
        (view === "home" && tab === "剪贴板") || view === "history";
    const selectable = globalSearch
        ? [...shownRows, ...shownSnippets, ...shownTools]
        : mainHistory
          ? shownRows
          : tab === "片段" && view === "home"
            ? shownSnippets
            : [];
    const doItem = (item) =>
        tools.some((t) => t.id === item.id) ? openTool(item) : copy(item);
    useEffect(() => {
        if (dialog) {
            dialogTrigger.current = document.activeElement;
            dialogRef.current?.focus();
        } else if (dialogTrigger.current) {
            dialogTrigger.current?.focus();
            dialogTrigger.current = null;
        }
    }, [dialog]);
    useEffect(() => {
        const handler = (e) => {
            if (e.isComposing || e.keyCode === 229) return;
            if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") {
                e.preventDefault();
                setVisible(true);
                requestAnimationFrame(() => searchRef.current?.focus());
                return;
            }
            if (e.key === "Escape") {
                e.preventDefault();
                if (dialog) {
                    setDialog(null);
                } else if (more) {
                    setMore(false);
                } else if (query) {
                    setQuery("");
                } else if (view !== "home") {
                    go("home");
                } else {
                    setVisible(false);
                }
                return;
            }
            if (!visible || dialog) return;
            if (
                (e.metaKey || e.ctrlKey) &&
                /^[1-6]$/.test(e.key) &&
                mainHistory
            ) {
                const item = shownRows[Number(e.key) - 1];
                if (item) {
                    e.preventDefault();
                    copy(item);
                }
                return;
            }
            const inField = ["INPUT", "TEXTAREA", "SELECT"].includes(
                e.target.tagName,
            );
            if (
                (!inField || e.target === searchRef.current) &&
                ["ArrowDown", "ArrowUp"].includes(e.key) &&
                selectable.length
            ) {
                e.preventDefault();
                const index = selectable.findIndex((x) => x.id === selected);
                const next =
                    index === -1
                        ? e.key === "ArrowDown"
                            ? 0
                            : selectable.length - 1
                        : (index +
                              (e.key === "ArrowDown" ? 1 : -1) +
                              selectable.length) %
                          selectable.length;
                setSelected(selectable[next].id);
                const target = document.getElementById(
                    "row-" + selectable[next].id,
                );
                target?.scrollIntoView({ block: "nearest" });
                if (e.target !== searchRef.current) target?.focus();
                return;
            }
            if (
                e.key === "Enter" &&
                e.target === searchRef.current &&
                selectable.length
            ) {
                e.preventDefault();
                doItem(
                    selectable.find((x) => x.id === selected) || selectable[0],
                );
            }
        };
        window.addEventListener("keydown", handler);
        return () => window.removeEventListener("keydown", handler);
    });
    function showDialog(data) {
        setDialog(data);
        setMore(false);
    }
    function renderRow(item, isSnippet = false) {
        const Icon = item.icon;
        return (
            <button
                id={"row-" + item.id}
                key={item.id}
                className={
                    "content-row " + (selected === item.id ? "selected" : "")
                }
                onClick={() => copy(item)}
                onFocus={() => setSelected(item.id)}
                title={isSnippet ? item.text : item.title}
            >
                <Icon size={22} className="row-icon" />
                {item.image && (
                    <img
                        className="thumb"
                        src="/assets/landscape.png"
                        alt="山峰与湖面"
                    />
                )}
                <span className="row-copy">
                    <span className="row-title">{item.title}</span>
                    {isSnippet && <small>{item.text}</small>}
                </span>
                <span className="row-meta">
                    {isSnippet ? item.folder : `${item.source} · ${item.time}`}
                </span>
                <span className="copy-affordance">
                    {copied === item.id ? <Check size={15} /> : null}
                    {copied === item.id ? "已复制" : "复制"}
                </span>
            </button>
        );
    }
    const toolLaunch = (title) =>
        showDialog({
            kind: "launch",
            title,
            description:
                "正式应用中，此操作会收起当前面板，打开对应的功能窗口。",
            icon: ArrowSquareOut,
        });
    return (
        <main
            className={"desktop " + theme}
            onMouseDown={(e) => {
                if (e.target === e.currentTarget && !pinned && !dialog) {
                    setVisible(false);
                    setMore(false);
                }
            }}
        >
            <aside className="review-tools" aria-label="原型预览控制">
                <div className="review-brand">
                    <ClipboardText size={23} /> CLIPY <span>UI 预览</span>
                </div>
                <h1>
                    常用的，
                    <br />
                    触手可及。
                </h1>
                <p>
                    剪贴板是主角。
                    <br />
                    图标与工具，各在其位。
                </p>
                <div className="review-controls">
                    <label>
                        外观
                        <button
                            className="appearance"
                            onClick={() =>
                                setTheme(theme === "light" ? "dark" : "light")
                            }
                        >
                            {theme === "light" ? (
                                <Sun size={16} />
                            ) : (
                                <Moon size={16} />
                            )}{" "}
                            {theme === "light" ? "浅色" : "深色"}
                        </button>
                    </label>
                    <label>
                        图标状态
                        <select
                            aria-label="图标状态"
                            value={overflow}
                            onChange={(e) => {
                                setOverflow(e.target.value);
                                setHiddenEnabled(true);
                                setVisible(true);
                            }}
                        >
                            <option value="normal">检测到隐藏图标</option>
                            <option value="empty">没有隐藏图标</option>
                            <option value="permission">缺少辅助功能权限</option>
                            <option value="unsupported">
                                已连接外部显示器
                            </option>
                        </select>
                    </label>
                    <label>
                        内容状态
                        <select
                            aria-label="内容状态"
                            value={previewEmpty ? "empty" : "normal"}
                            onChange={(e) => {
                                setPreviewEmpty(e.target.value === "empty");
                                setVisible(true);
                            }}
                        >
                            <option value="normal">示例内容</option>
                            <option value="empty">空状态</option>
                        </select>
                    </label>
                </div>
                <p className="review-note">
                    可点击、搜索和切换页面。
                    <br />
                    内容均为示例，不操作真实应用。
                </p>
            </aside>
            <div className="desktop-bar">
                <span className="bar-app">Clipy</span>
                <div className="bar-right">
                    <button
                        className={
                            "menubar-trigger " + (visible ? "pressed" : "")
                        }
                        aria-label="打开或关闭 Clipy"
                        onClick={() => {
                            setVisible(!visible);
                            setMore(false);
                        }}
                    >
                        <ClipboardText size={19} />
                    </button>
                    <WifiHigh size={18} />
                    <MagnifyingGlass size={17} />
                </div>
            </div>
            {!visible && (
                <button className="reopen" onClick={() => setVisible(true)}>
                    <ClipboardText size={24} /> 打开 Clipy{" "}
                    <span>也可点击顶部图标</span>
                </button>
            )}
            {visible && (
                <section
                    className="panel"
                    aria-label="Clipy 控制面板"
                    ref={panelRef}
                >
                    <header className="panel-header">
                        <div className="brand">
                            <ClipboardText size={29} weight="duotone" />
                            <strong>Clipy</strong>
                        </div>
                        <div className="header-actions">
                            <IconButton
                                label={pinned ? "取消固定" : "固定面板"}
                                icon={PushPin}
                                active={pinned}
                                aria-pressed={pinned}
                                onClick={() => {
                                    setPinned(!pinned);
                                    notify(
                                        pinned
                                            ? "已取消固定"
                                            : "已固定，点击外部保持打开",
                                    );
                                }}
                            />
                            <IconButton
                                label="偏好设置"
                                icon={GearSix}
                                active={view === "settings"}
                                onClick={() =>
                                    go(
                                        view === "settings"
                                            ? "home"
                                            : "settings",
                                    )
                                }
                            />
                        </div>
                    </header>
                    <div className="search">
                        <MagnifyingGlass size={21} />
                        <input
                            ref={searchRef}
                            aria-label="搜索剪贴板与功能"
                            placeholder="搜索剪贴板与功能"
                            value={query}
                            onChange={(e) => {
                                setQuery(e.target.value);
                                setSelected(null);
                                if (view !== "home" && view !== "history")
                                    setView("home");
                            }}
                        />
                        {query ? (
                            <IconButton
                                label="清除搜索"
                                icon={X}
                                onClick={() => {
                                    setQuery("");
                                    searchRef.current?.focus();
                                }}
                            />
                        ) : (
                            <kbd>⌘ F</kbd>
                        )}
                    </div>
                    <section className="overflow" aria-label="隐藏的菜单栏图标">
                        <div className="section-label">
                            隐藏的菜单栏图标
                            {overflow === "normal" && hiddenEnabled ? (
                                <span className="hover-hint">
                                    点击打开原菜单
                                </span>
                            ) : null}
                        </div>
                        {!hiddenEnabled ? (
                            <div className="inline-state">
                                <span>已关闭图标收纳</span>
                                <button onClick={() => setHiddenEnabled(true)}>
                                    开启
                                </button>
                            </div>
                        ) : overflow === "normal" ? (
                            <div className="app-strip">
                                {icons.map((name) => (
                                    <button
                                        key={name}
                                        onClick={() =>
                                            showDialog({
                                                kind: "app",
                                                title: name,
                                                description:
                                                    "原应用菜单 · 交互示意",
                                            })
                                        }
                                        title={
                                            "打开 " + name + " 的菜单（演示）"
                                        }
                                    >
                                        <img
                                            src={
                                                "/assets/" +
                                                name.toLowerCase() +
                                                ".png"
                                            }
                                            alt=""
                                        />
                                        <span>{name}</span>
                                    </button>
                                ))}
                            </div>
                        ) : (
                            <div className="inline-state">
                                <span>
                                    {overflow === "empty" ? (
                                        <Check size={16} />
                                    ) : (
                                        <WarningCircle size={16} />
                                    )}{" "}
                                    {overflow === "empty"
                                        ? "所有图标均可见"
                                        : overflow === "permission"
                                          ? "需要辅助功能权限"
                                          : "外部显示器连接期间暂停"}
                                </span>
                                {overflow === "permission" && (
                                    <button onClick={() => go("settings")}>
                                        去设置
                                    </button>
                                )}
                                {overflow === "empty" && (
                                    <IconButton
                                        label="重新检测"
                                        icon={ArrowClockwise}
                                        onClick={() =>
                                            notify("已刷新，当前没有隐藏图标")
                                        }
                                    />
                                )}
                            </div>
                        )}
                    </section>
                    <nav className="tabs" role="tablist" aria-label="内容分类">
                        {["剪贴板", "片段", "工具"].map((name) => (
                            <button
                                role="tab"
                                aria-selected={view === "home" && tab === name}
                                id={"tab-" + name}
                                aria-controls="content"
                                key={name}
                                onClick={() => {
                                    setTab(name);
                                    go("home");
                                    setFilter("全部");
                                }}
                            >
                                {name}
                            </button>
                        ))}
                    </nav>
                    <div
                        className="content"
                        id="content"
                        role="region"
                        aria-label={
                            view === "home"
                                ? tab
                                : viewTitles[view] || tool?.title
                        }
                    >
                        {view !== "home" && (
                            <div className="subhead">
                                <button
                                    className="back"
                                    onClick={() => go("home")}
                                >
                                    <CaretLeft size={17} /> 返回
                                </button>
                                <strong>
                                    {view === "tool"
                                        ? tool?.title
                                        : viewTitles[view]}
                                </strong>
                                <span />
                            </div>
                        )}
                        {globalSearch ? (
                            <div className="scroller search-results">
                                {!selectable.length ? (
                                    <Empty
                                        title="没有找到匹配内容"
                                        description="试试更短的关键词，或搜索“截图”“查词”。"
                                    />
                                ) : (
                                    <>
                                        {shownRows.length > 0 && (
                                            <>
                                                <div className="list-label">
                                                    剪贴板
                                                </div>
                                                {shownRows.map((x) =>
                                                    renderRow(x),
                                                )}
                                            </>
                                        )}
                                        {shownSnippets.length > 0 && (
                                            <>
                                                <div className="list-label">
                                                    片段
                                                </div>
                                                {shownSnippets.map((x) =>
                                                    renderRow(x, true),
                                                )}
                                            </>
                                        )}
                                        {shownTools.length > 0 && (
                                            <>
                                                <div className="list-label">
                                                    工具
                                                </div>
                                                {shownTools.map((item) => (
                                                    <button
                                                        className={
                                                            "tool-row " +
                                                            (selected ===
                                                            item.id
                                                                ? "selected"
                                                                : "")
                                                        }
                                                        key={item.id}
                                                        id={"row-" + item.id}
                                                        onClick={() =>
                                                            openTool(item)
                                                        }
                                                    >
                                                        <item.icon size={24} />
                                                        <span>
                                                            <strong>
                                                                {item.title}
                                                            </strong>
                                                            <small>
                                                                {item.desc}
                                                            </small>
                                                        </span>
                                                        <CaretRight size={16} />
                                                    </button>
                                                ))}
                                            </>
                                        )}
                                    </>
                                )}
                            </div>
                        ) : mainHistory ? (
                            <>
                                <div className="filters" aria-label="历史类型">
                                    {["全部", "文字", "图片", "文件"].map(
                                        (name) => (
                                            <button
                                                key={name}
                                                aria-pressed={filter === name}
                                                className={
                                                    filter === name
                                                        ? "chosen"
                                                        : ""
                                                }
                                                onClick={() => {
                                                    setFilter(name);
                                                    setSelected(null);
                                                }}
                                            >
                                                {name}
                                            </button>
                                        ),
                                    )}
                                </div>
                                <div className="scroller history-list">
                                    {shownRows.length ? (
                                        shownRows.map((x) => renderRow(x))
                                    ) : (
                                        <Empty
                                            title={
                                                query
                                                    ? "没有找到匹配内容"
                                                    : "这里还没有内容"
                                            }
                                            description={
                                                query
                                                    ? "换一个关键词试试。"
                                                    : "复制的内容会出现在这里，随时取用。"
                                            }
                                            icon={ClipboardText}
                                        />
                                    )}
                                </div>
                                {view === "home" && (
                                    <button
                                        className="all-history"
                                        onClick={() => go("history")}
                                    >
                                        查看全部历史 <CaretRight size={15} />
                                    </button>
                                )}
                            </>
                        ) : view === "home" && tab === "片段" ? (
                            <>
                                <div
                                    className="filters"
                                    aria-label="片段文件夹"
                                >
                                    {["全部", "工作", "个人"].map((name) => (
                                        <button
                                            key={name}
                                            aria-pressed={folder === name}
                                            className={
                                                folder === name ? "chosen" : ""
                                            }
                                            onClick={() => setFolder(name)}
                                        >
                                            {name !== "全部" && (
                                                <Folder size={14} />
                                            )}{" "}
                                            {name}
                                        </button>
                                    ))}
                                </div>
                                <div className="scroller">
                                    {shownSnippets.length ? (
                                        shownSnippets.map((x) =>
                                            renderRow(x, true),
                                        )
                                    ) : (
                                        <Empty
                                            title="还没有常用片段"
                                            description="把常用回复和固定文本保存在这里。"
                                            icon={Folder}
                                        />
                                    )}
                                </div>
                                <button
                                    className="all-history"
                                    onClick={() => toolLaunch("片段编辑器")}
                                >
                                    管理片段 <ArrowSquareOut size={15} />
                                </button>
                            </>
                        ) : view === "home" && tab === "工具" ? (
                            <div className="scroller tools-list">
                                {tools.map((item) => (
                                    <button
                                        className="tool-row"
                                        key={item.id}
                                        onClick={() => openTool(item)}
                                    >
                                        <item.icon size={24} />
                                        <span>
                                            <strong>{item.title}</strong>
                                            <small>{item.desc}</small>
                                        </span>
                                        <CaretRight size={16} />
                                    </button>
                                ))}
                            </div>
                        ) : view === "devices" ? (
                            <div className="scroller detail-body">
                                <div className="section-description">
                                    同一局域网内，内容随手传递。
                                </div>
                                {[
                                    {
                                        name: "Pixel 9",
                                        detail: "Android · 已连接",
                                        icon: DeviceMobile,
                                    },
                                    {
                                        name: "MacBook Air",
                                        detail: "macOS · 已连接",
                                        icon: Laptop,
                                    },
                                ].map((d) => (
                                    <div className="device-row" key={d.name}>
                                        <d.icon size={30} />
                                        <span>
                                            <strong>{d.name}</strong>
                                            <small>
                                                <i className="status-dot" />
                                                {d.detail}
                                            </small>
                                        </span>
                                        <button
                                            className="small-button"
                                            onClick={() =>
                                                showDialog({
                                                    kind: "send",
                                                    title: "发送给 " + d.name,
                                                    description:
                                                        "选择一个示例文件，查看发送反馈。",
                                                })
                                            }
                                        >
                                            发送文件
                                        </button>
                                    </div>
                                ))}
                                <div className="setting-row">
                                    <div>
                                        <strong>自动同步剪贴板</strong>
                                        <small>在已配对设备间同步新内容</small>
                                    </div>
                                    <Switch
                                        label="自动同步剪贴板"
                                        checked={sync}
                                        onChange={setSync}
                                    />
                                </div>
                                <button
                                    className="text-button"
                                    onClick={() =>
                                        showDialog({
                                            kind: "connect",
                                            title: "添加设备",
                                            description:
                                                "输入设备的局域网 IP 地址。",
                                        })
                                    }
                                >
                                    <Plus size={16} /> 手动添加设备
                                </button>
                            </div>
                        ) : view === "notifications" ? (
                            <div className="scroller detail-body">
                                {notifications.length ? (
                                    <>
                                        <div className="notifications-header">
                                            <span>
                                                {notifications.length} 条未读
                                            </span>
                                            <button
                                                onClick={() => {
                                                    setNotifications([]);
                                                    notify("已全部标为已读");
                                                }}
                                            >
                                                全部已读
                                            </button>
                                        </div>
                                        {notifications.map((n) => (
                                            <button
                                                className="notification"
                                                key={n.id}
                                                onClick={() =>
                                                    showDialog({
                                                        kind: "notification",
                                                        title: n.title,
                                                        description: n.body,
                                                    })
                                                }
                                            >
                                                <div>
                                                    <strong>{n.app}</strong>
                                                    <small>{n.time}</small>
                                                </div>
                                                <b>{n.title}</b>
                                                <p>{n.body}</p>
                                            </button>
                                        ))}
                                    </>
                                ) : (
                                    <Empty
                                        title="通知已看完"
                                        description="新的同步通知会出现在这里。"
                                        icon={Bell}
                                    />
                                )}
                            </div>
                        ) : view === "settings" ? (
                            <div className="scroller detail-body">
                                <div className="setting-row">
                                    <div>
                                        <strong>收纳隐藏的菜单栏图标</strong>
                                        <small>在单个内置屏幕上自动发现</small>
                                    </div>
                                    <Switch
                                        label="收纳隐藏的菜单栏图标"
                                        checked={hiddenEnabled}
                                        onChange={setHiddenEnabled}
                                    />
                                </div>
                                <div className="setting-row">
                                    <div>
                                        <strong>固定控制面板</strong>
                                        <small>点击面板外部时保持打开</small>
                                    </div>
                                    <Switch
                                        label="固定控制面板"
                                        checked={pinned}
                                        onChange={setPinned}
                                    />
                                </div>
                                <div className="setting-row">
                                    <div>
                                        <strong>外观</strong>
                                        <small>适配浅色与深色界面</small>
                                    </div>
                                    <select
                                        aria-label="面板外观"
                                        value={theme}
                                        onChange={(e) =>
                                            setTheme(e.target.value)
                                        }
                                    >
                                        <option value="light">浅色</option>
                                        <option value="dark">深色</option>
                                    </select>
                                </div>
                                <div className="permission-info">
                                    <WarningCircle size={20} />
                                    <div>
                                        <strong>辅助功能权限</strong>
                                        <p>
                                            用于识别菜单栏图标并打开原应用菜单。
                                        </p>
                                        <button
                                            className="text-button"
                                            onClick={() =>
                                                showDialog({
                                                    kind: "permission",
                                                    title: "辅助功能权限",
                                                    description:
                                                        "正式应用会打开“系统设置 → 隐私与安全性 → 辅助功能”。此原型不请求系统权限。",
                                                })
                                            }
                                        >
                                            查看授权入口{" "}
                                            <ArrowSquareOut size={14} />
                                        </button>
                                    </div>
                                </div>
                                <button
                                    className="all-history"
                                    onClick={() => toolLaunch("完整偏好设置")}
                                >
                                    打开完整偏好设置{" "}
                                    <ArrowSquareOut size={15} />
                                </button>
                            </div>
                        ) : view === "tool" ? (
                            <div className="scroller detail-body">
                                {tool.id === "capture" ? (
                                    captureModes.map((mode) => (
                                        <button
                                            className="tool-row"
                                            key={mode.name}
                                            onClick={() =>
                                                toolLaunch(mode.name)
                                            }
                                        >
                                            <mode.icon size={25} />
                                            <span>
                                                <strong>{mode.name}</strong>
                                                <small>{mode.detail}</small>
                                            </span>
                                            <CaretRight size={16} />
                                        </button>
                                    ))
                                ) : tool.id === "word" ? (
                                    <>
                                        <div className="section-description">
                                            输入英文单词或中英文句子。
                                        </div>
                                        <form
                                            className="word-form"
                                            onSubmit={(e) => {
                                                e.preventDefault();
                                                if (toolInput.trim())
                                                    setWordResult(true);
                                            }}
                                        >
                                            <input
                                                placeholder="试试输入 focus"
                                                aria-label="查词输入"
                                                value={toolInput}
                                                onChange={(e) => {
                                                    setToolInput(
                                                        e.target.value,
                                                    );
                                                    setWordResult(false);
                                                }}
                                            />
                                            <button
                                                className="primary"
                                                disabled={!toolInput.trim()}
                                            >
                                                查询
                                            </button>
                                        </form>
                                        {wordResult ? (
                                            <div className="word-result">
                                                <small>
                                                    示例结果 · 未连接在线词典
                                                </small>
                                                <h2>
                                                    {toolInput
                                                        .trim()
                                                        .toLowerCase() ===
                                                    "focus"
                                                        ? "focus"
                                                        : "focus · 示例词条"}
                                                </h2>
                                                <span>/ˈfoʊkəs/</span>
                                                <p>
                                                    n. 焦点；关注点
                                                    <br />
                                                    v. 专注；集中
                                                </p>
                                                <blockquote>
                                                    Focus on what matters.
                                                    <br />
                                                    <small>
                                                        专注于重要的事情。
                                                    </small>
                                                </blockquote>
                                                <button
                                                    className="text-button"
                                                    onClick={() =>
                                                        notify(
                                                            "已加入单词本 · 演示反馈",
                                                        )
                                                    }
                                                >
                                                    <BookOpen size={16} />{" "}
                                                    加入单词本
                                                </button>
                                            </div>
                                        ) : (
                                            <Empty
                                                title="每个词，都值得理解"
                                                description="在原型中输入任意内容可查看示例结果。"
                                                icon={Translate}
                                            />
                                        )}
                                    </>
                                ) : tool.id === "password" ? (
                                    <>
                                        <div className="section-description">
                                            这里仅展示生成流程，示例密码不能用于账户。
                                        </div>
                                        <label className="range-label">
                                            长度 <strong>{length} 位</strong>
                                            <input
                                                type="range"
                                                min="8"
                                                max="32"
                                                value={length}
                                                aria-label="密码长度"
                                                onChange={(e) =>
                                                    setLength(
                                                        Number(e.target.value),
                                                    )
                                                }
                                            />
                                        </label>
                                        <button
                                            className="primary"
                                            onClick={() =>
                                                setPassword(
                                                    "Demo-7x!R2q#K9m@P4w$L8b%N6c&T3z?".slice(
                                                        0,
                                                        length,
                                                    ),
                                                )
                                            }
                                        >
                                            生成示例密码
                                        </button>
                                        {password && (
                                            <div className="password-output">
                                                <code>{password}</code>
                                                <button
                                                    className="text-button"
                                                    onClick={() =>
                                                        notify(
                                                            "已复制示例密码 · 演示反馈",
                                                        )
                                                    }
                                                >
                                                    <Copy size={16} /> 复制
                                                </button>
                                            </div>
                                        )}
                                    </>
                                ) : tool.id === "book" ? (
                                    <>
                                        <div className="section-description">
                                            已收藏的单词 · 示例
                                        </div>
                                        {["focus", "clarity", "create"].map(
                                            (word) => (
                                                <button
                                                    className="tool-row"
                                                    key={word}
                                                    onClick={() => {
                                                        setTool(
                                                            tools.find(
                                                                (t) =>
                                                                    t.id ===
                                                                    "word",
                                                            ),
                                                        );
                                                        setToolInput(word);
                                                        setWordResult(true);
                                                    }}
                                                >
                                                    <BookOpen size={23} />
                                                    <span>
                                                        <strong>{word}</strong>
                                                        <small>
                                                            查看词义与例句
                                                        </small>
                                                    </span>
                                                    <CaretRight size={16} />
                                                </button>
                                            ),
                                        )}
                                    </>
                                ) : (
                                    <>
                                        <div className="section-description">
                                            描述你要做的事，或直接选择一个动作。
                                        </div>
                                        <input
                                            className="standalone-input"
                                            placeholder="例如：打开 Safari"
                                            aria-label="智能切换输入"
                                            value={toolInput}
                                            onChange={(e) =>
                                                setToolInput(e.target.value)
                                            }
                                        />
                                        <div className="smart-actions">
                                            {[
                                                "智能识别",
                                                "打开应用",
                                                "ZCode 新对话",
                                                "打开 Codex",
                                                "Google 搜索",
                                                "翻译",
                                            ].map((action) => (
                                                <button
                                                    key={action}
                                                    onClick={() =>
                                                        toolLaunch(action)
                                                    }
                                                >
                                                    {action}
                                                    <ArrowSquareOut size={15} />
                                                </button>
                                            ))}
                                        </div>
                                    </>
                                )}
                            </div>
                        ) : null}
                    </div>
                    <footer className="panel-footer">
                        <div className="quick-actions">
                            <button onClick={() => openTool(tools[0])}>
                                <Camera size={21} />
                                <span>截图</span>
                            </button>
                            <button onClick={() => openTool(tools[1])}>
                                <Translate size={21} />
                                <span>查词</span>
                            </button>
                            <button onClick={() => openTool(tools[3])}>
                                <ArrowsLeftRight size={21} />
                                <span>智能切换</span>
                            </button>
                        </div>
                        <div className="footer-utilities">
                            <button
                                className={
                                    "device-button " +
                                    (view === "devices" ? "active" : "")
                                }
                                onClick={() => go("devices")}
                            >
                                <i className="status-dot" />
                                <span>设备 2</span>
                            </button>
                            <IconButton
                                label="通知"
                                icon={Bell}
                                active={view === "notifications"}
                                onClick={() => go("notifications")}
                            >
                                {notifications.length > 0 && (
                                    <b className="badge">
                                        {notifications.length}
                                    </b>
                                )}
                            </IconButton>
                            <IconButton
                                label="更多操作"
                                icon={DotsThree}
                                aria-expanded={more}
                                onClick={() => setMore(!more)}
                            />
                        </div>
                        {more && (
                            <div className="more-menu" role="menu">
                                <button
                                    role="menuitem"
                                    onClick={() => go("settings")}
                                >
                                    <GearSix size={17} /> 偏好设置
                                </button>
                                <button
                                    role="menuitem"
                                    onClick={() => {
                                        setMore(false);
                                        notify("已刷新隐藏图标 · 演示反馈");
                                    }}
                                >
                                    <ArrowClockwise size={17} /> 刷新隐藏图标
                                </button>
                                <button
                                    role="menuitem"
                                    onClick={() => {
                                        setVisible(false);
                                        setMore(false);
                                    }}
                                >
                                    <Power size={17} /> 关闭面板
                                </button>
                            </div>
                        )}
                    </footer>
                    {toast && (
                        <div className="toast" role="status">
                            <Check size={16} />
                            {toast}
                        </div>
                    )}
                    {dialog && (
                        <div
                            className="dialog-backdrop"
                            onMouseDown={(e) => {
                                if (e.target === e.currentTarget)
                                    setDialog(null);
                            }}
                        >
                            <section
                                className="dialog"
                                role="dialog"
                                aria-modal="true"
                                aria-label={dialog.title}
                                tabIndex={-1}
                                ref={dialogRef}
                                onKeyDown={(e) => {
                                    if (e.key === "Tab") {
                                        const els = [
                                            ...e.currentTarget.querySelectorAll(
                                                "button:not(:disabled),input,select",
                                            ),
                                        ];
                                        const first = els[0],
                                            last = els.at(-1);
                                        if (
                                            e.shiftKey &&
                                            (document.activeElement === first ||
                                                document.activeElement ===
                                                    e.currentTarget)
                                        ) {
                                            e.preventDefault();
                                            last?.focus();
                                        } else if (
                                            !e.shiftKey &&
                                            document.activeElement === last
                                        ) {
                                            e.preventDefault();
                                            first?.focus();
                                        }
                                    }
                                }}
                            >
                                <div className="dialog-heading">
                                    <h2>{dialog.title}</h2>
                                    <IconButton
                                        label="关闭对话框"
                                        icon={X}
                                        onClick={() => setDialog(null)}
                                    />
                                </div>
                                <p>{dialog.description}</p>
                                {dialog.kind === "app" ? (
                                    <>
                                        <div className="app-demo">
                                            <img
                                                src={
                                                    "/assets/" +
                                                    dialog.title.toLowerCase() +
                                                    ".png"
                                                }
                                                alt=""
                                            />
                                            <span>
                                                <strong>{dialog.title}</strong>
                                                <small>
                                                    原型示意，不连接真实应用
                                                </small>
                                            </span>
                                        </div>
                                        <button
                                            className="dialog-option"
                                            onClick={() => {
                                                setDialog(null);
                                                notify(
                                                    "原应用菜单操作 · 演示反馈",
                                                );
                                            }}
                                        >
                                            查看状态 <CaretRight size={15} />
                                        </button>
                                        <button
                                            className="dialog-option"
                                            onClick={() => setDialog(null)}
                                        >
                                            关闭原菜单
                                        </button>
                                    </>
                                ) : dialog.kind === "send" ? (
                                    <>
                                        <div className="sample-file">
                                            <FileText size={25} />
                                            <span>
                                                项目说明.pdf
                                                <small>240 KB · 示例文件</small>
                                            </span>
                                        </div>
                                        <button
                                            className="primary wide"
                                            onClick={() => {
                                                setDialog(null);
                                                notify("文件已发送 · 演示反馈");
                                            }}
                                        >
                                            <PaperPlaneTilt size={17} />{" "}
                                            发送示例文件
                                        </button>
                                    </>
                                ) : dialog.kind === "connect" ? (
                                    <form
                                        onSubmit={(e) => {
                                            e.preventDefault();
                                            const value = new FormData(
                                                e.currentTarget,
                                            ).get("ip");
                                            if (
                                                !/^(\d{1,3}\.){3}\d{1,3}$/.test(
                                                    value,
                                                ) ||
                                                value
                                                    .split(".")
                                                    .some(
                                                        (x) => Number(x) > 255,
                                                    )
                                            ) {
                                                e.currentTarget.elements.ip.setCustomValidity(
                                                    "请输入有效的 IPv4 地址",
                                                );
                                                e.currentTarget.reportValidity();
                                                return;
                                            }
                                            setDialog(null);
                                            notify("已发起连接 · 演示反馈");
                                        }}
                                    >
                                        <input
                                            className="standalone-input"
                                            name="ip"
                                            aria-label="设备 IP 地址"
                                            placeholder="192.168.1.20"
                                            required
                                            onChange={(e) =>
                                                e.target.setCustomValidity("")
                                            }
                                        />
                                        <button className="primary wide">
                                            连接
                                        </button>
                                    </form>
                                ) : (
                                    <button
                                        className="primary wide"
                                        onClick={() => {
                                            setDialog(null);
                                            if (dialog.kind === "launch")
                                                notify(
                                                    "功能入口已确认 · 演示反馈",
                                                );
                                        }}
                                    >
                                        知道了
                                    </button>
                                )}
                            </section>
                        </div>
                    )}
                </section>
            )}
        </main>
    );
}
