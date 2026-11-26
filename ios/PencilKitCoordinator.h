#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import <PencilKit/PencilKit.h>
#import "MyPDFPage.h"
#import <react/renderer/components/RNPdfAnnotationViewSpec/Props.h>
#import "MyPDFKitToolPickerModel.h"
#import "MyPDFDocument.h"
#import "StrokeRefinementController.h"

NS_ASSUME_NONNULL_BEGIN

using namespace facebook::react;

@class PencilKitCoordinator;
@protocol PencilKitCoordinatorDelegate <NSObject>
- (void)pencilKitCoordinatorDrawingDidChange:(PencilKitCoordinator *)coordinator;
@end

@interface PencilKitCoordinator : NSObject <PDFPageOverlayViewProvider, PKCanvasViewDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, PKCanvasView *> *pageToViewMapping;
@property (nonatomic, weak) id<PencilKitCoordinatorDelegate> delegate;
@property (nonatomic, assign) BOOL toolPickerVisible;
@property PdfAnnotationViewBrushSettingsStruct currentBrushSettings;
// Shape recognition and handwriting clean-up for freshly drawn strokes
// (iosShapeRecognition / iosSmoothStrokes). Serves the page canvases owned
// here and the free canvas owned by PdfAnnotationView.
@property (nonatomic, strong, readonly) StrokeRefinementController *strokeRefiner;


- (UIView *)pdfView:(PDFView *)view overlayViewForPage:(PDFPage *)page;
- (void)pdfView:(PDFView *)pdfView willEndDisplayingOverlayView:(UIView *)overlayView forPage:(PDFPage *)page;
-(void)prepareForPersistance:(MyPDFDocument *)document;
-(void)updateDrawings:(MyPDFDocument *)document;
- (void)setDrawingTool:(PDFPage *)pdfPage brushSettings:(PdfAnnotationViewBrushSettingsStruct)config;
- (void)setToolPickerVisible:(PDFPage *)pdfPage isVisible:(bool)visible;
- (void)applyDrawingPolicyToVisibleCanvases;
- (UIColor *)colorFromString:(NSString *)colorInHex;
-(void)undo:(PDFPage *)pdfPage;
-(void)redo:(PDFPage *)pdfPage;
-(void)clear:(PDFPage *)pdfPage;

@end

NS_ASSUME_NONNULL_END
