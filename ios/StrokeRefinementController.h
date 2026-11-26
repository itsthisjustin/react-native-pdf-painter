#import <Foundation/Foundation.h>
#import <PencilKit/PencilKit.h>

NS_ASSUME_NONNULL_BEGIN

// PencilKit glue for the two Apple Pencil refinements (the geometry itself
// lives in StrokeRefiner.{h,mm}):
//
//   shapeRecognitionEnabled  "draw and hold": a stroke finished with the pen
//                            resting at its end is replaced by a clean line,
//                            arrow, ellipse, rectangle or triangle if it
//                            confidently is one. Undo brings back the
//                            hand-drawn stroke.
//   smoothStrokesEnabled     a light clean-up of every finished pen stroke.
//
// Both are off by default. A PKCanvasView delegate forwards its three
// callbacks here; one controller can serve any number of canvases.
@interface StrokeRefinementController : NSObject

@property (nonatomic, assign) BOOL shapeRecognitionEnabled;
@property (nonatomic, assign) BOOL smoothStrokesEnabled;

// YES while this controller is assigning a refined drawing to a canvas.
// PencilKit reports that assignment through canvasViewDrawingDidChange: like
// any other change; the delegate should return early when this is set (the
// change that triggered the refinement is still being handled further up
// the stack, and saves the refined drawing when it resumes).
@property (nonatomic, readonly) BOOL isApplyingRefinement;

- (void)canvasViewDidBeginUsingTool:(PKCanvasView *)canvasView;
- (void)canvasViewDidEndUsingTool:(PKCanvasView *)canvasView;

// Call first thing from canvasViewDrawingDidChange:. If the change is a
// stroke the user has just finished, refines it. Returns YES when the
// canvas's drawing was replaced before returning (a recognised shape is
// instead swapped in on the next run-loop turn, and reported to the delegate
// as a drawing change of its own).
- (BOOL)canvasViewDrawingDidChange:(PKCanvasView *)canvasView;

@end

NS_ASSUME_NONNULL_END
