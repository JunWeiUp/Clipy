export type Tool =
    | "select"
    | "pen"
    | "line"
    | "arrow"
    | "rectangle"
    | "ellipse"
    | "text"
    | "number"
    | "highlighter"
    | "mosaic"
    | "blur"
    | "solid"
    | "erase"
    | "magnifier"
    | "measure"
    | "picker"
    | "spotlight"
    | "stamp";
export interface Point {
    x: number;
    y: number;
    pressure?: number;
}
export interface Annotation {
    id: string;
    tool: Tool;
    points: Point[];
    color: string;
    width: number;
    opacity: number;
    text?: string;
    fontSize?: number;
    fontFamily?: string;
    imagePath?:string; imageRotation?:number; textBox?:{width:number;height:number};
    number?: number;
    filled?: boolean;
    arrowStyle?: string;
    bold?: boolean;
    italic?: boolean;
    underline?: boolean;
    strike?: boolean;
    align?: string;
    background?: string;
    lineStyle?:string;fillMode?:string;cornerRadius?:number;outline?:boolean;arrowFlip?:boolean;numberFormat?:string;numberStart?:number;magnifierZoom?:number;spotlightOpacity?:number;measureUnit?:string;imageScale?:number;
}
export interface Scene {
    imagePath: string;
    width: number;
    height: number;
    annotations: Annotation[];
}
export const TOOLS: { id: Tool; label: string; icon: string }[] = [
    { id: "select", label: "选择", icon: "↖" },
    { id: "pen", label: "画笔", icon: "✎" },
    { id: "line", label: "直线", icon: "╱" },
    { id: "arrow", label: "箭头", icon: "↗" },
    { id: "rectangle", label: "矩形", icon: "□" },
    { id: "ellipse", label: "椭圆", icon: "○" },
    { id: "text", label: "文字", icon: "T" },
    { id: "number", label: "编号", icon: "①" },
    { id: "highlighter", label: "荧光笔", icon: "▰" },
    { id: "mosaic", label: "马赛克", icon: "▦" },
    { id: "blur", label: "模糊", icon: "◌" },
    { id: "solid", label: "遮罩", icon: "■" },
    { id: "erase", label: "擦除", icon: "▱" },
    { id: "magnifier", label: "放大镜", icon: "⊕" },
    { id: "measure", label: "测距", icon: "↔" },
    { id: "picker", label: "取色", icon: "⌖" },
    { id: "spotlight", label: "聚光灯", icon: "◉" },
    { id: "stamp", label: "图章", icon: "★" },
];
export const COLORS = [
    "#FF3B30",
    "#FF9500",
    "#FFCC00",
    "#34C759",
    "#007AFF",
    "#AF52DE",
    "#FF2D55","#FFFFFF","#AAAAAA","#808080","#555555","#000000",
];
export const cloneAnnotation = (a: Annotation): Annotation => ({
    ...a,
    points: a.points.map((p) => ({ ...p })),
    ...(a.textBox?{textBox:{...a.textBox}}:{}),
});
export function bounds(a: Annotation) {
    if(a.textBox)return {x:a.points[0]?.x||0,y:a.points[0]?.y||0,width:a.textBox.width,height:a.textBox.height};
    const xs = a.points.map((p) => p.x),
        ys = a.points.map((p) => p.y);
    const x = Math.min(...xs),
        y = Math.min(...ys);
    return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
}
export function hitTest(a: Annotation, p: Point, tolerance = 8) {
    const b = bounds(a);
    if((a.tool==="stamp"&&a.imagePath)||a.textBox)return p.x>=b.x-tolerance&&p.x<=b.x+b.width+tolerance&&p.y>=b.y-tolerance&&p.y<=b.y+b.height+tolerance;
    if (a.tool === "text" || a.tool === "stamp")
        return (
            p.x >= b.x - tolerance &&
            p.x <=
                b.x +
                    (a.text?.length || 1) * (a.fontSize || 24) * 0.75 +
                    tolerance &&
            p.y >= b.y - tolerance &&
            p.y <= b.y + (a.fontSize || 24) * 1.5 + tolerance
        );
    if (a.tool === "number")
        return Math.hypot(p.x - b.x, p.y - b.y) < Math.max(16, a.width * 4);
    if (
        [
            "rectangle",
            "ellipse",
            "mosaic",
            "blur",
            "solid",
            "erase",
            "magnifier",
            "spotlight",
        ].includes(a.tool)
    )
        return (
            p.x >= b.x - tolerance &&
            p.x <= b.x + b.width + tolerance &&
            p.y >= b.y - tolerance &&
            p.y <= b.y + b.height + tolerance
        );
    for (let i = 1; i < a.points.length; i++) {
        const start = a.points[i - 1]!,
            end = a.points[i]!,
            dx = end.x - start.x,
            dy = end.y - start.y;
        const l = dx * dx + dy * dy;
        const t = l
            ? Math.max(
                  0,
                  Math.min(
                      1,
                      ((p.x - start.x) * dx + (p.y - start.y) * dy) / l,
                  ),
              )
            : 0;
        if (
            Math.hypot(p.x - start.x - t * dx, p.y - start.y - t * dy) <=
            Math.max(tolerance, a.width / 2)
        )
            return true;
    }
    return false;
}
export function moved(a: Annotation, dx: number, dy: number): Annotation {
    return {
        ...a,
        points: a.points.map((p) => ({ ...p, x: p.x + dx, y: p.y + dy })),
    };
}
export function arrowHead(a: Point, b: Point, width: number) {
    const angle = Math.atan2(b.y - a.y, b.x - a.x),
        size = Math.max(12, width * 4);
    return [
        {
            x: b.x - size * Math.cos(angle - 0.45),
            y: b.y - size * Math.sin(angle - 0.45),
        },
        b,
        {
            x: b.x - size * Math.cos(angle + 0.45),
            y: b.y - size * Math.sin(angle + 0.45),
        },
    ];
}
export function finiteScene(scene: Scene) {
    return (
        Number.isFinite(scene.width) &&
        Number.isFinite(scene.height) &&
        scene.width > 0 &&
        scene.height > 0 &&
        scene.width * scene.height <= 80_000_000 &&
        scene.annotations.length <= 500 &&
        scene.annotations.every(
            (a) =>
                a.points.length > 0 &&
                a.points.length <= 4096 &&
                a.points.every(
                    (p) =>
                        Number.isFinite(p.x) &&
                        Number.isFinite(p.y) &&
                        (p.pressure === undefined ||
                            (Number.isFinite(p.pressure) &&
                                p.pressure >= 0 &&
                                p.pressure <= 1)),
                ),
        )
    );
}
