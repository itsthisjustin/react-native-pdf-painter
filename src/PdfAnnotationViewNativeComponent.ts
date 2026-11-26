import { codegenNativeComponent } from 'react-native';
import type { CodegenTypes, HostComponent, ViewProps } from 'react-native';
import React from 'react';
import { codegenNativeCommands } from 'react-native';

export type BrushType =
    'marker' | 'pressure-pen' | 'highlighter' | 'eraser' | 'link' | 'none';

export interface BrushSettings {
    type?: CodegenTypes.WithDefault<BrushType, 'marker'>;
    color: string;
    size: CodegenTypes.Float;
    lineal?: boolean;
}

export type PageCountEvent = {
    pageCount: CodegenTypes.Int32;
};

export type PageChangeEvent = {
    currentPage: CodegenTypes.Int32;
};

export type DocumentFinishedEvent = {
    next: boolean;
};
export type TapEvent = {
    x: CodegenTypes.Double;
    y: CodegenTypes.Double;
};
export type PageRectEvent = {
    x: CodegenTypes.Double;
    y: CodegenTypes.Double;
    width: CodegenTypes.Double;
    height: CodegenTypes.Double;
};
export type LinkCompletedEvent = {
    fromPage: CodegenTypes.Int32;
    toPage: CodegenTypes.Int32;
};

export interface NativeProps extends ViewProps {
    backgroundColor?: string;
    pdfUrl?: string;
    canvasMode?: boolean;
    drawWithFinger?: boolean;
    /**
     * iOS only. Keeps PencilKit markup active even while the tool picker is
     * hidden, so the Apple Pencil can always draw (with palm rejection).
     * Also disables tap-edge page navigation. Finger touches keep driving
     * the PDF view's internal gestures (scroll, zoom, page swipe) unless
     * iosFingerPassthrough is also set.
     */
    iosPencilAlwaysDraws?: boolean;
    /**
     * iOS only. Requires iosPencilAlwaysDraws. Restricts the PDF view's
     * internal gestures to pencil touches so finger input passes through to
     * ancestor views (e.g. React Native pan/zoom handlers behind a
     * background PDF). Without it, fingers pan/zoom/page-swipe the PDF
     * itself while the pencil draws.
     */
    iosFingerPassthrough?: boolean;
    /**
     * iOS only. Renders the canvas in dark appearance so PencilKit's dynamic
     * ink inverts (black strokes render white). Use for drawing surfaces that
     * follow the app theme — NOT for PDFs/images where ink should stay
     * literal (the default light appearance).
     */
    iosDarkInk?: boolean;
    /**
     * iOS only. The page fills the view edge to edge (no page margins): it is
     * scaled to cover the view, so the reader scrolls along the longer side and
     * can zoom in but never out past full bleed. For reading a document like a
     * book. Without it the whole page is fitted inside the view.
     */
    iosFillView?: boolean;
    /**
     * iOS only, default false. "Draw and hold" shape recognition: finish a
     * stroke with the pen resting at its end (about half a second) and, if it
     * clearly is a straight line, arrow, circle/ellipse, rectangle or
     * triangle, it is replaced by a clean version in the same ink. Undo
     * brings back the hand-drawn stroke. Small marks and anything not
     * confidently recognised are left exactly as drawn; highlighter strokes
     * only ever snap to straight lines.
     */
    iosShapeRecognition?: boolean;
    /**
     * iOS only, default false. Handwriting clean-up: a light smoothing of
     * each finished pen stroke that removes jitter and evens out width
     * wobble while keeping endpoints, corners and the writer's hand.
     * Highlighter strokes and recognised shapes are not smoothed.
     */
    iosSmoothStrokes?: boolean;
    thumbnailMode?: boolean;
    pageNavigationEnabled?: boolean;
    annotationFile?: string;
    autoSave?: boolean;
    brushSettings?: BrushSettings;
    iosToolPickerVisible?: boolean;
    onPageCount?: CodegenTypes.BubblingEventHandler<PageCountEvent> | null;
    onPageChange?: CodegenTypes.BubblingEventHandler<PageChangeEvent> | null;
    onDocumentFinished?: CodegenTypes.BubblingEventHandler<DocumentFinishedEvent> | null;
    onTap?: CodegenTypes.BubblingEventHandler<TapEvent> | null;
    onLinkCompleted?: CodegenTypes.BubblingEventHandler<LinkCompletedEvent> | null;
    /** iOS only. Where the current page is drawn, in this view's coordinates
        (excludes PDFKit's page margins). Fires on layout, page and zoom changes. */
    onPageRect?: CodegenTypes.BubblingEventHandler<PageRectEvent> | null;
    androidBeyondViewportPageCount?: CodegenTypes.Int32;
}

type ComponentType = HostComponent<NativeProps>;

export default codegenNativeComponent<NativeProps>(
    'PdfAnnotationView'
) as ComponentType;

interface NativeCommands {
    saveAnnotations: (
        viewRef: React.ElementRef<ComponentType>,
        path: string
    ) => void;
    loadAnnotations: (
        viewRef: React.ElementRef<ComponentType>,
        path: string
    ) => void;
    undo: (viewRef: React.ElementRef<ComponentType>) => void;
    redo: (viewRef: React.ElementRef<ComponentType>) => void;
    clear: (viewRef: React.ElementRef<ComponentType>) => void;
    setPage: (
        viewRef: React.ElementRef<ComponentType>,
        page: CodegenTypes.Int32
    ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
    supportedCommands: [
        'saveAnnotations',
        'loadAnnotations',
        'undo',
        'redo',
        'clear',
        'setPage',
    ],
});
