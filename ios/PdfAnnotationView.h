#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>
#import <PDFKit/PDFKit.h>
#import "PencilKitCoordinator.h"
#import "MyPDFDocument.h"
#import "CustomPdfView.h"

#ifndef PdfAnnotationViewNativeComponent_h
#define PdfAnnotationViewNativeComponent_h

NS_ASSUME_NONNULL_BEGIN

@interface PdfAnnotationView : RCTViewComponentView<PencilKitCoordinatorDelegate, PKCanvasViewDelegate>
/** Strips PencilKit's "Select All / Insert Space" edit menu from a canvas and its subviews. */
+ (void)removeEditMenu:(UIView *)view;
@end

NS_ASSUME_NONNULL_END

#endif /* PdfAnnotationViewNativeComponent_h */
