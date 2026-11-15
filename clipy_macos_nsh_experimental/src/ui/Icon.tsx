import { Canvas, Path2D } from "nsh";
const paths: Record<string, string> = {
    clipboard:
        "M9 4H6a2 2 0 0 0-2 2v14h16V6a2 2 0 0 0-2-2h-3 M9 2h6v5H9Z M8 12h8 M8 16h6",
    history: "M3 12a9 9 0 1 0 2-6 M3 3v6h6 M12 7v5l3 2",
    snippets: "M6 3h12v18H6Z M9 8h6 M9 12h6 M9 16h4",
    devices: "M2 4h15v12H2Z M7 20h5 M9 16v4 M19 9h4v12h-7v-3",
    notifications: "M5 17h14l-2-3V9a5 5 0 0 0-10 0v5Z M10 21h4",
    tools: "M5 4h4v4H5Z M15 4h4v4h-4Z M5 15h4v4H5Z M15 15h4v4h-4Z",
    settings:
        "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8 M12 2v3 M12 19v3 M2 12h3 M19 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2",
    capture: "M8 3H3v5 M16 3h5v5 M21 16v5h-5 M8 21H3v-5 M7 7h10v10H7Z",
    words: "M3 5h11 M8 2v3 M6 5c0 7 8 10 8 10 M12 5c0 7-7 11-9 11 M14 21l4-11l4 11 M15 18h6",
    password: "M8 11h8v10H4V11Z M7 11V7a5 5 0 0 1 10 0v4 M10 15v3",
    search: "M10 3a7 7 0 1 0 0 14a7 7 0 1 0 0-14 M15 15l6 6",
};
export function Icon(p: { name: string; size?: number; color?: string }) {
    return (
        <Canvas
            style={{ width: p.size || 18, height: p.size || 18 }}
            draw={(c, s) => {
                c.save();
                c.scale(s.width / 24, s.height / 24);
                c.strokeStyle = p.color || "#7C7C82";
                c.lineWidth = 1.7;
                c.lineCap = "round";
                c.lineJoin = "round";
                c.stroke(new Path2D(paths[p.name] || paths.clipboard));
                c.restore();
            }}
        />
    );
}
