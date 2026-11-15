export interface Size {
    width: number;
    height: number;
}
export interface Position {
    x: number;
    y: number;
}
export function fitScale(view: Size, image: Size) {
    return Math.max(
        0.0001,
        Math.min(
            (view.width - 48) / image.width,
            (view.height - 48) / image.height,
            1,
        ),
    );
}
export function imageOffset(
    view: Size,
    image: Size,
    scale: number,
    pan: Position,
): Position {
    return {
        x: (view.width - image.width * scale) / 2 + pan.x,
        y: (view.height - image.height * scale) / 2 + pan.y,
    };
}
export function screenToImage(
    point: Position,
    view: Size,
    image: Size,
    scale: number,
    pan: Position,
): Position {
    const offset = imageOffset(view, image, scale, pan);
    return { x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale };
}
export function anchoredPan(
    point: Position,
    imagePoint: Position,
    view: Size,
    image: Size,
    scale: number,
): Position {
    return {
        x:
            point.x -
            imagePoint.x * scale -
            (view.width - image.width * scale) / 2,
        y:
            point.y -
            imagePoint.y * scale -
            (view.height - image.height * scale) / 2,
    };
}
