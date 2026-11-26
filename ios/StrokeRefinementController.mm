#import "StrokeRefinementController.h"
#import "StrokeRefiner.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace StrokeRefiner;

// --- Hold-to-snap ----------------------------------------------------------
// The pen counts as resting while the path stays within this distance (screen
// points) of where it was lifted...
static const double kHoldRadiusPt = 2.5;
// ...and a rest at least this long (seconds) asks for shape recognition.
static const double kHoldMinDuration = 0.45;

// --- Sampling --------------------------------------------------------------
// Spacing (screen points) at which a stroke is sampled for classification
// and smoothing, and of the control points of a smoothed stroke.
static const double kSampleSpacingPt = 1.25;
// Spacing (screen points) of the control points along a clean shape.
static const double kShapeSpacingPt = 3.0;
// Time step (seconds) used to look for the trailing hold.
static const double kHoldTimeStep = 1.0 / 60.0;
// Strokes that sample to more points than this are left alone.
static const size_t kMaxSamples = 8000;

// A smoothed stroke that differs from the original by less than this is not
// worth replacing (screen points / relative width change).
static const double kSmoothMinShiftPt = 0.05;
static const double kSmoothMinWidthChange = 0.02;

// A new stroke that begins within this long (seconds) of the previous one
// ending may arrive before the previous one's drawing change (see
// canvasViewDidBeginUsingTool:).
static const CFTimeInterval kPendingChangeWindow = 0.5;

// What is known about one canvas between delegate callbacks.
@interface StrokeRefinementCanvasState : NSObject
// Strokes begun whose drawing change has not been seen yet.
@property (nonatomic, assign) NSInteger pendingStrokes;
// A stroke is being drawn right now.
@property (nonatomic, assign) BOOL strokeInProgress;
// Stroke count after the last drawing change that was looked at.
@property (nonatomic, assign) NSUInteger knownStrokeCount;
@property (nonatomic, assign) CFTimeInterval lastStrokeEnd;
@end

@implementation StrokeRefinementCanvasState
@end

static Sample SRSampleFromPoint(PKStrokePoint *point) {
    Sample s;
    s.x = point.location.x;
    s.y = point.location.y;
    s.t = point.timeOffset;
    s.w = point.size.width;
    s.h = point.size.height;
    s.opacity = point.opacity;
    s.force = point.force;
    s.azimuth = point.azimuth;
    s.altitude = point.altitude;
    if (@available(iOS 17.0, *)) s.secondaryScale = point.secondaryScale;
    if (@available(iOS 26.0, *)) s.threshold = point.threshold;
    if (@available(iOS 27.0, *)) s.lateralJitter = point.lateralJitter;
    return s;
}

static PKStrokePoint *SRPointFromSample(const Sample &s) {
    CGPoint location = CGPointMake(s.x, s.y);
    CGSize size = CGSizeMake(s.w, s.h);
    if (@available(iOS 27.0, *)) {
        return [[PKStrokePoint alloc] initWithLocation:location timeOffset:s.t size:size opacity:s.opacity
                                                 force:s.force azimuth:s.azimuth altitude:s.altitude
                                        secondaryScale:s.secondaryScale threshold:s.threshold
                                         lateralJitter:s.lateralJitter];
    }
    if (@available(iOS 26.0, *)) {
        return [[PKStrokePoint alloc] initWithLocation:location timeOffset:s.t size:size opacity:s.opacity
                                                 force:s.force azimuth:s.azimuth altitude:s.altitude
                                        secondaryScale:s.secondaryScale threshold:s.threshold];
    }
    if (@available(iOS 17.0, *)) {
        return [[PKStrokePoint alloc] initWithLocation:location timeOffset:s.t size:size opacity:s.opacity
                                                 force:s.force azimuth:s.azimuth altitude:s.altitude
                                        secondaryScale:s.secondaryScale];
    }
    return [[PKStrokePoint alloc] initWithLocation:location timeOffset:s.t size:size opacity:s.opacity
                                             force:s.force azimuth:s.azimuth altitude:s.altitude];
}

static Sample SRLerp(const Sample &a, const Sample &b, double f) {
    Sample s = a;
    s.x = a.x + (b.x - a.x) * f;
    s.y = a.y + (b.y - a.y) * f;
    s.t = a.t + (b.t - a.t) * f;
    s.w = a.w + (b.w - a.w) * f;
    s.h = a.h + (b.h - a.h) * f;
    s.opacity = a.opacity + (b.opacity - a.opacity) * f;
    s.force = a.force + (b.force - a.force) * f;
    return s;
}

static double SRMedian(std::vector<double> values) {
    if (values.empty()) return 0;
    std::nth_element(values.begin(), values.begin() + values.size() / 2, values.end());
    return values[values.size() / 2];
}

// Two PKStroke objects describing the same stroke. PKCanvasView hands out
// fresh wrappers every time its drawing is read, so identity will not do.
static BOOL SRSameStroke(PKStroke *a, PKStroke *b) {
    if (!a || !b) return NO;
    return a.path.count == b.path.count
        && [a.path.creationDate isEqualToDate:b.path.creationDate]
        && CGRectEqualToRect(a.renderBounds, b.renderBounds);
}

@implementation StrokeRefinementController {
    NSMapTable<PKCanvasView *, StrokeRefinementCanvasState *> *_states;
    // Undo managers holding actions that target this controller.
    NSHashTable<NSUndoManager *> *_undoManagers;
    BOOL _applying;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _states = [NSMapTable weakToStrongObjectsMapTable];
        _undoManagers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)dealloc {
    // NSUndoManager does not retain its targets.
    for (NSUndoManager *undoManager in _undoManagers) {
        [undoManager removeAllActionsWithTarget:self];
    }
}

- (BOOL)isApplyingRefinement {
    return _applying;
}

- (BOOL)enabled {
    return self.shapeRecognitionEnabled || self.smoothStrokesEnabled;
}

- (StrokeRefinementCanvasState *)stateForCanvas:(PKCanvasView *)canvasView {
    StrokeRefinementCanvasState *state = [_states objectForKey:canvasView];
    if (!state) {
        state = [[StrokeRefinementCanvasState alloc] init];
        [_states setObject:state forKey:canvasView];
    }
    return state;
}

#pragma mark - Telling a freshly drawn stroke from every other change

// canvasViewDrawingDidChange: fires for everything: a finished stroke, the
// eraser, undo/redo, lasso moves and programmatic assignment. Only the first
// is refined. A change is a stroke the user just drew when a tool was put
// down since the last change, the inking tool is selected, and the drawing
// has exactly one stroke more than it had before.

- (void)canvasViewDidBeginUsingTool:(PKCanvasView *)canvasView {
    if (![self enabled]) return;
    StrokeRefinementCanvasState *state = [self stateForCanvas:canvasView];
    // Normally nothing is pending here and the stroke count is re-read, which
    // also absorbs drawings loaded with the delegate detached. When writing
    // quickly the next stroke can begin before the previous one's drawing
    // change arrives; then the count must be left alone.
    BOOL previousChangePending = state.pendingStrokes > 0
        && (state.strokeInProgress || CACurrentMediaTime() - state.lastStrokeEnd < kPendingChangeWindow);
    if (!previousChangePending) {
        state.pendingStrokes = 0;
        state.knownStrokeCount = canvasView.drawing.strokes.count;
    }
    state.pendingStrokes += 1;
    state.strokeInProgress = YES;
}

- (void)canvasViewDidEndUsingTool:(PKCanvasView *)canvasView {
    if (![self enabled]) return;
    StrokeRefinementCanvasState *state = [self stateForCanvas:canvasView];
    state.strokeInProgress = NO;
    state.lastStrokeEnd = CACurrentMediaTime();
}

- (BOOL)canvasViewDrawingDidChange:(PKCanvasView *)canvasView {
    if (_applying) return NO;
    if (![self enabled]) {
        [_states removeObjectForKey:canvasView];
        return NO;
    }
    StrokeRefinementCanvasState *state = [self stateForCanvas:canvasView];
    NSArray<PKStroke *> *strokes = canvasView.drawing.strokes;
    NSUInteger previousCount = state.knownStrokeCount;
    state.knownStrokeCount = strokes.count;

    BOOL isNewStroke = state.pendingStrokes > 0
        && strokes.count == previousCount + 1
        && [canvasView.tool isKindOfClass:[PKInkingTool class]];
    // The user is already drawing the next stroke: replacing the drawing
    // now could disturb it, so this one stays as drawn.
    BOOL nextStrokeUnderway = state.strokeInProgress && state.pendingStrokes >= 2;
    state.pendingStrokes = nextStrokeUnderway ? 1 : 0;
    if (!isNewStroke || nextStrokeUnderway) return NO;

    return [self refineStroke:strokes.lastObject inCanvas:canvasView];
}

#pragma mark - Refinement

// Length, in the stroke's own coordinates, of one point on screen. The
// canvas may be zoomed (PDF pages) or scaled by an ancestor transform (React
// Native pans and zooms the free canvas), and the stroke carries a transform.
- (double)unitForStroke:(PKStroke *)stroke inCanvas:(PKCanvasView *)canvasView {
    double screenPerUnit = canvasView.zoomScale;
    if (canvasView.window) {
        CGRect onScreen = [canvasView convertRect:CGRectMake(0, 0, 100, 100) toView:nil];
        screenPerUnit *= std::sqrt(std::fabs(onScreen.size.width * onScreen.size.height)) / 100.0;
    }
    CGAffineTransform t = stroke.transform;
    screenPerUnit *= std::sqrt(std::fabs(t.a * t.d - t.b * t.c));
    if (!std::isfinite(screenPerUnit) || screenPerUnit <= 0) return 1.0;
    return std::max(0.05, std::min(20.0, 1.0 / screenPerUnit));
}

- (BOOL)refineStroke:(PKStroke *)stroke inCanvas:(PKCanvasView *)canvasView {
    PKStrokePath *path = stroke.path;
    // Partly erased strokes carry a mask; a stroke fresh from the pen has none.
    if (!stroke || stroke.mask != nil || path.count < 2) return NO;
    BOOL isHighlighter = [stroke.ink.inkType isEqualToString:PKInkTypeMarker];
    double unit = [self unitForStroke:stroke inCanvas:canvasView];
    PKFloatRange *whole = [[PKFloatRange alloc] initWithLowerBound:0 upperBound:path.count - 1];

    // The stroke at an even spacing: input to both classifier and smoother.
    __block std::vector<Sample> samples;
    __block BOOL tooLong = NO;
    [path enumerateInterpolatedPointsInRange:whole
                            strideByDistance:kSampleSpacingPt * unit
                                  usingBlock:^(PKStrokePoint *point, BOOL *stop) {
        if (samples.size() >= kMaxSamples) { tooLong = YES; *stop = YES; return; }
        samples.push_back(SRSampleFromPoint(point));
    }];
    if (tooLong || samples.empty()) return NO;
    // Make sure the very end of the stroke is there: striding by distance
    // stops short of it unless the length happens to divide evenly.
    Sample end = SRSampleFromPoint([path interpolatedPointAt:path.count - 1]);
    double tail = std::hypot(end.x - samples.back().x, end.y - samples.back().y);
    if (tail > 0.25 * kSampleSpacingPt * unit || samples.size() < 2) {
        samples.push_back(end);
    } else {
        samples.back() = end;
    }

    if (self.shapeRecognitionEnabled) {
        PKStroke *shapeStroke = [self shapeStrokeForStroke:stroke samples:samples unit:unit linesOnly:isHighlighter];
        if (shapeStroke) {
            // Swap the shape in on the next run-loop turn. By then PencilKit's
            // own undo registration for the hand-drawn stroke is closed, so
            // the swap is an undo step of its own: one Undo brings back the
            // hand-drawn stroke, a second removes it (as Notes does).
            __weak StrokeRefinementController *weakSelf = self;
            __weak PKCanvasView *weakCanvas = canvasView;
            dispatch_async(dispatch_get_main_queue(), ^{
                StrokeRefinementController *strongSelf = weakSelf;
                PKCanvasView *canvas = weakCanvas;
                if (!strongSelf || !canvas || !strongSelf.shapeRecognitionEnabled) return;
                [strongSelf replaceLastStroke:stroke with:shapeStroke inCanvas:canvas isCleanUp:NO];
            });
            return NO;
        }
    }

    // Highlighter strokes are never smoothed.
    if (self.smoothStrokesEnabled && !isHighlighter) {
        SmoothResult smoothed = smoothStroke(samples, unit);
        if (smoothed.maxShift < kSmoothMinShiftPt * unit && smoothed.maxWidthChange < kSmoothMinWidthChange) {
            return NO;
        }
        PKStroke *cleanStroke = [self strokeLike:stroke withSamples:smoothed.samples];
        _applying = YES;
        BOOL replaced = [self replaceLastStroke:stroke with:cleanStroke inCanvas:canvasView isCleanUp:YES];
        _applying = NO;
        return replaced;
    }
    return NO;
}

// The clean shape for a stroke that ended with the pen held still, or nil.
- (nullable PKStroke *)shapeStrokeForStroke:(PKStroke *)stroke
                                    samples:(const std::vector<Sample> &)samples
                                       unit:(double)unit
                                  linesOnly:(BOOL)linesOnly {
    // Look for the hold on an even time base: a pen at rest still produces
    // samples (or at least a final one when it lifts), so the time between
    // arriving at the resting spot and lifting is on the path.
    PKStrokePath *path = stroke.path;
    PKFloatRange *whole = [[PKFloatRange alloc] initWithLowerBound:0 upperBound:path.count - 1];
    __block std::vector<Sample> timed;
    [path enumerateInterpolatedPointsInRange:whole
                                strideByTime:kHoldTimeStep
                                  usingBlock:^(PKStrokePoint *point, BOOL *stop) {
        if (timed.size() >= kMaxSamples) { *stop = YES; return; }
        timed.push_back(SRSampleFromPoint(point));
    }];
    if (timed.size() >= kMaxSamples) return nil;
    if (timed.size() < 2) {
        // No usable time base: fall back to the recorded control points.
        timed.clear();
        for (NSUInteger i = 0; i < path.count; i++) timed.push_back(SRSampleFromPoint([path pointAtIndex:i]));
    }
    timed.push_back(SRSampleFromPoint([path interpolatedPointAt:path.count - 1]));
    for (size_t i = 1; i < timed.size(); i++) {
        if (timed[i].t < timed[i - 1].t) return nil;   // not a time-ordered stroke
    }

    Hold hold = trailingHold(timed, kHoldRadiusPt * unit);
    if (hold.duration < kHoldMinDuration) return nil;

    // Classify what was drawn before the pen came to rest.
    Shape shape = recognizeShape(pointsBefore(samples, hold.startTime), unit, linesOnly);
    if (shape.kind == ShapeKind::None) return nil;
    std::vector<Vec> outline = shapeOutline(shape, kShapeSpacingPt * unit);
    if (outline.size() < 2) return nil;

    // One even width for the whole shape: the stroke's median, so it looks
    // like the same pen at the same pressure.
    std::vector<double> widths, heights, opacities, forces, altitudes;
    for (const Sample &s : samples) {
        widths.push_back(s.w);
        heights.push_back(s.h);
        opacities.push_back(s.opacity);
        forces.push_back(s.force);
        altitudes.push_back(s.altitude);
    }
    Sample base = samples[samples.size() / 2];   // azimuth and the newer attributes
    base.w = SRMedian(widths);
    base.h = SRMedian(heights);
    base.opacity = SRMedian(opacities);
    base.force = SRMedian(forces);
    base.altitude = SRMedian(altitudes);

    double duration = std::max(0.05, hold.startTime);
    std::vector<Sample> shapeSamples;
    shapeSamples.reserve(outline.size());
    for (size_t i = 0; i < outline.size(); i++) {
        Sample s = base;
        s.x = outline[i].x;
        s.y = outline[i].y;
        s.t = duration * i / (outline.size() - 1);
        shapeSamples.push_back(s);
    }
    return [self strokeLike:stroke withControlSamples:shapeSamples];
}

// A stroke with the original's ink, transform, texture seed and creation
// date, whose path runs through `samples` (points on the wanted curve).
- (PKStroke *)strokeLike:(PKStroke *)stroke withSamples:(const std::vector<Sample> &)samples {
    // Two extra control points tucked against each end keep the rebuilt
    // spline reaching the stroke's true ends, so strokes never get shorter.
    std::vector<Sample> controls;
    controls.reserve(samples.size() + 4);
    size_t n = samples.size();
    controls.push_back(samples[0]);
    if (n >= 2) {
        controls.push_back(SRLerp(samples[0], samples[1], 0.08));
        controls.push_back(SRLerp(samples[0], samples[1], 0.40));
        for (size_t i = 1; i + 1 < n; i++) controls.push_back(samples[i]);
        controls.push_back(SRLerp(samples[n - 1], samples[n - 2], 0.40));
        controls.push_back(SRLerp(samples[n - 1], samples[n - 2], 0.08));
        controls.push_back(samples[n - 1]);
    }
    return [self strokeLike:stroke withControlSamples:controls];
}

- (PKStroke *)strokeLike:(PKStroke *)stroke withControlSamples:(const std::vector<Sample> &)controls {
    NSMutableArray<PKStrokePoint *> *points = [NSMutableArray arrayWithCapacity:controls.size()];
    for (const Sample &s : controls) [points addObject:SRPointFromSample(s)];
    PKStrokePath *path = [[PKStrokePath alloc] initWithControlPoints:points creationDate:stroke.path.creationDate];
    if (@available(iOS 16.0, *)) {
        return [[PKStroke alloc] initWithInk:stroke.ink strokePath:path transform:stroke.transform mask:nil
                                  randomSeed:stroke.randomSeed];
    }
    return [[PKStroke alloc] initWithInk:stroke.ink strokePath:path transform:stroke.transform mask:nil];
}

#pragma mark - Replacing the stroke, undoably

// Replaces the canvas's last stroke, `from`, with `to` — but only if `from`
// really is still the last stroke. That check is what makes the registered
// undo/redo actions safe to run at any later time: if the drawing has since
// been cleared, reloaded or edited, they do nothing instead of resurrecting
// stale ink.
//
// Undo behaviour:
//   Shape (isCleanUp NO)   The swap is its own undo step. Undo puts the
//                          hand-drawn stroke back, Redo the shape.
//   Clean-up (isCleanUp YES) The user should not need two Undos per stroke,
//                          so undoing the clean-up also undoes the stroke
//                          itself: either both sit in one undo group already
//                          (registered during the same event), or the stroke
//                          is undone right after. Redo brings back the
//                          stroke as it was drawn.
- (BOOL)replaceLastStroke:(PKStroke *)from with:(PKStroke *)to inCanvas:(PKCanvasView *)canvasView isCleanUp:(BOOL)isCleanUp {
    NSArray<PKStroke *> *strokes = canvasView.drawing.strokes;
    if (!SRSameStroke(strokes.lastObject, from)) return NO;
    NSMutableArray<PKStroke *> *replaced = [strokes mutableCopy];
    replaced[replaced.count - 1] = to;

    NSUndoManager *undoManager = canvasView.undoManager;
    BOOL undoingCleanUp = isCleanUp && undoManager.isUndoing;
    if (undoManager && !undoingCleanUp) {
        [_undoManagers addObject:undoManager];
        __weak PKCanvasView *weakCanvas = canvasView;
        [undoManager registerUndoWithTarget:self handler:^(StrokeRefinementController *target) {
            PKCanvasView *canvas = weakCanvas;
            if (canvas) [target replaceLastStroke:to with:from inCanvas:canvas isCleanUp:isCleanUp];
        }];
    }

    canvasView.drawing = [[PKDrawing alloc] initWithStrokes:replaced];
    // The assignment reaches the delegate as an ordinary drawing change;
    // keep the stroke count in step in case it was suppressed.
    StrokeRefinementCanvasState *state = [_states objectForKey:canvasView];
    if (state) state.knownStrokeCount = replaced.count;

    if (undoingCleanUp) {
        // The hand-drawn stroke (`to`) is back. If PencilKit's own undo of
        // that stroke was not part of the same undo group, undo it now.
        __weak PKCanvasView *weakCanvas = canvasView;
        dispatch_async(dispatch_get_main_queue(), ^{
            PKCanvasView *canvas = weakCanvas;
            NSUndoManager *manager = canvas.undoManager;
            if (!canvas || !manager.canUndo || manager.isUndoing || manager.isRedoing) return;
            if (SRSameStroke(canvas.drawing.strokes.lastObject, to)) [manager undo];
        });
    }
    return YES;
}

@end
