import {createSmartHighlight} from "./smart-highlight";
import {textBoxLayout} from "./textBox";
import {createCaptureTranslation} from "../app/capture-translation";
import {parseHex,hexToHSBA,hsbaToHex,recentColors,gradientEndpoints} from "./colors";
import {geometrySize,geometryMatrix,outputToSource,normalizedCrop,type Rect} from "./geometry";
import {ToolIcon} from "./ToolIcon";
import {Slider} from "nsh/base";
import { fitScale, imageOffset, screenToImage, anchoredPan } from "./viewport";
import { t as tr } from "../ui/locale";
import {
    Canvas,
    View,
    Scroll,
    Text,
    signal,
    Image,
    effect,
    keymap,
    cleanup,
    PanResponder,
    windowSize,
    colorScheme,
} from "nsh";
import { Menu } from "nsh/desktop";
import type { CanvasRenderingContext2D } from "nsh";
import { Btn, Field, Setting, cx } from "../ui/primitives";
import {
    TOOLS,
    COLORS,
    bounds,
    hitTest,
    moved,
    arrowHead,
    cloneAnnotation,
} from "./scene";
import type { Annotation, Tool, Point } from "./scene";

export function ImageEditor(p: {
    path: string;
    actions: any;
    defaults?: Record<string, unknown>;
    pressure?: number | { pressure: number; receivedAt?: number };
    initialSize?: { width: number; height: number };
    overlay?:{selectionRect:Rect;displayFrame:Rect;scale:number};
    pixelScale?:number;
    onClose: () => void;
}) {
    const originalPath=p.path,sourcePath=signal(originalPath);
    const annotations = signal<Annotation[]>([]),
        undo = signal<Annotation[][]>([]),
        redo = signal<Annotation[][]>([]);
    const previewPath = signal("");
    const basePreviewPath = signal("");
    const imageReady = signal(false);
    const cursorPoint = signal<Point | null>(null);
    const basePreviewSize = signal({ width: 0, height: 0 });
    let previewGeneration = 0;
    const defaults = p.defaults || {};
    const initial = (key: string, fallback: number) =>
        typeof defaults[key] === "number" && Number.isFinite(defaults[key])
            ? Number(defaults[key])
            : fallback;
    const effects = signal({
        beautify: !!defaults.beautify,
        padding: initial("beautifyPadding", 48),
        radius: initial("beautifyRadius", 12),
        shadow: initial("beautifyShadow", 20),
        brightness: initial("brightness", 0),
        contrast: initial("contrast", 1),
        saturation: initial("saturation", 1),
        sharpness: initial("sharpness", 0),beautifyMode:"rounded",preset:"None",invert:false,removeBackground:false,gradientMode:"gradient",gradientColors:["#738CF2","#B366D9"],gradientSolid:"#F5F5F5",gradientAngle:45,
    });
    const appearance=signal({lineStyle:"solid",fillMode:"stroke",cornerRadius:6,outline:false,arrowFlip:false,numberFormat:"decimal",magnifierZoom:2,spotlightOpacity:.55,measureUnit:"px",imageScale:p.pixelScale||p.overlay?.scale||1});
    const translationBackend=signal(defaults.captureTranslationBackend==="model"?"model":"system"),translationTarget=signal(tr("中文")),translationBusy=signal(false),translationOpen=signal(false);
    const textOnlyCensor=signal(false);
    const stampMode=signal("emoji"),stampSource=signal<{path:string;width:number;height:number;leaseId:string}|null>(null),stampSources=signal<string[]>([]),stampRotation=signal(0);
    const recent=signal<string[]>((Array.isArray(defaults.recentAnnotationColors)?defaults.recentAnnotationColors.filter((c):c is string=>typeof c==="string"):[]).slice(0,12));
    const nextNumber=signal(1),smoothing=signal("smooth"),smartHighlight=signal(!!defaults.smartHighlighter),inspectorOpen=signal(!p.overlay),censorMode=signal<Tool>("mosaic");
    const arrowStyle = signal("line"),
        textStyle = signal({
            bold: false,
            italic: false,
            underline: false,
            strike: false,
            align: "left",
            background: "",
        }),
        cropMode = signal(false),
        crop = signal<{
            x: number;
            y: number;
            width: number;
            height: number;
        } | null>(null),
        rotation = signal(0),
        flipH = signal(false),
        flipV = signal(false);
    const tool = signal<Tool>(
            defaults.rememberTool &&
                TOOLS.some((tool) => tool.id === defaults.lastAnnotationTool)
                ? (defaults.lastAnnotationTool as Tool)
                : "arrow",
        ),
        color = signal("#FF3B30"),
        width = signal(3),
        opacity = signal(1),
        text = signal(tr("文字")),
        fontSize = signal(24),
        fontFamily = signal<string | undefined>(undefined),
        selected = signal("");
    const activeTool = () =>
        annotations().find((a) => a.id === selected())?.tool || tool();
    const imageSize = signal(p.initialSize || { width: 1200, height: 800 }),
        viewport = signal({ width: 800, height: 500 }),
        status = signal(""),
        busy = signal(false);
    let previewRunning = false,
        previewAgain = false,
        disposed = false;
    let imageQueue: Promise<unknown> = Promise.resolve();
    function imageCall(name: string, payload: any) {
        const operation = imageQueue
            .catch(() => {})
            .then(() => {
                if (disposed) return undefined;
                return p.actions.invoke(name, payload);
            });
        imageQueue = operation.then(
            () => {},
            () => {},
        );
        return operation;
    }
    async function refreshPreview() {
        if (disposed) return;
        if (previewRunning) {
            previewAgain = true;
            return;
        }
        previewRunning = true;
        try {
            do {
                previewAgain = false;
                const generation = ++previewGeneration;
                const result = await imageCall("image.render", {
                    imagePath: sourcePath(),
                    ...imageSize(),
                    annotations: annotations(),
                    effects: effects(),
                    preview: true,
                    preservePreviewPaths: basePreviewPath()
                        ? [basePreviewPath()]
                        : [],
                });
                if (
                    !disposed &&
                    generation === previewGeneration &&
                    result?.path
                )
                    previewPath.set(result.path);
                else if (result?.path)
                    await p.actions.invoke("image.releaseOutput", {
                        path: result.path,
                    });
            } while (previewAgain && !disposed);
        } finally {
            previewRunning = false;
        }
    }
    cleanup(() => {
        disposed = true;
        previewGeneration++;
    });
    let draft: Annotation | null = null,
        dragBase: Annotation | null = null,
        start: Point | null = null,
        before: Annotation[] = [];
    const userScale = signal<number | null>(null),
        pan = signal({ x: 0, y: 0 }),
        grab = signal(false);
    const geometry=()=>({source:imageSize(),crop:cropMode()?null:crop(),rotation:rotation(),flipH:flipH(),flipV:flipV(),padding:effects().beautify?effects().padding:0,header:effects().beautify&&effects().beautifyMode==="window"?32:0});
    const sceneSize=()=>geometrySize(geometry());
    const fit = () => userScale() ?? fitScale(viewport(), sceneSize());
    const offset = () => imageOffset(viewport(), sceneSize(), fit(), pan());
    function zoomAt(point: Point, scale: number) {
        const imagePoint = screenToImage(
            point,
            viewport(),
            sceneSize(),
            fit(),
            pan(),
        );
        const next = Math.max(0.0001, Math.min(16, scale));
        userScale.set(next);
        pan.set(anchoredPan(point, imagePoint, viewport(), sceneSize(), next));
    }
    const centre = () => ({
        x: viewport().width / 2,
        y: viewport().height / 2,
    });
    function fitImage() {
        if(p.overlay&&sourcePath()!==originalPath){userScale.set(fitScale({width:Math.max(100,viewport().width-300),height:Math.max(100,viewport().height-140)},sceneSize()));pan.set({x:-150,y:-70});}
        else{userScale.set(null);pan.set({x:0,y:0});}
    }
    let panOrigin: Point | null = null,
        panStart = { x: 0, y: 0 };
    function alignOverlay(size:{width:number;height:number}) {
        if (!p.overlay) return;
        const frame=p.overlay.displayFrame,rect=p.overlay.selectionRect,scale=rect.width/size.width;
        viewport.set({width:frame.width,height:frame.height});
        userScale.set(scale);
        const outer=sceneSize(),origin=geometryMatrix(geometry());
        pan.set({x:rect.x-frame.x-origin.tx*scale-(frame.width-outer.width*scale)/2,y:rect.y-frame.y-origin.ty*scale-(frame.height-outer.height*scale)/2});
    }
    if(p.overlay&&p.initialSize)alignOverlay(p.initialSize);
    const toImage=(point:Point)=>{const output=screenToImage(point,viewport(),sceneSize(),fit(),pan()),source=outputToSource(output,geometry()),area=normalizedCrop(geometry());return {x:Math.max(area.x,Math.min(area.x+area.width,source.x)),y:Math.max(area.y,Math.min(area.y+area.height,source.y))};};
    type DocumentState={path:string;size:{width:number;height:number};annotations:Annotation[];effects:ReturnType<typeof effects>;crop:ReturnType<typeof crop>;cropMode:boolean;rotation:number;flipH:boolean;flipV:boolean;undo:Annotation[][];redo:Annotation[][]};
    const documentUndo=signal<DocumentState[]>([]),documentRedo=signal<DocumentState[]>([]),composeCount=signal(0);
    function documentSnapshot():DocumentState{return {path:sourcePath(),size:{...imageSize()},annotations:annotations().map(cloneAnnotation),effects:{...effects(),gradientColors:[...effects().gradientColors]},crop:crop()?{...crop()!}:null,cropMode:cropMode(),rotation:rotation(),flipH:flipH(),flipV:flipV(),undo:undo(),redo:redo()};}
    function resetPreview(){previewGeneration++;for(const path of new Set([previewPath(),basePreviewPath()].filter(Boolean)))void p.actions.invoke("image.releaseOutput",{path});previewPath.set("");basePreviewPath.set("");basePreviewSize.set({width:0,height:0});}
    function restoreDocument(state:DocumentState){translationGeneration++;translation?.dispose();translationBusy.set(false);resetPreview();imageSize.set(state.size);annotations.set(state.annotations.map(cloneAnnotation));effects.set({...state.effects,gradientColors:[...state.effects.gradientColors]});crop.set(state.crop);cropMode.set(state.cropMode);rotation.set(state.rotation);flipH.set(state.flipH);flipV.set(state.flipV);undo.set(state.undo);redo.set(state.redo);selected.set("");sourcePath.set(state.path);fitImage();status.set(tr("已恢复上一幅画布"));}
    const renderScene=()=>({imagePath:sourcePath(),...imageSize(),annotations:annotations(),effects:effects(),crop:crop(),rotation:rotation(),flipH:flipH(),flipV:flipV()});
    async function appendCapture(axis:"vertical"|"horizontal"){if(composeCount()>=4||smartBusy()||smartError())return;const old=documentSnapshot();busy.set(true);try{const result=await p.actions.invoke("editor.appendCapture",{scene:renderScene(),axis});if(disposed||result?.cancelled)return;if(!result?.path||!Number.isFinite(result.width)||!Number.isFinite(result.height))throw Error(tr("添加截图失败，当前画布已保留"));documentUndo.set([...documentUndo(),old]);documentRedo.set([]);composeCount.set(composeCount()+1);translationGeneration++;translation?.dispose();translationBusy.set(false);resetPreview();imageSize.set({width:result.width,height:result.height});annotations.set([]);undo.set([]);redo.set([]);selected.set("");crop.set(null);cropMode.set(false);rotation.set(0);flipH.set(false);flipV.set(false);effects.set({...effects(),beautify:false,brightness:0,contrast:1,saturation:1,sharpness:0,preset:"None",invert:false,removeBackground:false});sourcePath.set(result.path);fitImage();status.set(tr("截图已添加，可撤销恢复上一幅画布"));}catch(error){if(!disposed)status.set(String(error));}finally{if(!disposed)busy.set(false);}}
    const snapshot = () => annotations().map(cloneAnnotation);
    const remember = (old: Annotation[]) => {
        documentRedo.set([]);
        undo.set([...undo(), old].slice(-50));
        redo.set([]);
    };
    const undoAction = () => {
        if(busy())return;resetSmart();
        if (!undo().length){if(documentUndo().length){documentRedo.set([...documentRedo(),documentSnapshot()]);const old=documentUndo()[documentUndo().length-1]!;documentUndo.set(documentUndo().slice(0,-1));restoreDocument(old);}return;}
        redo.set([...redo(), snapshot()]);
        annotations.set(undo()[undo().length - 1]!);
        undo.set(undo().slice(0, -1));
        selected.set("");
        previewPath.set("");
        previewGeneration++;
        void refreshPreview();
    };
    const redoAction = () => {
        if(busy())return;resetSmart();
        if (!redo().length){if(documentRedo().length){documentUndo.set([...documentUndo(),documentSnapshot()]);const next=documentRedo()[documentRedo().length-1]!;documentRedo.set(documentRedo().slice(0,-1));restoreDocument(next);}return;}
        undo.set([...undo(), snapshot()]);
        annotations.set(redo()[redo().length - 1]!);
        redo.set(redo().slice(0, -1));
        selected.set("");
        previewPath.set("");
        previewGeneration++;
        void refreshPreview();
    };
    const updateSelected = (patch: Partial<Annotation>) => {
        if (!selected() || draft) return;
        remember(snapshot());
        annotations.set(
            annotations().map((a) =>
                a.id === selected() ? { ...a, ...patch } : a,
            ),
        );
        previewPath.set("");
        void refreshPreview();
    };
    const remove = () => {
        if (!selected()) return;
        remember(snapshot());
        annotations.set(annotations().filter((a) => a.id !== selected()));
        selected.set("");
        previewPath.set("");
        previewGeneration++;
        void refreshPreview();
    };
    cleanup(() => {
        previewGeneration++;
    });
    const shortcuts: Record<string, string> = {
        select: "v",
        pen: "p",
        line: "l",
        arrow: "a",
        rectangle: "r",
        ellipse: "o",
        text: "t",
        number: "n",
        highlighter: "h",
        mosaic: "m",
        blur: "b",
        solid: "s",
        erase: "e",
        magnifier: "z",
        measure: "d",
        picker: "i",
        spotlight: "f",
        stamp: "g",
    };
    function chooseTool(value: Tool) {
        grab.set(false);
        tool.set(value);
        cropMode.set(false);
        selected.set("");
        if (defaults.rememberTool)
            void p.actions.saveSettings?.({ lastAnnotationTool: value });
    }
    const keys = keymap.bind(
        {
            "mod+z": undoAction,
            "mod+shift+z": redoAction,
            delete: remove,
            backspace: remove,
            "mod+plus": () => zoomAt(centre(), fit() * 1.25),
            "mod+minus": () => zoomAt(centre(), fit() / 1.25),
            "mod+1": fitImage,enter:()=>{if(cropMode())cropMode.set(false);},escape:()=>{if(cropMode()){cropMode.set(false);crop.set(null);}else p.onClose();},
            space: () => grab.set(!grab()),
            ...Object.fromEntries(
                Object.entries(shortcuts).map(([value, key]) => [
                    key,
                    () => chooseTool(value as Tool),
                ]),
            ),
        },
        { when: "notEditing" },
    );
    cleanup(() => keys());
    let sourceGeneration=0;
    effect(() => {
        const path = sourcePath(),sourceToken=++sourceGeneration;
        imageReady.set(false);
        void Image.getSize(path)
            .then(async (size) => {
                if (disposed||sourceToken!==sourceGeneration) return;
                imageSize.set({ width: size.width, height: size.height });
                if(path===originalPath)alignOverlay(size);
                if (
                    size.width > 4096 ||
                    size.height > 4096 ||
                    size.width * size.height > 4_000_000
                ) {
                    const preview = await imageCall("image.render", {
                        imagePath: path,
                        annotations: [],
                        preview: true,
                    });
                    if (disposed||sourceToken!==sourceGeneration) {
                        if (preview?.path)
                            await p.actions.invoke("image.releaseOutput", {
                                path: preview.path,
                            });
                        return;
                    }
                    if (!preview?.path) {
                        status.set(tr("无法生成受限尺寸预览，请返回重试。"));
                        return;
                    }
                    basePreviewPath.set(preview.path);
                    basePreviewSize.set({
                        width: preview.width || size.width,
                        height: preview.height || size.height,
                    });
                }
                imageReady.set(true);
                if(annotations().length||effects().brightness!==0||effects().contrast!==1||effects().saturation!==1||effects().sharpness!==0||effects().preset!=="None"||effects().invert||effects().removeBackground)void refreshPreview();
            })
            .catch((error) => {
                if (!disposed&&sourceToken===sourceGeneration) {
                    status.set(String(error));
                    imageReady.set(
                        String(error).includes("headless runs load no images"),
                    );
                }
            });
    });

    const samplePressure = () => {
        const sample = p.pressure;
        const value =
            typeof sample === "number"
                ? sample
                : sample &&
                    (!sample.receivedAt ||
                        Date.now() - sample.receivedAt <= 200)
                  ? sample.pressure
                  : 1;
        return typeof value === "number" && Number.isFinite(value) && value > 0
            ? Math.max(0.05, Math.min(1, value))
            : 1;
    };
    const begin = (point: Point) => {
        if (!imageReady()||busy()) return;
        if (grab()) {
            panOrigin = point;
            panStart = pan();
            return;
        }
        const raw=outputToSource(screenToImage(point,viewport(),sceneSize(),fit(),pan()),geometry()),allowed=normalizedCrop(geometry());if(raw.x<allowed.x||raw.y<allowed.y||raw.x>allowed.x+allowed.width||raw.y>allowed.y+allowed.height)return;
        start = {
            ...toImage(point),
            ...(defaults.stylusPressure ? { pressure: samplePressure() } : {}),
        };
        cursorPoint.set(start);
        before = snapshot();
        previewPath.set("");
        previewGeneration++;
        if (tool() === "picker") {
            const pos = start;
            void p.actions
                .invoke("image.sample", {
                    imagePath: sourcePath(),
                    x: pos.x,
                    y: pos.y,
                })
                .then((r: any) => {
                    if (!disposed && r?.color) {
                        color.set(r.color);
                        status.set(tr("已取色 {0}", { "0": r.color }));
                    }
                });
            start = null;
            return;
        }
        if (cropMode()) return;
        if (tool() === "select") {
            const found = [...annotations()]
                .reverse()
                .find((a) => hitTest(a, start!, 8 / fit()));
            if (found) {
                color.set(found.color);
                width.set(found.width);
                opacity.set(found.opacity);
                text.set(found.text || "文字");
                fontSize.set(found.fontSize || 24);
                fontFamily.set(found.fontFamily);if(found.imagePath){stampMode.set("image");const existing=stampSource();if(existing?.path!==found.imagePath){const b=bounds(found);stampSource.set({path:found.imagePath,width:b.width,height:b.height,leaseId:""});}stampRotation.set(found.imageRotation||0);}else if(found.tool==="stamp")stampMode.set("emoji");
                arrowStyle.set(found.arrowStyle || "line");appearance.set({...appearance(),lineStyle:found.lineStyle||"solid",fillMode:found.fillMode||"stroke",cornerRadius:found.cornerRadius??6,outline:!!found.outline,arrowFlip:!!found.arrowFlip,numberFormat:found.numberFormat||"decimal",magnifierZoom:found.magnifierZoom||2,spotlightOpacity:found.spotlightOpacity??.55,measureUnit:found.measureUnit||"px",imageScale:found.imageScale||1});
                textStyle.set({
                    bold: !!found.bold,
                    italic: !!found.italic,
                    underline: !!found.underline,
                    strike: !!found.strike,
                    align: found.align || "left",
                    background: found.background || "",
                });
            }
            selected.set(found?.id || "");
            dragBase = found ? cloneAnnotation(found) : null;
            return;
        }
        if (annotations().length >= 500) {
            status.set(tr("最多支持 500 个标注，请删除部分标注后继续。"));
            start = null;
            return;
        }
        if(tool()==="stamp"&&stampMode()==="image"&&!stampSource()){status.set(tr("请先导入图片图章"));start=null;return;}
        draft = {
            id: `a-${Date.now()}-${Math.random().toString(36).slice(2)}`,
            tool: tool(),
            points: [start, { ...start }],
            color: color(),
            width: width(),
            opacity: opacity(),
            arrowStyle: arrowStyle(),
            ...textStyle(),...appearance(),
            text:
                tool() === "stamp"
                    ? text() === "文字"
                        ? "👍"
                        : text()
                    : text(),
            fontSize: fontSize(),
            fontFamily: fontFamily(),
            ...(tool()==="stamp"&&stampMode()==="image"&&stampSource()?{imagePath:stampSource()!.path,imageRotation:stampRotation()}:{}),
            number:nextNumber(),numberStart:nextNumber(),
        };
        if(draft.tool==="stamp"&&draft.imagePath){const source=stampSource()!,size=Math.min(200,imageSize().width/3),height=size*source.height/source.width;draft.points=[start,{x:start.x+size,y:start.y+height}];}
        if(draft.tool==="number")nextNumber.set(nextNumber()+1);
        annotations.set([...annotations(), draft]);
        selected.set(draft.id);
    };
    const move = (point: Point) => {
        if (panOrigin) {
            pan.set({
                x: panStart.x + point.x - panOrigin.x,
                y: panStart.y + point.y - panOrigin.y,
            });
            return;
        }
        if (!start) return;
        const pos = {
            ...toImage(point),
            ...(defaults.stylusPressure ? { pressure: samplePressure() } : {}),
        };
        cursorPoint.set(pos);
        if (cropMode()) {
            crop.set({
                x: Math.min(start.x, pos.x),
                y: Math.min(start.y, pos.y),
                width: Math.abs(pos.x - start.x),
                height: Math.abs(pos.y - start.y),
            });
            return;
        }
        if (dragBase) {
            annotations.set(
                annotations().map((a) =>
                    a.id === dragBase!.id
                        ? moved(dragBase!, pos.x - start!.x, pos.y - start!.y)
                        : a,
                ),
            );
            return;
        }
        if (!draft) return;
        if (draft.tool === "pen" || draft.tool === "highlighter") {
            if(draft.points.length<4096){const previous=draft.points[draft.points.length-1]!;const factor=draft.tool==="pen"&&smoothing()!=="none"?(smoothing()==="fine"?.5:.75):1;draft={...draft,points:[...draft.points,{...pos,x:previous.x+(pos.x-previous.x)*factor,y:previous.y+(pos.y-previous.y)*factor}]};}
        } else if(draft.tool==="stamp"&&draft.imagePath){const source=stampSource()!,ratio=source.height/source.width,w=Math.max(8,Math.abs(pos.x-start.x),Math.abs(pos.y-start.y)/ratio),h=w*ratio;draft={...draft,points:[{x:pos.x<start.x?start.x-w:start.x,y:pos.y<start.y?start.y-h:start.y},{x:pos.x<start.x?start.x:start.x+w,y:pos.y<start.y?start.y:start.y+h}]};}
        else draft = { ...draft, points: [start, pos] };
        annotations.set(
            annotations().map((a) => (a.id === draft!.id ? draft! : a)),
        );
    };
    const smartBusy=signal(false),smartError=signal("");
    const smartEngine=createSmartHighlight({sourcePath,getAnnotations:annotations,setAnnotations:rows=>{annotations.set(rows);previewPath.set("");previewGeneration++;},invoke:(method,params,signal)=>{if(!p.actions.invokeWithSignal)throw Error(tr("文字识别服务尚未就绪"));return p.actions.invokeWithSignal(method,params,signal);},onStatus:result=>{if(disposed)return;smartBusy.set(result.pending>0);if(result.phase==="aligned"){status.set(result.message?tr(result.message):tr("已对齐 {0} 处文字",{"0":result.count||0}));void refreshPreview();}else if(result.phase==="failed"||result.phase==="limit"){const message=tr(result.message||"文字行对齐失败，已保留原笔画。");smartError.set(message);status.set(message);inspectorOpen.set(true);}else if(result.pending>0)status.set(tr("正在处理 {0} 笔文字标注…",{"0":result.pending}));}});
    function resetSmart(){smartEngine.reset();smartError.set("");}
    cleanup(()=>smartEngine.dispose());
    let previousSmartSource=sourcePath(),previousSmartCrop=JSON.stringify(crop());
    effect(()=>{const path=sourcePath(),area=JSON.stringify(crop());if(path!==previousSmartSource||area!==previousSmartCrop){previousSmartSource=path;previousSmartCrop=area;resetSmart();}});
    const end = () => {
        if (panOrigin) {
            panOrigin = null;
            return;
        }
        if (!start) return;
        if(draft?.tool==="pen"&&cursorPoint()){draft={...draft,points:[...draft.points,cursorPoint()!]};annotations.set(annotations().map(row=>row.id===draft!.id?draft!:row));}
        const finished = draft;
        if (draft || dragBase) remember(before);
        start = null;
        cursorPoint.set(null);
        draft = null;
        dragBase = null;
        if (finished?.tool === "highlighter" && smartHighlight())
            smartEngine.queue(finished);
        else if(finished&&censorTools.includes(finished.tool)&&textOnlyCensor())smartEngine.queue(finished,{kind:"text-censor"});
        else void refreshPreview();
    };
    const pointer = PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onPanResponderGrant: (e) => {
            if (!start) begin({ x: e.locationX, y: e.locationY });
        },
        onPanResponderMove: (e) => move({ x: e.locationX, y: e.locationY }),
        onPanResponderRelease: end,
        onPanResponderTerminate: end,
    }).panHandlers;
    async function deliverImage(action:string){if(smartError())return;let outputPath:string|undefined;busy.set(true);status.set(tr("正在生成原生分辨率 PNG…"));try{await smartEngine.settle();if(cropMode())cropMode.set(false);const result=await imageCall("image.render",{imagePath:sourcePath(),...imageSize(),annotations:annotations(),effects:effects(),crop:crop(),rotation:rotation(),flipH:flipH(),flipV:flipV()});outputPath=result?.path;if(disposed)return;if(!outputPath)throw Error(tr("导出没有返回文件，请查看诊断信息。"));
      let delivered=false;if(action==="copy"||action==="done"){const copied=await p.actions.invoke("clipboard.write",{type:"image",path:outputPath,sensitive:true});if(copied===undefined||copied===false)throw Error(tr("复制未完成，编辑内容已保留。"));delivered=true;}
      else if(action==="save"){const saved=await p.actions.invoke("files.saveCopy",{path:outputPath,name:"Clipy.png"});if(saved?.cancelled){status.set(tr("已取消保存"));return;}if(!saved?.path)throw Error(tr("保存失败，请查看诊断信息"));delivered=true;}
      else{const reply=await p.actions.invoke(`capture.${action}`,{path:outputPath});if(reply===undefined||reply===false)throw Error(tr("操作未完成，请查看诊断信息。"));if(!disposed)status.set(tr("操作已完成"));}
      if(disposed)return;if(delivered){const committed=await p.actions.invoke("image.commit",{path:outputPath});if(!committed?.committed)throw Error(tr("保存截图历史失败，编辑内容已保留。"));outputPath=undefined;status.set(tr(action==="save"?"截图已保存":"已复制图片"));if(action==="done")p.onClose();}
    }catch(error){if(!disposed)status.set(String(error));}finally{if(outputPath)try{await p.actions.invoke("image.releaseOutput",{path:outputPath});}catch{}if(!disposed)busy.set(false);}}
    const exportImage=(copy=false)=>deliverImage(copy?"copy":"save");
    function draw(
        c: CanvasRenderingContext2D,
        size: { width: number; height: number },
    ) {
        c.clearRect(0,0,size.width,size.height);
        c.fillStyle = p.overlay?"#00000066":"#262626";
        c.fillRect(0, 0, size.width, size.height);
        if (!imageReady()) return;
        c.save();
        c.translate(offset().x, offset().y);
        c.scale(fit(), fit());
        const g=geometry(),out=sceneSize(),padding=g.padding||0,inner={x:padding,y:padding,width:out.width-padding*2,height:out.height-padding*2};
        if(effects().beautify){const endpoints=gradientEndpoints(out.width,out.height,effects().gradientAngle),gradient=c.createLinearGradient(endpoints.x0,endpoints.y0,endpoints.x1,endpoints.y1);effects().gradientColors.forEach((value,index)=>gradient.addColorStop(index/(effects().gradientColors.length-1),value));c.fillStyle=effects().gradientMode==="solid"?effects().gradientSolid:gradient;c.fillRect(0,0,out.width,out.height);c.save();c.shadowColor="#0000004D";c.shadowBlur=effects().shadow;c.shadowOffsetY=effects().shadow*.3;c.fillStyle="#FFFFFF";c.beginPath();c.roundRect(inner.x,inner.y,inner.width,inner.height,effects().beautifyMode==="plain"?0:effects().radius);c.fill();c.restore();}
        c.save();c.beginPath();if(effects().beautify)c.roundRect(inner.x,inner.y,inner.width,inner.height,effects().beautifyMode==="plain"?0:effects().radius);else c.rect(inner.x,inner.y,inner.width,inner.height);c.clip();if(g.header){c.fillStyle="#F5F5F5";c.fillRect(inner.x,inner.y,inner.width,g.header);for(let i=0;i<3;i++){c.fillStyle=["#FF5F57","#FFBD2E","#28C840"][i]!;c.beginPath();c.arc(inner.x+19+i*18,inner.y+16,5,0,Math.PI*2);c.fill();}c.beginPath();c.rect(inner.x,inner.y+g.header,inner.width,inner.height-g.header);c.clip();}const matrix=geometryMatrix(g);c.transform(matrix.a,matrix.b,matrix.c,matrix.d,matrix.tx,matrix.ty);
        c.drawImage(
            previewPath() || basePreviewPath() || sourcePath(),
            0,
            0,
            imageSize().width,
            imageSize().height,
        );
        for (const a of annotations()) {
            if (!previewPath())
                drawAnnotation(
                    c,
                    a,
                    basePreviewPath() || sourcePath(),
                    imageSize(),
                    basePreviewPath()
                        ? {
                              x: basePreviewSize().width / imageSize().width,
                              y: basePreviewSize().height / imageSize().height,
                          }
                        : { x: 1, y: 1 },
                );
            if (a.id === selected()) {
                const b = bounds(a);
                c.save();
                c.lineWidth = 1 / fit();
                c.strokeStyle = "#087BFF";
                c.setLineDash([5 / fit(), 4 / fit()]);
                c.strokeRect(
                    b.x - 6 / fit(),
                    b.y - 6 / fit(),
                    Math.max(b.width, 12) + 12 / fit(),
                    Math.max(b.height, 12) + 12 / fit(),
                );
                c.restore();
            }
        }
        if (defaults.showGuides && cursorPoint()) {
            const point = cursorPoint()!;
            c.save();
            c.strokeStyle = "#087BFF";
            c.lineWidth = 1 / fit();
            c.setLineDash([4 / fit(), 4 / fit()]);
            c.beginPath();
            c.moveTo(0, point.y);
            c.lineTo(imageSize().width, point.y);
            c.moveTo(point.x, 0);
            c.lineTo(point.x, imageSize().height);
            c.stroke();
            c.restore();
        }
        if (cropMode()&&crop()) {
            const r = crop()!;
            c.strokeStyle = "#FFFFFF";
            c.lineWidth = 2 / fit();
            c.setLineDash([6 / fit(), 3 / fit()]);
            c.strokeRect(r.x, r.y, r.width, r.height);
        }
        c.restore();
        c.restore();
    }
    const paintTools:Tool[]=["pen","line","arrow","rectangle","ellipse","highlighter","text","number","mosaic","spotlight","magnifier","stamp","picker","measure"];
    const censorTools:Tool[]=["mosaic","blur","solid","erase"];
    const painted=()=>["pen","line","arrow","rectangle","ellipse","highlighter","text","number","measure"].includes(activeTool());
    function changeAppearance(key:string,value:any){appearance.set({...appearance(),[key]:value});updateSelected({[key]:value});}
    function changeEffect(key:string,value:any){effects.set({...effects(),[key]:value});previewPath.set("");previewGeneration++;void refreshPreview();}
    function chooseCensor(value:Tool){censorMode.set(value);tool.set(value);if(selected())updateSelected({tool:value});}
    async function redact(categories:string[]){busy.set(true);try{const result=await imageCall("image.redact",{imagePath:sourcePath(),categories});if(!disposed&&Array.isArray(result?.annotations)){remember(snapshot());annotations.set([...annotations(),...result.annotations.slice(0,500-annotations().length)]);status.set(tr("已识别 {0} 处，可选中后删除。",{"0":result.annotations.length}));void refreshPreview();}}finally{if(!disposed)busy.set(false);}}
    const labelFor=(id:Tool)=>TOOLS.find(item=>item.id===id)?.label||id;
    function IconButton(q:{name:string;label:string;active?:boolean;disabled?:boolean;onPress:()=>void}){return <View role="button" accessibilityLabel={tr(q.label)} disabled={!!q.disabled} tooltip={<Text>{tr(q.label)}</Text>} onPress={()=>{if(!q.disabled)q.onPress();}} class={`w-[30px] h-[30px] rounded-lg items-center justify-center ${q.disabled?"opacity-35":""} ${q.active?"bg-[#087BFF]":"hover:bg-secondary"}`}><ToolIcon name={q.name} color={q.active?"#FFFFFF":colorScheme()==="dark"?"#C8C8CF":"#65656B"}/></View>;}
    function Segment(q:{value:string;items:{id:string;label:string}[];onChange:(value:string)=>void}){return <View class="flex-row bg-secondary rounded-md p-[2px] gap-[2px]"><Each of={q.items}>{item=><View role="button" accessibilityLabel={tr(item().label)} onPress={()=>q.onChange(item().id)} class={`flex-1 min-w-0 h-[24px] rounded-[5px] items-center justify-center ${q.value===item().id?"bg-background":""}`}><Text class="text-[11px] text-foreground" style={{numberOfLines:1}}>{tr(item().label)}</Text></View>}</Each></View>;}
    function OptionSlider(q:{label:string;value:number;min:number;max:number;step?:number;display?:string;onChange:(value:number)=>void}){return <View class="flex-row items-center gap-2"><Text class="w-[76px] text-[11px] text-muted-foreground">{tr(q.label)}</Text><Slider accessibilityLabel={tr(q.label)} class="flex-1" min={q.min} max={q.max} step={q.step??1} value={q.value} trackClass="h-[24px] justify-center" indicatorClass="h-[3px] rounded-full bg-secondary" rangeClass="bg-[#087BFF] rounded-full" thumbClass="w-[14px] h-[14px] rounded-full bg-background border border-border" onChange={event=>q.onChange(Number(Array.isArray(event.value)?event.value[0]:event.value))}/><Text class="w-[32px] text-right text-[11px] text-foreground">{q.display??String(Math.round(q.value*100)/100)}</Text></View>;}
    let translation:ReturnType<typeof createCaptureTranslation>|undefined,translationGeneration=0;
    function cancelTranslation(){translationGeneration++;translation?.cancel();translationBusy.set(false);}
    cleanup(()=>translation?.dispose());
    async function translateSelection(){const backend=translationBackend(),current=++translationGeneration;translation?.dispose();translation=createCaptureTranslation({sourcePath:sourcePath(),sourceSize:imageSize(),invoke:(method,params,signal)=>{if(!p.actions.invokeWithSignal)throw Error(tr("翻译服务尚未就绪"));return p.actions.invokeWithSignal(method,method==="model.translate"?{...params,backend}:params,signal);},onStatus:value=>{if(!disposed&&current===translationGeneration)status.set(value.phase==="translating"?tr("正在翻译 {0}/{1} 行",{"0":value.completed,"1":value.total}):tr(value.phase==="recognizing"?"正在识别文字…":value.phase==="complete"?"翻译完成":value.phase==="cancelled"?"截图翻译已取消":"翻译失败"));}});translationBusy.set(true);try{const result=await translation.submit(translationTarget(),{background:"#FFFFFF",color:"#1D1D1F"});if(disposed||current!==translationGeneration)return;if(annotations().length+result.length>500)throw Error(tr("最多支持 500 个标注，请删除部分标注后继续。"));remember(snapshot());annotations.set([...annotations(),...result]);previewPath.set("");void refreshPreview();status.set(tr("已添加可编辑翻译标注"));}catch(error){if(!disposed&&current===translationGeneration&&(error as any)?.code!=="CANCELLED")status.set(tr(error instanceof Error?error.message:String(error)));}finally{if(!disposed&&current===translationGeneration)translationBusy.set(false);}}
    function applyColor(value:string,remember=false){const parsed=parseHex(value);if(!parsed)return;color.set(parsed);updateSelected({color:parsed});if(remember){const list=recentColors(recent(),parsed);recent.set(list);void p.actions.saveSettings?.({recentAnnotationColors:list});}}
    async function importStamp(){if(stampSources().length>=8){status.set(tr("每个文档最多导入 8 个图片图章"));return;}busy.set(true);try{const result=await p.actions.invoke("editor.importStamp",{});if(disposed)return;if(result?.cancelled)return;if(!result?.path||!result.width||!result.height)throw Error(tr("图片图章导入失败"));stampSource.set(result);stampSources.set([...stampSources(),result.leaseId||result.path]);stampMode.set("image");chooseTool("stamp");status.set(tr("在画布上拖动放置图片图章"));}catch(error){if(!disposed)status.set(String(error));}finally{if(!disposed)busy.set(false);}}
    function ColorEditor(q:{value:string;onChange:(value:string)=>void;onCommit?:(value:string)=>void}){const hsba=signal(hexToHSBA(q.value)),hex=signal(q.value),error=signal("");let own=q.value;effect(()=>{const value=q.value;if(value!==own){own=value;hsba.set(hexToHSBA(value));hex.set(value);error.set("");}});function change(key:string,value:number){error.set("");const next={...hsba(),[key]:value};hsba.set(next);own=hsbaToHex(next);hex.set(own);q.onChange(own);}function apply(){const value=parseHex(hex());if(!value){error.set(tr("请输入 6 或 8 位十六进制颜色"));return;}own=value;hsba.set(hexToHSBA(value));q.onChange(value);q.onCommit?.(value);error.set("");}return <View class="gap-2"><OptionSlider label="色相 H" value={hsba().h} min={0} max={360} display={`${Math.round(hsba().h)}°`} onChange={value=>change("h",value)}/><OptionSlider label="饱和度 S" value={hsba().s*100} min={0} max={100} display={`${Math.round(hsba().s*100)}%`} onChange={value=>change("s",value/100)}/><OptionSlider label="明度 B" value={hsba().b*100} min={0} max={100} display={`${Math.round(hsba().b*100)}%`} onChange={value=>change("b",value/100)}/><OptionSlider label="颜色 Alpha" value={hsba().a*100} min={0} max={100} display={`${Math.round(hsba().a*100)}%`} onChange={value=>change("a",value/100)}/><Field label="Hex / RGBA" value={hex()} onChange={(value:string)=>hex.set(value)}/><If when={!!error()}><Text class="text-[10px] text-red-500">{error()}</Text></If><Btn label={tr("应用颜色")} onPress={apply}/></View>;}
    const gradientStop=signal(0);
    const moreColor=signal(false),moreEmoji=signal(false);
    function HeaderToolbar(){return <View class="h-[52px] flex-row items-center gap-[2px] px-3 border-b border-border bg-sidebar/70">
      <If when={!p.overlay&&windowSize().width>=1040}><Text class="text-[11px] font-semibold text-muted-foreground mr-3">{tr("标注编辑")}</Text></If>
      <IconButton name="select" label="选择" active={tool()==="select"&&!grab()} onPress={()=>chooseTool("select")}/><IconButton name="grab" label="抓手" active={grab()} onPress={()=>grab.set(!grab())}/><View class="w-px h-5 bg-border mx-1"/>
      <Scroll horizontal class="flex-1"><View class="flex-row items-center gap-[2px]"><Each of={paintTools}>{id=><IconButton name={id()} label={id()==="mosaic"?"遮挡":labelFor(id())} active={id()==="mosaic"?censorTools.includes(tool()):tool()===id()} onPress={()=>{chooseTool(id()==="mosaic"?censorMode():id());if(p.overlay)inspectorOpen.set(true);}}/>}</Each></View></Scroll>
      <View class="w-px h-5 bg-border mx-1"/><IconButton name="crop" label="裁剪" active={cropMode()} onPress={()=>cropMode.set(!cropMode())}/><IconButton name="flipH" label="水平翻转" active={flipH()} onPress={()=>flipH.set(!flipH())}/><IconButton name="flipV" label="垂直翻转" active={flipV()} onPress={()=>flipV.set(!flipV())}/><IconButton name="rotate" label="旋转" onPress={()=>rotation.set((rotation()+90)%360)}/>
      <IconButton name="undo" label="撤销" disabled={busy()||(!undo().length&&!documentUndo().length)} onPress={undoAction}/><IconButton name="redo" label="重做" disabled={busy()||(!redo().length&&!documentRedo().length)} onPress={redoAction}/>
      <Btn label={`${Math.round(fit()*100)}% ▾`} accessibilityLabel={tr("缩放菜单")} onPress={()=>void Menu.popup([{label:tr("放大"),shortcut:"mod+plus",onSelect:()=>zoomAt(centre(),fit()*1.25)},{label:tr("缩小"),shortcut:"mod+minus",onSelect:()=>zoomAt(centre(),fit()/1.25)},{type:"separator"},{label:tr("适应画布"),shortcut:"mod+1",onSelect:fitImage},{label:"100%",onSelect:()=>zoomAt(centre(),1)}])}/><If when={p.overlay}><IconButton name="select" label="检查器" active={inspectorOpen()} onPress={()=>inspectorOpen.set(!inspectorOpen())}/></If><Btn label={tr("添加截图")} disabled={busy()||translationBusy()||smartBusy()||!!smartError()||composeCount()>=4} onPress={()=>void Menu.popup([{label:tr("纵向添加"),onSelect:()=>void appendCapture("vertical")},{label:tr("横向添加"),onSelect:()=>void appendCapture("horizontal")}])}/><Btn label={tr("返回")} onPress={p.onClose}/>
    </View>;}
    function Inspector(){return <Scroll class="w-[268px] border-l border-border bg-background p-4 gap-[14px]">
      <View class="flex-row items-center gap-2"><View class="w-[24px] h-[24px] rounded-md bg-blue-500/15 items-center justify-center"><ToolIcon name={activeTool()} color="#087BFF" size={14}/></View><Text class="text-[13px] font-semibold text-foreground flex-1">{tr(censorTools.includes(activeTool())?"遮挡":labelFor(activeTool()))}</Text><Text class="text-[10px] text-muted-foreground">{selected()?tr("已选中 1 个标注"):""}</Text></View>
      <If when={!!smartError()}><Text class="text-[11px] text-red-500">{smartError()}</Text><Btn label={tr("以原笔画继续")} onPress={()=>{resetSmart();status.set(tr("已保留原笔画，可继续编辑或输出"));}}/></If><If when={painted()}><View class="flex-row items-center"><Text class="text-[11px] text-muted-foreground flex-1">{tr("颜色")}</Text><Text class="text-[10px] text-muted-foreground">{color()}</Text></View><Each of={[COLORS.slice(0,6),COLORS.slice(6,12)]}>{row=><View class="flex-row justify-between"><Each of={row()}>{value=><View role="button" accessibilityLabel={tr("颜色 {0}",{"0":value()})} onPress={()=>{applyColor(value(),true);}} class="w-[22px] h-[22px] rounded-full border-2" style={{backgroundColor:value(),borderColor:color()===value()?"#087BFF":"#9B9BA255"}}/>}</Each></View>}</Each><OptionSlider label="不透明度" value={opacity()} min={0} max={1} step={.01} display={`${Math.round(opacity()*100)}%`} onChange={value=>{opacity.set(value);updateSelected({opacity:value});}}/><Btn label={tr("更多颜色…")} onPress={()=>moreColor.set(!moreColor())}/><If when={moreColor()}><ColorEditor value={color()} onChange={value=>applyColor(value)} onCommit={value=>applyColor(value,true)}/><If when={recent().length>0}><Text class="text-[10px] text-muted-foreground">{tr("最近颜色")}</Text><View class="flex-row flex-wrap gap-2"><Each of={recent()}>{value=><View role="button" accessibilityLabel={tr("最近颜色 {0}",{"0":value()})} onPress={()=>applyColor(value(),true)} class="w-[22px] h-[22px] rounded-full border border-border" style={{backgroundColor:value()}}/>}</Each></View></If></If></If>
      <If when={["pen","line","arrow","rectangle","ellipse","highlighter","number","magnifier"].includes(activeTool())}><OptionSlider label="线宽" value={width()} min={1} max={24} onChange={value=>{width.set(value);updateSelected({width:value});}}/></If>
      <If when={["pen","line","arrow","rectangle","ellipse"].includes(activeTool())}><View class="gap-2"><Text class="text-[11px] text-muted-foreground">{tr("线型")}</Text><Segment value={appearance().lineStyle} items={[{id:"solid",label:"━━"},{id:"dash",label:"┄┄"},{id:"dot",label:"┈┈"}]} onChange={value=>changeAppearance("lineStyle",value)}/></View></If>
      <If when={["rectangle","ellipse"].includes(activeTool())}><Text class="text-[11px] text-muted-foreground">{tr("填充")}</Text><Segment value={appearance().fillMode} items={[{id:"stroke",label:"描边"},{id:"mixed",label:"半透明"},{id:"fill",label:"填充"}]} onChange={value=>changeAppearance("fillMode",value)}/></If>
      <If when={activeTool()==="rectangle"}><OptionSlider label="圆角" value={appearance().cornerRadius} min={0} max={64} onChange={value=>changeAppearance("cornerRadius",value)}/></If>
      <If when={activeTool()==="arrow"}><Text class="text-[11px] text-muted-foreground">{tr("箭头样式")}</Text><Segment value={arrowStyle()} items={[{id:"line",label:"→"},{id:"dash",label:"⇢"},{id:"curve",label:"↝"},{id:"long",label:"⟶"},{id:"bar",label:"⇥"},{id:"double",label:"↔"}]} onChange={value=>{arrowStyle.set(value);updateSelected({arrowStyle:value});}}/><Setting label={tr("描边轮廓")} value={appearance().outline} onChange={(value:boolean)=>changeAppearance("outline",value)}/><Setting label={tr("翻转")} value={appearance().arrowFlip} onChange={(value:boolean)=>changeAppearance("arrowFlip",value)}/></If>
      <If when={activeTool()==="pen"}><Text class="text-[11px] text-muted-foreground">{tr("平滑")}</Text><Segment value={smoothing()} items={[{id:"none",label:"无"},{id:"smooth",label:"平滑"},{id:"fine",label:"精细"}]} onChange={value=>smoothing.set(value)}/><Text class="text-[10px] text-muted-foreground">{tr(defaults.stylusPressure?"压感已开启":"压感可在截图设置中开启")}</Text></If>
      <If when={activeTool()==="highlighter"}><Setting label={tr("智能")} value={smartHighlight()} onChange={(value:boolean)=>smartHighlight.set(value)}/></If>
      <If when={activeTool()==="number"}><Text class="text-[11px] text-muted-foreground">{tr("格式")}</Text><Segment value={appearance().numberFormat} items={[{id:"decimal",label:"1"},{id:"roman",label:"I"},{id:"upper",label:"A"},{id:"lower",label:"a"}]} onChange={value=>changeAppearance("numberFormat",value)}/><View class="flex-row items-center gap-2"><Text class="text-[11px] text-muted-foreground flex-1">{tr("起始")}</Text><Btn label="−" onPress={()=>{const value=Math.max(1,(annotations().find(row=>row.id===selected())?.number||nextNumber())-1);nextNumber.set(value);updateSelected({number:value});}}/><Text class={cx.text}>{annotations().find(row=>row.id===selected())?.number||nextNumber()}</Text><Btn label="+" onPress={()=>{const value=(annotations().find(row=>row.id===selected())?.number||nextNumber())+1;nextNumber.set(value);updateSelected({number:value});}}/></View></If>
      <If when={activeTool()==="text"}><Text class="text-[11px] text-muted-foreground">{tr("字体")}</Text><Btn label={`${fontFamily()||tr("系统")} ▾`} onPress={()=>void Menu.popup([{id:undefined,label:tr("系统")},{id:"PingFangSC-Regular",label:"PingFang SC"},{id:"Menlo-Regular",label:"Menlo"},{id:"TimesNewRomanPSMT",label:"Times New Roman"}].map(font=>({label:font.label,checked:fontFamily()===font.id,onSelect:()=>{fontFamily.set(font.id);updateSelected({fontFamily:font.id});}})))}/><Field label={tr("标注文字")} multiline value={text()} onChange={(value:string)=>{text.set(value);updateSelected({text:value});}}/><OptionSlider label="字体大小" value={fontSize()} min={8} max={96} onChange={value=>{fontSize.set(value);updateSelected({fontSize:value});}}/><View class="flex-row gap-1"><Each of={[{id:"bold",label:"B"},{id:"italic",label:"I"},{id:"underline",label:"U"},{id:"strike",label:"S"}]}>{item=><Btn label={item().label} primary={(textStyle() as any)[item().id]} onPress={()=>{const value={...textStyle(),[item().id]:!(textStyle() as any)[item().id]};textStyle.set(value);updateSelected(value);}}/>}</Each></View><Segment value={textStyle().align} items={[{id:"left",label:"左"},{id:"center",label:"中"},{id:"right",label:"右"}]} onChange={value=>{textStyle.set({...textStyle(),align:value});updateSelected({align:value});}}/><Setting label={tr("文字背景")} value={!!textStyle().background} onChange={(value:boolean)=>{textStyle.set({...textStyle(),background:value?"#FFFFFF":""});updateSelected({background:value?"#FFFFFF":""});}}/><Setting label={tr("描边轮廓")} value={appearance().outline} onChange={(value:boolean)=>changeAppearance("outline",value)}/></If>
      <If when={censorTools.includes(activeTool())}><Setting label={tr("仅文字")} value={textOnlyCensor()} onChange={(value:boolean)=>textOnlyCensor.set(value)}/><Text class="text-[11px] text-muted-foreground">{tr("模式")}</Text><Segment value={censorTools.includes(tool())?tool():activeTool()} items={[{id:"mosaic",label:"马赛克"},{id:"blur",label:"模糊"},{id:"solid",label:"纯色遮罩"},{id:"erase",label:"擦除"}]} onChange={value=>chooseCensor(value as Tool)}/><View class="rounded-xl bg-secondary p-3 gap-3"><Text class="text-[12px] font-semibold text-foreground">{tr("自动遮挡")}</Text><Text class="text-[10px] text-muted-foreground">{tr("识别结果可选中单个遮挡后删除。")}</Text><View class="flex-row flex-wrap gap-1"><Each of={[{id:"text",label:"全部文字"},{id:"privacy",label:"隐私信息"},{id:"faces",label:"人脸"},{id:"persons",label:"人物"}]}>{item=><Btn label={tr(item().label)} disabled={busy()} onPress={()=>void redact([item().id])}/>}</Each></View></View></If>
      <If when={activeTool()==="spotlight"}><OptionSlider label="变暗" value={appearance().spotlightOpacity} min={0} max={1} step={.01} display={`${Math.round(appearance().spotlightOpacity*100)}%`} onChange={value=>changeAppearance("spotlightOpacity",value)}/><Segment value={appearance().lineStyle} items={[{id:"solid",label:"实线边框"},{id:"dash",label:"虚线边框"}]} onChange={value=>changeAppearance("lineStyle",value)}/></If>
      <If when={activeTool()==="magnifier"}><OptionSlider label="缩放" value={appearance().magnifierZoom} min={1.2} max={5} step={.1} display={`${appearance().magnifierZoom.toFixed(1)}×`} onChange={value=>changeAppearance("magnifierZoom",value)}/><Setting label={tr("描边轮廓")} value={appearance().outline} onChange={(value:boolean)=>changeAppearance("outline",value)}/></If>
      <If when={activeTool()==="stamp"}><Segment value={stampMode()} items={[{id:"emoji",label:"表情"},{id:"image",label:"图片"}]} onChange={value=>{stampMode.set(value);chooseTool("stamp");}}/><If when={stampMode()==="image"}><Btn label={tr("导入图片图章…")} disabled={busy()||stampSources().length>=8} onPress={()=>void importStamp()}/><Text class="text-[10px] text-muted-foreground">{tr("最多 8 个源文件，总输入不超过 32 MiB。关闭编辑器后释放。")}</Text><If when={!!stampSource()}><Text class="text-[10px] text-muted-foreground">{`${stampSource()?.width} × ${stampSource()?.height}`}</Text><OptionSlider label="图章旋转" value={stampRotation()} min={-180} max={180} onChange={value=>{stampRotation.set(value);updateSelected({imageRotation:value});}}/><OptionSlider label="图章宽度" value={annotations().find(a=>a.id===selected())?.imagePath?bounds(annotations().find(a=>a.id===selected())!).width:200} min={8} max={Math.min(2000,imageSize().width)} onChange={value=>{const row=annotations().find(a=>a.id===selected());if(row?.imagePath){const b=bounds(row),ratio=b.height/Math.max(1,b.width);updateSelected({points:[{x:b.x,y:b.y},{x:b.x+value,y:b.y+value*ratio}]});}}}/><OptionSlider label="不透明度" value={opacity()} min={0} max={1} step={.01} onChange={value=>{opacity.set(value);updateSelected({opacity:value});}}/></If></If><If when={stampMode()==="emoji"}><View class="flex-row flex-wrap gap-1"><Each of={["👍","✅","❌","⚠️","❤️","⭐️","🔥","👀","💡","🎉","❓","📌"]}>{emoji=><View role="button" accessibilityLabel={emoji()} onPress={()=>{text.set(emoji());updateSelected({text:emoji()});}} class={`w-[32px] h-[32px] rounded-md items-center justify-center ${text()===emoji()?"bg-blue-500/15":""}`}><Text class="text-[22px]">{emoji()}</Text></View>}</Each></View><Btn label={tr("更多表情")} onPress={()=>moreEmoji.set(!moreEmoji())}/><If when={moreEmoji()}><Field label={tr("图章内容")} value={text()} onChange={(value:string)=>{text.set(value);updateSelected({text:value});}}/></If><OptionSlider label="图章尺寸" value={fontSize()} min={16} max={96} onChange={value=>{fontSize.set(value);updateSelected({fontSize:value});}}/></If></If>
      <If when={activeTool()==="picker"}><Text class="text-[11px] text-muted-foreground leading-[18px]">{tr("在画布上点击取样颜色，取到的颜色设为当前标注颜色。")}</Text></If>
      <If when={activeTool()==="measure"}><Text class="text-[11px] text-muted-foreground">{tr("单位")}</Text><Segment value={appearance().measureUnit} items={[{id:"px",label:"px"},{id:"pt",label:"pt"}]} onChange={value=>changeAppearance("measureUnit",value)}/><Text class="text-[10px] text-muted-foreground">{tr("测量以原图像素为准")}</Text></If>
      <If when={translationOpen()}><View class="h-px bg-border my-1"/><Text class="text-[12px] font-semibold text-foreground">{tr("原位翻译")}</Text><Segment value={translationBackend()} items={[{id:"system",label:"系统翻译"},{id:"model",label:"模型翻译"}]} onChange={value=>{cancelTranslation();translationBackend.set(value);void p.actions.saveSettings?.({captureTranslationBackend:value});}}/><Text class="text-[10px] text-muted-foreground">{tr(translationBackend()==="system"?"系统翻译需要 macOS 26 与已下载语言包，不会自动改用在线模型。":"模型翻译使用你配置的服务地址与密钥。")}</Text><Field label={tr("目标语言")} value={translationTarget()} onChange={(value:string)=>{cancelTranslation();translationTarget.set(value);}}/><Text class="text-[10px] text-muted-foreground">{tr("识别最多 20 行，翻译后可选择文字继续编辑。")}</Text><View class="flex-row gap-1"><Btn label={tr("开始翻译")} primary disabled={translationBusy()||!translationTarget().trim()} onPress={()=>void translateSelection()}/><Btn label={tr("取消")} disabled={!translationBusy()} onPress={()=>{cancelTranslation();}}/></View></If>
      <View class="h-px bg-border my-1"/><Setting label={tr("美化")} value={effects().beautify} onChange={(value:boolean)=>changeEffect("beautify",value)}/><If when={effects().beautify}><Segment value={effects().beautifyMode} items={[{id:"window",label:"窗口"},{id:"rounded",label:"圆角"},{id:"plain",label:"无边框"}]} onChange={value=>changeEffect("beautifyMode",value)}/><Text class="text-[11px] text-muted-foreground">{tr("背景")}</Text><Segment value={effects().gradientMode} items={[{id:"gradient",label:"渐变"},{id:"solid",label:"纯色"}]} onChange={value=>changeEffect("gradientMode",value)}/><If when={effects().gradientMode==="solid"}><ColorEditor value={effects().gradientSolid} onChange={value=>changeEffect("gradientSolid",value)}/></If><If when={effects().gradientMode==="gradient"}><View class="flex-row flex-wrap gap-2"><Each of={effects().gradientColors}>{(value,index)=><View role="button" accessibilityLabel={tr("渐变色标 {0}",{"0":index()+1})} onPress={()=>gradientStop.set(index())} class="w-[25px] h-[25px] rounded border-2" style={{backgroundColor:value(),borderColor:gradientStop()===index()?"#087BFF":"#AAAAAA"}}/>}</Each></View><View class="flex-row gap-1"><Btn label={tr("添加色标")} disabled={effects().gradientColors.length>=8} onPress={()=>{const next=[...effects().gradientColors,"#FFFFFF"];gradientStop.set(next.length-1);changeEffect("gradientColors",next);}}/><Btn label={tr("删除色标")} disabled={effects().gradientColors.length<=2} onPress={()=>{const next=effects().gradientColors.filter((_,index)=>index!==gradientStop());gradientStop.set(Math.min(gradientStop(),next.length-1));changeEffect("gradientColors",next);}}/></View><ColorEditor value={effects().gradientColors[gradientStop()]||effects().gradientColors[0]!} onChange={value=>changeEffect("gradientColors",effects().gradientColors.map((old,index)=>index===gradientStop()?value:old))}/><OptionSlider label="渐变角度" value={effects().gradientAngle} min={0} max={360} display={`${Math.round(effects().gradientAngle)}°`} onChange={value=>changeEffect("gradientAngle",value)}/></If><OptionSlider label="内边距" value={effects().padding} min={0} max={100} onChange={value=>changeEffect("padding",value)}/><OptionSlider label="半径" value={effects().radius} min={0} max={64} onChange={value=>changeEffect("radius",value)}/><OptionSlider label="阴影" value={effects().shadow} min={0} max={100} onChange={value=>changeEffect("shadow",value)}/></If>
      <View class="h-px bg-border my-1"/><View class="flex-row items-center"><Text class="text-[11px] text-muted-foreground flex-1">{tr("调整（图像特效）")}</Text><Btn label={tr("重置")} onPress={()=>{effects.set({...effects(),preset:"None",brightness:0,contrast:1,saturation:1,sharpness:0,invert:false});void refreshPreview();}}/></View><View class="flex-row flex-wrap gap-1"><Each of={["None","Noir","Mono","Sepia","Chrome","Fade","Instant","Vivid"]}>{preset=><Btn label={preset()} primary={effects().preset===preset()} onPress={()=>changeEffect("preset",preset())}/>}</Each></View><Each of={[{key:"brightness",label:"亮度",min:-1,max:1},{key:"contrast",label:"对比度",min:0,max:4},{key:"saturation",label:"饱和度",min:0,max:4},{key:"sharpness",label:"锐度",min:0,max:4}]}>{item=><OptionSlider label={item().label} value={(effects() as any)[item().key]} min={item().min} max={item().max} step={.01} onChange={value=>changeEffect(item().key,value)}/>}</Each><Setting label={tr("移除背景")} value={effects().removeBackground} onChange={(value:boolean)=>changeEffect("removeBackground",value)}/><Setting label={tr("反色")} value={effects().invert} onChange={(value:boolean)=>changeEffect("invert",value)}/><Btn label={tr("删除所选标注")} disabled={!selected()} danger onPress={remove}/>
    </Scroll>;}
    function OutputBar(){return <View class="h-[54px] px-[14px] flex-row items-center gap-2 border-t border-border bg-sidebar/70"><Text class="text-[10px] text-muted-foreground flex-1" style={{numberOfLines:2}}>{status()||`${Math.round(sceneSize().width)} × ${Math.round(sceneSize().height)} · ${tr("已标注 {0} 处",{"0":annotations().length})} · ⌘Z ${tr("撤销")}`}</Text><Each of={[{id:"pin",icon:"pin",label:"贴图"},{id:"share",icon:"share",label:"分享"},{id:"ocr",icon:"ocr",label:"OCR 与二维码"},{id:"translate",icon:"translate",label:"翻译"}]}>{item=><Btn label={tr(item().label)} disabled={busy()||smartBusy()||!!smartError()||translationBusy()} onPress={()=>{if(item().id==="translate"){translationOpen.set(!translationOpen());inspectorOpen.set(true);}else void deliverImage(item().id);}}/>}</Each><View class="w-px h-5 bg-border mx-1"/><Btn label={tr("复制")} disabled={busy()||smartBusy()||!!smartError()||translationBusy()} onPress={()=>void deliverImage("copy")}/><Btn label={tr("保存")} accessibilityLabel={tr("保存 PNG")} disabled={busy()||smartBusy()||!!smartError()||translationBusy()} onPress={()=>void deliverImage("save")}/><Btn label={tr("完成")} primary disabled={busy()||smartBusy()||!!smartError()||translationBusy()} onPress={()=>void deliverImage("done")}/></View>;}
    const localSelection=()=>p.overlay?{x:p.overlay.selectionRect.x-p.overlay.displayFrame.x,y:p.overlay.selectionRect.y-p.overlay.displayFrame.y,width:p.overlay.selectionRect.width,height:p.overlay.selectionRect.height}:null;
    const floatingWidth=()=>Math.min(1000,viewport().width-24),floatingX=()=>Math.max(12,Math.min(viewport().width-floatingWidth()-12,(localSelection()?.x||0)+(localSelection()?.width||0)/2-floatingWidth()/2));
    const floatingY=()=>{if(sourcePath()!==originalPath)return Math.max(12,viewport().height-118);const rect=localSelection();return rect?rect.y+rect.height+122<viewport().height?rect.y+rect.height+10:Math.max(12,rect.y-116):12;};
    const inspectorPlacement=()=>{const top=floatingY(),above=top-24,below=viewport().height-top-106-24;return above>=below?{top:12,height:Math.max(120,Math.min(620,above))}:{top:top+118,height:Math.max(120,Math.min(620,below))};};
    const canvas=<View class="flex-1"><Canvas accessibilityLabel={tr("标注画布")} class="flex-1" onLayout={event=>viewport.set({width:event.bounds.size.width,height:event.bounds.size.height})} draw={draw} onWheel={event=>{const multiplier=event.deltaMode==="lines"?16:1;if(event.modifiers.platform||event.modifiers.control)zoomAt(event.position,fit()*Math.pow(1.002,-event.delta.y*multiplier));else pan.set({x:pan().x-event.delta.x*multiplier,y:pan().y-event.delta.y*multiplier});}} {...pointer}/><If when={!imageReady()}><View testID="editor-loading" class="absolute inset-0 items-center justify-center"><Text class="text-[12px] text-white">{tr("正在加载图像…")}</Text></View></If></View>;
    return <View class={`flex-1 ${p.overlay?"":"bg-background"}`}>
      <If when={!p.overlay} else={<View class="flex-1">{canvas}<View style={{position:"absolute",left:floatingX(),top:floatingY(),width:floatingWidth()}} class="rounded-xl overflow-hidden border border-border" macos={{backdrop:{material:"popover",blending:"behindWindow",state:"active"}}}><HeaderToolbar/><OutputBar/></View><If when={inspectorOpen()}><View style={{position:"absolute",right:12,top:inspectorPlacement().top,height:inspectorPlacement().height}} class="rounded-xl border border-border overflow-hidden"><Inspector/></View></If></View>}>
        <HeaderToolbar/><View class="flex-1 flex-row min-h-0">{canvas}<Inspector/></View><OutputBar/>
      </If>
    </View>;

}

function drawAnnotation(
    c: CanvasRenderingContext2D,
    a: Annotation,
    imagePath: string,
    imageSize: { width: number; height: number },
    sourceScale: { x: number; y: number } = { x: 1, y: 1 },
) {
    const sample = (
        sx: number,
        sy: number,
        sw: number,
        sh: number,
        dx: number,
        dy: number,
        dw: number,
        dh: number,
    ) =>
        c.drawImage(
            imagePath,
            sx * sourceScale.x,
            sy * sourceScale.y,
            Math.max(0.1, sw * sourceScale.x),
            Math.max(0.1, sh * sourceScale.y),
            dx,
            dy,
            dw,
            dh,
        );
    const points:Point[]=a.tool==="arrow"&&a.arrowFlip?[...a.points].reverse():a.points;
    const first = points[0]!,
        last = points[points.length - 1]!,
        b = bounds(a);
    c.save();
    c.strokeStyle = a.color;
    c.fillStyle = a.color;
    c.lineWidth = a.width;
    c.lineCap = "round";
    c.lineJoin = "round";
    c.globalAlpha = a.opacity;if(a.tool==="highlighter")c.globalCompositeOperation="multiply";
    const dash=a.lineStyle==="dash"?[a.width*3,a.width*2]:a.lineStyle==="dot"?[a.width,a.width*2]:[];c.setLineDash(dash);
    const stroke=()=>{if(a.outline&&a.tool==="arrow"){c.save();c.strokeStyle="#FFFFFF";c.lineWidth=Number(c.lineWidth)+2;c.stroke();c.restore();}c.stroke();};
    const finishShape=()=>{if(a.fillMode==="mixed"||a.fillMode==="fill"){c.save();c.globalAlpha=a.opacity*(a.fillMode==="mixed"?.25:1);c.fill();c.restore();}if(a.fillMode!=="fill")stroke();};
    if(a.tool==="stamp"&&a.imagePath){c.translate(b.x+b.width/2,b.y+b.height/2);c.rotate((a.imageRotation||0)*Math.PI/180);c.drawImage(a.imagePath,-b.width/2,-b.height/2,b.width,b.height);}
    else if (a.tool === "highlighter" && a.filled) {
        c.globalAlpha = a.opacity * 0.35;
        c.fillRect(b.x, b.y, b.width, b.height);
    } else if (a.tool === "mosaic") {
        const tile = Math.max(8, a.width * 4);
        for (let y = b.y; y < b.y + b.height; y += tile)
            for (let x = b.x; x < b.x + b.width; x += tile) {
                const w = Math.min(tile, b.x + b.width - x),
                    h = Math.min(tile, b.y + b.height - y);
                sample(x + w / 2, y + h / 2, 1, 1, x, y, w, h);
            }
    } else if (a.tool === "solid") {
        c.fillRect(b.x, b.y, b.width, b.height);
    } else if (a.tool === "erase") {
        sample(b.x, b.y, b.width, b.height, b.x, b.y, b.width, b.height);
    } else if (a.tool === "blur") {
        c.fillStyle = "#808080";
        c.globalAlpha = 0.4;
        c.fillRect(b.x, b.y, b.width, b.height);
    } else if(a.tool==="spotlight"){c.fillStyle="#000000";c.globalAlpha=a.opacity*(a.spotlightOpacity??.55);c.beginPath();c.rect(0,0,imageSize.width,imageSize.height);c.rect(b.x,b.y,b.width,b.height);c.fill("evenodd");c.globalAlpha=a.opacity;c.strokeRect(b.x,b.y,b.width,b.height);
    }else if(a.tool==="magnifier"){const zoom=Math.max(1.1,a.magnifierZoom||2);c.save();c.beginPath();c.ellipse(b.x+b.width/2,b.y+b.height/2,Math.max(.1,b.width/2),Math.max(.1,b.height/2),0,0,Math.PI*2);c.clip();sample(b.x+b.width*(1-1/zoom)/2,b.y+b.height*(1-1/zoom)/2,b.width/zoom,b.height/zoom,b.x,b.y,b.width,b.height);c.restore();if(a.outline){c.strokeStyle="#FFFFFF";c.lineWidth=a.width;c.beginPath();c.ellipse(b.x+b.width/2,b.y+b.height/2,Math.max(.1,b.width/2),Math.max(.1,b.height/2),0,0,Math.PI*2);stroke();}
    } else if (a.tool === "rectangle") {
        c.beginPath();c.roundRect(b.x,b.y,b.width,b.height,Math.max(0,a.cornerRadius||0));finishShape();
    } else if (a.tool === "ellipse") {
        c.beginPath();
        c.ellipse(
            b.x + b.width / 2,
            b.y + b.height / 2,
            Math.max(0.1, b.width / 2),
            Math.max(0.1, b.height / 2),
            0,
            0,
            Math.PI * 2,
        );
        finishShape();
    } else if (a.tool === "text" || a.tool === "stamp") {
        const family =
            (
                {
                    "PingFangSC-Regular": "PingFang SC",
                    "Menlo-Regular": "Menlo",
                    TimesNewRomanPSMT: "Times New Roman",
                } as Record<string, string>
            )[a.fontFamily || ""] || "sans-serif";
        c.font = `${a.italic ? "italic " : ""}${a.bold ? "600 " : ""}${a.fontSize || 24}px ${family === "sans-serif" ? family : `"${family}"`}`;
        c.textBaseline = "top";
        c.textAlign = (a.align || "left") as any;
        if(a.textBox){const box=a.textBox;c.save();c.fillStyle=a.background||"#FFFFFF";c.fillRect(first.x,first.y,box.width,box.height);c.beginPath();c.rect(first.x,first.y,box.width,box.height);c.clip();const font=(size:number)=>`${a.italic?"italic ":""}${a.bold?"600 ":""}${size}px ${family==="sans-serif"?family:`"${family}"`}`;const layout=textBoxLayout(a.text||"",box.width,box.height,a.fontSize||24,(text,size)=>{c.font=font(size);return c.measureText(text).width;});c.font=font(layout.fontSize);c.fillStyle=a.color;c.textAlign=(a.align||"left") as any;const x=first.x+(a.align==="center"?box.width/2:a.align==="right"?box.width-2:2);layout.lines.forEach((line,index)=>{const y=first.y+2+index*layout.lineHeight;if(a.outline){c.strokeStyle="#FFFFFF";c.lineWidth=2;c.strokeText(line,x,y);}c.fillText(line,x,y);if(a.underline||a.strike){const width=c.measureText(line).width,left=x-(a.align==="center"?width/2:a.align==="right"?width:0);c.strokeStyle=a.color;c.lineWidth=1;c.beginPath();c.moveTo(left,y+layout.fontSize*(a.strike?.5:1.1));c.lineTo(left+width,y+layout.fontSize*(a.strike?.5:1.1));c.stroke();}});c.restore();c.restore();return;}
        const content = a.text || "文字";
        const tw = c.measureText(content).width;
        const x =
            first.x -
            (a.align === "center" ? tw / 2 : a.align === "right" ? tw : 0);
        if (a.background) {
            c.fillStyle = a.background;
            c.fillRect(x - 4, first.y - 2, tw + 8, (a.fontSize || 24) * 1.3);
            c.fillStyle = a.color;
        }
        if(a.outline){c.save();c.strokeStyle="#FFFFFF";c.lineWidth=2;c.strokeText(content,first.x,first.y);c.restore();}
        c.fillText(content, first.x, first.y);
        if (a.underline || a.strike) {
            c.lineWidth = 1;
            c.beginPath();
            const y = first.y + (a.fontSize || 24) * (a.strike ? 0.5 : 1.1);
            c.moveTo(x, y);
            c.lineTo(x + tw, y);
            stroke();
        }
    } else if (a.tool === "number") {
        const radius = Math.max(14, a.width * 4);
        c.beginPath();
        c.arc(first.x, first.y, radius, 0, Math.PI * 2);
        c.fill();
        c.fillStyle = "#FFFFFF";
        c.font = `600 ${radius * 1.2}px sans-serif`;
        c.textAlign = "center";
        c.textBaseline = "middle";
        c.fillText(formattedNumber(a.number||a.numberStart||1,a.numberFormat||"decimal"),first.x,first.y,radius*1.8);
    } else {
        if (a.tool === "highlighter") {
            c.globalAlpha = a.opacity * 0.35;
            c.lineWidth = Math.max(12, a.width * 5);
        }
        if (a.arrowStyle === "dash") c.setLineDash([a.width * 3, a.width * 2]);
        if (
            (a.tool === "pen" || a.tool === "highlighter") &&
            points.some((point) => point.pressure !== undefined)
        ) {
            const base =
                a.tool === "highlighter" ? Math.max(12, a.width * 5) : a.width;
            for (let index = 1; index < points.length; index++) {
                const prev = points[index - 1]!,
                    next = points[index]!;
                c.lineWidth = Math.max(
                    0.1,
                    (base * ((prev.pressure ?? 1) + (next.pressure ?? 1))) / 2,
                );
                c.beginPath();
                c.moveTo(prev.x, prev.y);
                c.lineTo(next.x, next.y);
                stroke();
            }
        } else {
            c.beginPath();
            c.moveTo(first.x, first.y);
            if (a.tool === "arrow" && a.arrowStyle === "curve")
                c.quadraticCurveTo(
                    (first.x + last.x) / 2 - (last.y - first.y) * 0.2,
                    (first.y + last.y) / 2 + (last.x - first.x) * 0.2,
                    last.x,
                    last.y,
                );
            else for (const p of points.slice(1)) c.lineTo(p.x, p.y);
            stroke();
            c.setLineDash(dash);
        }
        if (a.tool === "measure") {
            c.font = "16px sans-serif";
            c.fillText(
                `${Math.round(Math.hypot(last.x-first.x,last.y-first.y)/(a.measureUnit==="pt"?Math.max(.1,a.imageScale||1):1))} ${a.measureUnit||"px"}`,
                (first.x + last.x) / 2,
                (first.y + last.y) / 2 - 8,
            );
        }
        if (a.tool === "arrow") {
            const h = arrowHead(first, last, a.width);
            c.beginPath();
            c.moveTo(h[0]!.x, h[0]!.y);
            c.lineTo(h[1]!.x, h[1]!.y);
            c.lineTo(h[2]!.x, h[2]!.y);
            stroke();
            if (a.arrowStyle === "double") {
                const rev = arrowHead(last, first, a.width);
                c.beginPath();
                c.moveTo(rev[0]!.x, rev[0]!.y);
                c.lineTo(first.x, first.y);
                c.lineTo(rev[2]!.x, rev[2]!.y);
                stroke();
            }
            if (a.arrowStyle === "bar") {
                const angle =
                        Math.atan2(last.y - first.y, last.x - first.x) +
                        Math.PI / 2,
                    size = Math.max(8, a.width * 3);
                c.beginPath();
                c.moveTo(
                    last.x - Math.cos(angle) * size,
                    last.y - Math.sin(angle) * size,
                );
                c.lineTo(
                    last.x + Math.cos(angle) * size,
                    last.y + Math.sin(angle) * size,
                );
                stroke();
            }
        }
    }
    c.restore();
}

function formattedNumber(value:number,style:string){const number=Math.max(1,Math.round(value));if(style==="roman"){let rest=number,result="";for(const [unit,glyph]of [[1000,"M"],[900,"CM"],[500,"D"],[400,"CD"],[100,"C"],[90,"XC"],[50,"L"],[40,"XL"],[10,"X"],[9,"IX"],[5,"V"],[4,"IV"],[1,"I"]] as [number,string][]){while(rest>=unit){result+=glyph;rest-=unit;}}return result;}if(style==="upper"||style==="lower"){let rest=number,result="";while(rest>0){rest--;result=String.fromCharCode(65+rest%26)+result;rest=Math.floor(rest/26);}return style==="lower"?result.toLowerCase():result;}return String(number);}
