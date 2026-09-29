import Foundation

/// Uses the same persisted app-language value as PreferencesManager without
/// depending on screenshot code or the application's localization table.
enum NativeScreenshotText {
    enum Key {
        case editorTitle, selectMove, toolPicker, annotationColor, lineWidth, textOrEmoji
        case undo, redo, done, cancel, annotate, record, scroll, actions, processImage
        case ocr, qrCode, autoRedact, pin, save
        case pencil, line, arrow, rectangle, filledRectangle, ellipse, highlighter
        case richText, number, stamp, pixelate, blur, solidCensor, eraseCensor
        case magnifier, ruler, colorSampler, spotlight
        case imageEdits, chooseCrop, applyCrop, flipHorizontal, flipVertical
        case transform, beautify, imageEffects, arrowStyle, smoothing, pressure
        case bold, italic, underline, outline, font, textBackground, fontSize, importImage, useEmoji
        case smartMarker, pixelBlock, blurRadius, magnifierZoom, shrink, enlarge
        case deleteSelected, editText, apply, scalePercent, rotateDegrees
        case margin, cornerRadius, shadow, windowMode, roundedMode
        case brightness, contrast, saturation, sharpness
        case noSelection, invalidTransform
        case processingImage
        case previewUnavailable
        case unsavedChanges, discardChangesExplanation, keepEditing, discardChanges
        case largeImageUndoWarning
        case arrowSolid, arrowDashed, arrowCurved, arrowCurvedDashed
        case arrowSketch, arrowDoubleHeaded
        case smoothingNone, smoothingSmooth, smoothingRefined
        case pixelDimensions, appendImage, appendBelow, appendRight
        case zoom50, zoom100, zoom200, zoomFit

        var words: (zh: String, en: String) {
            switch self {
            case .editorTitle: return ("截图标注", "Screenshot Annotation")
            case .selectMove: return ("选择 / 移动", "Select / Move")
            case .toolPicker: return ("标注工具", "Annotation Tool")
            case .annotationColor: return ("标注颜色", "Annotation Color")
            case .lineWidth: return ("线宽", "Line Width")
            case .textOrEmoji: return ("文字 / emoji", "Text / emoji")
            case .undo: return ("撤销", "Undo")
            case .redo: return ("重做", "Redo")
            case .done: return ("完成", "Done")
            case .cancel: return ("取消", "Cancel")
            case .annotate: return ("标注", "Annotate")
            case .record: return ("录屏", "Record")
            case .scroll: return ("长截图", "Scroll")
            case .actions: return ("操作…", "Actions…")
            case .processImage: return ("处理当前标注图片", "Process Annotated Image")
            case .ocr: return ("OCR", "OCR")
            case .qrCode: return ("二维码", "QR Code")
            case .autoRedact: return ("自动遮挡", "Auto Redact")
            case .pin: return ("贴图", "Pin")
            case .save: return ("保存", "Save")
            case .pencil: return ("画笔", "Pencil")
            case .line: return ("直线", "Line")
            case .arrow: return ("箭头", "Arrow")
            case .rectangle: return ("矩形", "Rectangle")
            case .filledRectangle: return ("填充矩形", "Filled Rectangle")
            case .ellipse: return ("椭圆", "Ellipse")
            case .highlighter: return ("荧光笔", "Highlighter")
            case .richText: return ("文字", "Text")
            case .number: return ("编号", "Number")
            case .stamp: return ("图章", "Stamp")
            case .pixelate: return ("马赛克", "Pixelate")
            case .blur: return ("模糊", "Blur")
            case .solidCensor: return ("纯色遮挡", "Solid Redaction")
            case .eraseCensor: return ("擦除遮挡", "Erase Redaction")
            case .magnifier: return ("放大镜", "Magnifier")
            case .ruler: return ("像素标尺", "Pixel Ruler")
            case .colorSampler: return ("取色器", "Color Sampler")
            case .spotlight: return ("聚光灯", "Spotlight")
            case .imageEdits: return ("图像编辑…", "Image edits…")
            case .chooseCrop: return ("框选裁剪区域", "Select crop area")
            case .applyCrop: return ("应用裁剪", "Apply crop")
            case .flipHorizontal: return ("水平翻转", "Flip horizontally")
            case .flipVertical: return ("垂直翻转", "Flip vertically")
            case .transform: return ("缩放 / 旋转…", "Scale / Rotate…")
            case .beautify: return ("美化包裹…", "Beautify wrap…")
            case .imageEffects: return ("亮度与特效…", "Color & effects…")
            case .arrowStyle: return ("箭头样式", "Arrow style")
            case .smoothing: return ("平滑", "Smoothing")
            case .pressure: return ("压感", "Pressure")
            case .bold: return ("粗体", "Bold")
            case .italic: return ("斜体", "Italic")
            case .underline: return ("下划线", "Underline")
            case .outline: return ("描边", "Outline")
            case .font: return ("字体…", "Font…")
            case .textBackground: return ("文字背景", "Text background")
            case .fontSize: return ("字号", "Font size")
            case .importImage: return ("导入图片图章…", "Import image stamp…")
            case .useEmoji: return ("使用 emoji", "Use emoji")
            case .smartMarker: return ("匹配文字行高", "Fit text line height")
            case .pixelBlock: return ("马赛克强度", "Mosaic strength")
            case .blurRadius: return ("模糊强度", "Blur strength")
            case .magnifierZoom: return ("放大倍率", "Magnifier zoom")
            case .shrink: return ("缩小", "Shrink")
            case .enlarge: return ("放大", "Enlarge")
            case .deleteSelected: return ("删除所选", "Delete selected")
            case .editText: return ("编辑文字…", "Edit text…")
            case .apply: return ("应用", "Apply")
            case .scalePercent: return ("缩放百分比", "Scale percent")
            case .rotateDegrees: return ("顺时针角度", "Clockwise degrees")
            case .margin: return ("边距", "Margin")
            case .cornerRadius: return ("圆角", "Corner radius")
            case .shadow: return ("阴影", "Shadow")
            case .windowMode: return ("窗口", "Window")
            case .roundedMode: return ("圆角图片", "Rounded image")
            case .brightness: return ("亮度", "Brightness")
            case .contrast: return ("对比度", "Contrast")
            case .saturation: return ("饱和度", "Saturation")
            case .sharpness: return ("锐度", "Sharpness")
            case .noSelection: return ("请先选择标注或裁剪区域", "Select an annotation or crop area first")
            case .invalidTransform: return ("缩放或旋转数值无效", "Invalid scale or rotation value")
            case .processingImage: return ("正在处理图片…", "Processing image…")
            case .previewUnavailable: return ("预览不可用，请尝试保存图片", "Preview unavailable; try saving the image")
            case .unsavedChanges: return ("有未保存的更改", "Unsaved changes")
            case .discardChangesExplanation: return (
                "退出会丢弃当前标注和图像修改。", "Closing will discard the current annotations and image edits.")
            case .keepEditing: return ("继续编辑", "Keep Editing")
            case .discardChanges: return ("放弃更改", "Discard Changes")
            case .largeImageUndoWarning: return (
                "图片过大，无法在内存预算内保留变换前版本。继续后此图像变换不可撤销。",
                "This image is too large to retain an undo copy within the memory budget. This image transform cannot be undone if you continue.")
            case .arrowSolid: return ("实线", "Solid")
            case .arrowDashed: return ("虚线", "Dashed")
            case .arrowCurved: return ("弯曲", "Curved")
            case .arrowCurvedDashed: return ("弯曲虚线", "Curved dashed")
            case .arrowSketch: return ("手绘", "Sketch")
            case .arrowDoubleHeaded: return ("双向", "Double headed")
            case .smoothingNone: return ("无", "None")
            case .smoothingSmooth: return ("平滑", "Smooth")
            case .smoothingRefined: return ("精细", "Refined")
            case .pixelDimensions: return ("图像像素尺寸", "Image pixel dimensions")
            case .appendImage: return ("追加图片…", "Append image…")
            case .appendBelow: return ("追加到下方", "Append below")
            case .appendRight: return ("追加到右侧", "Append to right")
            case .zoom50: return ("50%", "50%")
            case .zoom100: return ("100%", "100%")
            case .zoom200: return ("200%", "200%")
            case .zoomFit: return ("适合窗口", "Fit")
            }
        }
    }

    static func get(_ key: Key) -> String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        let chinese = raw == "zh" || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        return chinese ? key.words.zh : key.words.en
    }
}
