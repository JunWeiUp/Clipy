import { test, expect } from "nsh/test";
import { bounds, hitTest, moved, arrowHead, finiteScene } from "./scene";
import type { Annotation } from "./scene";
const rectangle: Annotation = {
    id: "a",
    tool: "rectangle",
    points: [
        { x: 80, y: 70 },
        { x: 10, y: 20 },
    ],
    color: "#FF3B30",
    width: 3,
    opacity: 1,
};
test("dragging preserves negative-direction geometry", () => {
    expect(bounds(rectangle)).toEqual({ x: 10, y: 20, width: 70, height: 50 });
    expect(bounds(moved(rectangle, 20, -10))).toEqual({
        x: 30,
        y: 10,
        width: 70,
        height: 50,
    });
    expect(rectangle.points[0]!.x).toBe(80);
});
test("line hit testing uses segment distance rather than whole bounds", () => {
    const line = {
        ...rectangle,
        tool: "line" as const,
        points: [
            { x: 0, y: 0 },
            { x: 100, y: 100 },
        ],
    };
    expect(hitTest(line, { x: 50, y: 50 })).toBe(true);
    expect(hitTest(line, { x: 10, y: 90 })).toBe(false);
});
test("scene rejects excessive pixels, points and invalid coordinates", () => {
    expect(
        finiteScene({
            imagePath: "x",
            width: 1200,
            height: 800,
            annotations: [rectangle],
        }),
    ).toBe(true);
    expect(
        finiteScene({
            imagePath: "x",
            width: 100000,
            height: 100000,
            annotations: [],
        }),
    ).toBe(false);
    expect(
        finiteScene({
            imagePath: "x",
            width: 1,
            height: 1,
            annotations: [{ ...rectangle, points: [{ x: NaN, y: 0 }] }],
        }),
    ).toBe(false);
});
test("arrow head ends at actual pointer position", () => {
    const head = arrowHead({ x: 0, y: 0 }, { x: 100, y: 100 }, 3);
    expect(head[1]).toEqual({ x: 100, y: 100 });
    expect(head[0]!.x < 100).toBe(true);
});
