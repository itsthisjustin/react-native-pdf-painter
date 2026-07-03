#import "PdfAnnotationView.h"

#import <react/renderer/components/RNPdfAnnotationViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNPdfAnnotationViewSpec/EventEmitters.h>
#import <react/renderer/components/RNPdfAnnotationViewSpec/Props.h>
#import <react/renderer/components/RNPdfAnnotationViewSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

@interface PdfAnnotationView () <RCTPdfAnnotationViewViewProtocol>

@end

@implementation PdfAnnotationView {
    CustomPdfView * _view;
    PKCanvasView * _canvasView;
    PencilKitCoordinator * _pencilKitCoordinator;
    RoundedTriangleAnnotation *firstLinkAnnotation;
    NSUInteger firstLinkPageIndex;
    NSUInteger _thumbnailGeneration;
    // The annotation file currently loaded into _canvasView. Diff-based
    // annotationFile handling misses reloads when a recycled view's
    // remembered props equal the new ones (same game reopened), leaving the
    // canvas empty while ink sits on disk.
    NSString *_loadedCanvasAnnotationFile;
}

- (PKCanvasViewDrawingPolicy)resolvedDrawingPolicyForToolPickerVisible:(BOOL)toolPickerVisible {
    if (!toolPickerVisible) {
        return PKCanvasViewDrawingPolicyPencilOnly;
    }
    return UIPencilInteraction.prefersPencilOnlyDrawing
        ? PKCanvasViewDrawingPolicyPencilOnly
        : PKCanvasViewDrawingPolicyAnyInput;
}

- (void)applyCanvasDrawingPolicy:(BOOL)drawWithFinger {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    BOOL toolPickerVisible = props.iosToolPickerVisible;
    _canvasView.drawingPolicy = [self resolvedDrawingPolicyForToolPickerVisible:toolPickerVisible];
    [_pencilKitCoordinator applyDrawingPolicyToVisibleCanvases];
}

- (void)applyClearBackgroundToScrollViews:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]] || [NSStringFromClass(subview.class) containsString:@"PageViewController"]) {
            subview.backgroundColor = [UIColor clearColor];
        }
        [self applyClearBackgroundToScrollViews:subview];
    }
}

- (void)applyAllowedTouchTypes:(NSArray<NSNumber *> *)types toView:(UIView *)view {
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        recognizer.allowedTouchTypes = types;
    }
    for (UIView *subview in view.subviews) {
        [self applyAllowedTouchTypes:types toView:subview];
    }
}

// With iosPencilAlwaysDraws + iosFingerPassthrough set (and the tool picker
// hidden), only pencil touches may drive the PDF view's internal gestures;
// finger touches fall through to ancestor views (e.g. React Native pan/zoom
// handlers behind a background PDF). Without iosFingerPassthrough, fingers
// keep interacting with the PDF view itself (scroll, zoom, page swipe) while
// the pencil draws.
- (void)refreshPencilTouchFiltering {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (!props.iosPencilAlwaysDraws || !props.iosFingerPassthrough || props.canvasMode) {
        return;
    }
    BOOL pencilOnly = !props.iosToolPickerVisible;
    NSArray<NSNumber *> *types = pencilOnly
        ? @[@(UITouchTypePencil)]
        : @[@(UITouchTypeDirect), @(UITouchTypeIndirect), @(UITouchTypePencil), @(UITouchTypeIndirectPointer)];
    [self applyAllowedTouchTypes:types toView:_view];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // PDFKit creates gesture recognizers lazily (page view controller, per-page
    // overlays), so re-apply the filter whenever layout runs.
    [self refreshPencilTouchFiltering];
}

- (void)updateCanvasToolPickerVisibility:(BOOL)visible {
    dispatch_async(dispatch_get_main_queue(), ^{
        MyPDFKitToolPickerModel *model = [MyPDFKitToolPickerModel sharedInstance];
        self->_canvasView.drawingPolicy = [self resolvedDrawingPolicyForToolPickerVisible:visible];
        if (visible) {
            [model.toolPicker addObserver:self->_canvasView];
        } else {
            [model.toolPicker removeObserver:self->_canvasView];
        }
        [self->_canvasView becomeFirstResponder];
        [model.toolPicker setVisible:visible forFirstResponder:self->_canvasView];
    });
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
    return concreteComponentDescriptorProvider<PdfAnnotationViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        static const auto defaultProps = std::make_shared<const PdfAnnotationViewProps>();
        _props = defaultProps;

        _view = [[CustomPdfView alloc] initWithFrame:frame];
        _view.displayMode = kPDFDisplaySinglePage;
        _view.displayDirection = kPDFDisplayDirectionHorizontal;
        _view.autoScales = true;
        _canvasView = [[PKCanvasView alloc] initWithFrame:frame];
        _canvasView.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        _canvasView.backgroundColor = [UIColor clearColor];
        _canvasView.opaque = NO;
        _canvasView.delegate = self;
        _pencilKitCoordinator = [[PencilKitCoordinator alloc] init];
        _pencilKitCoordinator.delegate = self;
        if (@available(iOS 16.0, *)) {
            _view.pageOverlayViewProvider = _pencilKitCoordinator;
        }

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePageChange:)
                                                     name:PDFViewPageChangedNotification
                                                   object:_view];

        UITapGestureRecognizer *tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        tapRecognizer.numberOfTapsRequired = 1;
        tapRecognizer.cancelsTouchesInView = NO;
        [_view addGestureRecognizer:tapRecognizer];

        UILongPressGestureRecognizer *longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPressRecognizer.minimumPressDuration = 0.25;
        [_view addGestureRecognizer:longPressRecognizer];

        [_view usePageViewController:true withViewOptions:NULL];

        self.contentView = _view;
        [self applyCanvasDrawingPolicy:YES];
        [self updateThumbnailMode:false];
    }

    return self;
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (props.canvasMode) {
        [self updateCanvasToolPickerVisibility:props.iosToolPickerVisible];
    }
}

// Fabric recycles native views across mounts; without a full reset a recycled
// view leaks the previous document, ink, and markup state into whatever
// mounts next (e.g. a game with no PDF showing the prior game's board).
- (void)prepareForRecycle
{
    [super prepareForRecycle];
    _thumbnailGeneration++; // invalidate any pending thumbnail snapshot
    _view.document = nil;
    _loadedCanvasAnnotationFile = nil;
    [self setCanvasDrawingQuietly:[[PKDrawing alloc] init]];
    if (@available(iOS 16.0, *)) {
        [_view setInMarkupMode:NO];
    }
    MyPDFKitToolPickerModel *model = [MyPDFKitToolPickerModel sharedInstance];
    [model.toolPicker removeObserver:_canvasView];
    self.contentView = _view;
    firstLinkAnnotation = nil;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (props.canvasMode) return;
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) return;

    CGPoint locationInView = [gestureRecognizer locationInView:_view];
    PDFPage *currentPage = _view.currentPage;

    if (!currentPage) return;

    CGPoint locationOnPage = [_view convertPoint:locationInView toPage:currentPage];

    for (PDFAnnotation *annotation in currentPage.annotations) {
        if (CGRectContainsPoint(annotation.bounds, locationOnPage)) {
            [currentPage removeAnnotation:annotation];

            if (props.autoSave) {
                NSString * filePath = [[NSString alloc] initWithUTF8String: props.annotationFile.c_str()];
                [_pencilKitCoordinator prepareForPersistance:(MyPDFDocument *)_view.document];
                [(MyPDFDocument* )_view.document saveDrawingsToDisk:filePath];
            }
            break;
        }
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)sender {
}

- (void)handleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) return;

    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (props.canvasMode) {
        CGPoint touchLocation = [sender locationInView:_canvasView];
        PdfAnnotationViewEventEmitter::OnTap event = PdfAnnotationViewEventEmitter::OnTap{touchLocation.x, touchLocation.y};
        if (_eventEmitter != nullptr) {
           std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)
            ->onTap(event);
        }
        return;
    }

    CGPoint touchLocation = [sender locationInView:_view];
    CGFloat screenWidth = _view.bounds.size.width;
    bool addLink = props.brushSettings.type == PdfAnnotationViewType::Link;

    PDFPage *currentPage = _view.currentPage;
    CGPoint convertedPoint = [_view convertPoint:touchLocation toPage:currentPage];

    if (addLink) {
        NSUInteger currentPageIndex = [_view.document indexForPage:currentPage];
        Float size = props.brushSettings.size;
        RoundedTriangleAnnotation *linkAnnotation = [[RoundedTriangleAnnotation alloc] initWithBounds:CGRectMake(convertedPoint.x - size / 2, convertedPoint.y - size / 2, size, size) forType:PDFAnnotationSubtypeWidget withProperties:nil];
        linkAnnotation.backgroundColor = [self hexStringToColor:[NSString stringWithUTF8String:props.brushSettings.color.c_str()]];


        [currentPage addAnnotation:linkAnnotation];


        if (!firstLinkAnnotation) {
            firstLinkAnnotation = linkAnnotation;
            firstLinkPageIndex = currentPageIndex;
        } else {
            PDFDestination *dest1 = [[PDFDestination alloc] initWithPage:[_view.document pageAtIndex:currentPageIndex] atPoint:CGPointZero];
            PDFDestination *dest2 = [[PDFDestination alloc] initWithPage:[_view.document pageAtIndex:firstLinkPageIndex] atPoint:CGPointZero];

            firstLinkAnnotation.rotation = firstLinkPageIndex > currentPageIndex ? 0 : 180;
            linkAnnotation.rotation = firstLinkPageIndex > currentPageIndex ? 180 : 0;

            firstLinkAnnotation.action = [[PDFActionGoTo alloc] initWithDestination:dest1];
            linkAnnotation.action = [[PDFActionGoTo alloc] initWithDestination:dest2];
            linkAnnotation.backgroundColor = [linkAnnotation.backgroundColor colorWithAlphaComponent:CGColorGetAlpha(linkAnnotation.backgroundColor.CGColor) * 0.5];

            firstLinkAnnotation = nil;

            PdfAnnotationViewEventEmitter::OnLinkCompleted event = PdfAnnotationViewEventEmitter::OnLinkCompleted{static_cast<int>(firstLinkPageIndex), static_cast<int>(currentPageIndex)};
            if (_eventEmitter != nullptr) {
               std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)
                ->onLinkCompleted(event);
            }

            if (props.autoSave) {
                NSString * filePath = [[NSString alloc] initWithUTF8String: props.annotationFile.c_str()];
                [_pencilKitCoordinator prepareForPersistance:(MyPDFDocument *)_view.document];
                [(MyPDFDocument* )_view.document saveDrawingsToDisk:filePath];
            }
        }
        [_view layoutDocumentView];
        return;
    }

    NSArray<PDFAnnotation *> *annotations = [currentPage annotations];
    for (PDFAnnotation *annotation in annotations) {
        if (CGRectContainsPoint(annotation.bounds, convertedPoint)) {
            if ([annotation isKindOfClass:[PDFAnnotation class]] && annotation.action) {
                if ([annotation.action isKindOfClass:[PDFActionGoTo class]]) {
                    PDFActionGoTo *goToAction = (PDFActionGoTo *)annotation.action;
                    [_view performSelector:@selector(goToDestination:) withObject:goToAction.destination afterDelay:0.1];
                    return;
                }
            }
        }
    }

    NSInteger delta = 0;
    // Tap-edge page turning is disabled in pencil-always-draws mode: a pencil
    // tap near the page edge is drawing input, not navigation.
    bool pageNavigationEnabled = props.pageNavigationEnabled && !props.iosPencilAlwaysDraws;
    if (pageNavigationEnabled && touchLocation.x < screenWidth * 0.25 && !addLink) {
        delta = -1;
    } else if (pageNavigationEnabled && touchLocation.x > screenWidth * 0.75 && !addLink) {
        delta = 1;
    } else {
        if (_view.currentSelection) {
            [_view clearSelection];
            return;
        }
        
        PdfAnnotationViewEventEmitter::OnTap event = PdfAnnotationViewEventEmitter::OnTap{touchLocation.x, touchLocation.y};
        if (_eventEmitter != nullptr) {
           std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)
            ->onTap(event);
        }
    }

    if (currentPage) {
        NSUInteger currentIndex = [currentPage.document indexForPage:currentPage];
        NSUInteger nextIndex = currentIndex + delta;
        if (nextIndex >= 0 && nextIndex < _view.document.pageCount) {
            [_view goToPage:[currentPage.document pageAtIndex:nextIndex]];
        } else {
            PdfAnnotationViewEventEmitter::OnDocumentFinished event = PdfAnnotationViewEventEmitter::OnDocumentFinished{delta > 0};
            if (_eventEmitter != nullptr) {
               std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)
                ->onDocumentFinished(event);
            }
        }
    }
}

- (void)updateCanvasMode:(bool)isCanvasMode {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (isCanvasMode) {
        self.contentView = _canvasView;
        [self applyCanvasDrawingPolicy:props.drawWithFinger];
        [self updateCanvasToolPickerVisibility:props.iosToolPickerVisible];
        if (_eventEmitter != nullptr) {
            PdfAnnotationViewEventEmitter::OnPageCount countEvent = PdfAnnotationViewEventEmitter::OnPageCount{1};
            PdfAnnotationViewEventEmitter::OnPageChange pageEvent = PdfAnnotationViewEventEmitter::OnPageChange{0};
            std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)->onPageCount(countEvent);
            std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)->onPageChange(pageEvent);
        }
    } else {
        self.contentView = _view;
    }
}

- (void)saveCanvasDrawingToDisk:(NSString *)filePath {
    if ([filePath hasPrefix:@"file://"]) {
        filePath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    }
    NSData *data = [_canvasView.drawing dataRepresentation];
    [data writeToFile:filePath atomically:YES];
}

// Programmatic drawing assignment fires canvasViewDrawingDidChange, and with
// autoSave that echo writes the just-assigned (possibly empty) drawing back
// over the file — erasing real ink. Detach the delegate around assignments.
- (void)setCanvasDrawingQuietly:(PKDrawing *)drawing {
    _canvasView.delegate = nil;
    _canvasView.drawing = drawing;
    _canvasView.delegate = self;
}

- (void)loadCanvasDrawingFromDisk:(NSString *)filePath {
    if ([filePath hasPrefix:@"file://"]) {
        filePath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    }
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        [self setCanvasDrawingQuietly:[[PKDrawing alloc] init]];
        return;
    }
    NSError *error = nil;
    PKDrawing *drawing = [[PKDrawing alloc] initWithData:data error:&error];
    if (!error && drawing) {
        [self setCanvasDrawingQuietly:drawing];
    }
}

- (void)handlePageChange:(NSNotification *)notification {
    NSUInteger index = [_view.document indexForPage:_view.currentPage];
    PdfAnnotationViewEventEmitter::OnPageChange event = PdfAnnotationViewEventEmitter::OnPageChange{(int)index};
    if (_eventEmitter != nullptr) {
       std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(_eventEmitter)
        ->onPageChange(event);
     }
    // New pages bring freshly created overlay canvases and recognizers.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshPencilTouchFiltering];
    });
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
    const auto &oldViewProps = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    const auto &newViewProps = *std::static_pointer_cast<PdfAnnotationViewProps const>(props);

    if (oldViewProps.pdfUrl != newViewProps.pdfUrl) {
        NSString * pdfUrl = [[NSString alloc] initWithUTF8String: newViewProps.pdfUrl.c_str()];
        if ([pdfUrl hasPrefix:@"file://"]) {
            pdfUrl = [pdfUrl stringByReplacingOccurrencesOfString:@"file://" withString:@""];
        }
        pdfUrl = [pdfUrl stringByRemovingPercentEncoding];
        NSURL* url = [NSURL fileURLWithPath:pdfUrl isDirectory:NO];
        _view.document = [[MyPDFDocument alloc] initWithURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            PdfAnnotationViewEventEmitter::OnPageCount result = PdfAnnotationViewEventEmitter::OnPageCount{(int)self->_view.document.pageCount};
            if (self->_eventEmitter != nullptr) {
                std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(self->_eventEmitter)
                ->onPageCount(result);
             }
        });

        _view.minScaleFactor = _view.scaleFactorForSizeToFit;
        _view.maxScaleFactor = 4.0;
        _view.scaleFactor = _view.scaleFactorForSizeToFit;
        dispatch_async(dispatch_get_main_queue(), ^{
            const auto &loadedProps = *std::static_pointer_cast<PdfAnnotationViewProps const>(self->_props);
            if (loadedProps.iosPencilAlwaysDraws && !loadedProps.canvasMode) {
                if (@available(iOS 16.0, *)) {
                    [self->_view setInMarkupMode:YES];
                }
            }
            NSString * bg = [[NSString alloc] initWithUTF8String: loadedProps.backgroundColor.c_str()];
            if ([bg isEqualToString:@"transparent"]) {
                [self applyClearBackgroundToScrollViews:self->_view];
            }
            [self refreshPencilTouchFiltering];
        });
    }
    if (oldViewProps.canvasMode != newViewProps.canvasMode) {
        [self updateCanvasMode:newViewProps.canvasMode];
    }
    if (oldViewProps.drawWithFinger != newViewProps.drawWithFinger) {
        [self applyCanvasDrawingPolicy:newViewProps.drawWithFinger];
    }
    if ((oldViewProps.brushSettings.size != newViewProps.brushSettings.size || oldViewProps.brushSettings.type != newViewProps.brushSettings.type || oldViewProps.brushSettings.color != newViewProps.brushSettings.color || oldViewProps.brushSettings.lineal != newViewProps.brushSettings.lineal)) {
        if (newViewProps.canvasMode) {
            NSString * colorString = [[NSString alloc] initWithUTF8String: newViewProps.brushSettings.color.c_str()];
            UIColor *toolColor = [self hexStringToColor:colorString];
            PKTool *tool;
            switch (newViewProps.brushSettings.type) {
                case PdfAnnotationViewType::PressurePen:
                    tool = [[PKInkingTool alloc] initWithInkType:PKInkTypePencil color:toolColor width:newViewProps.brushSettings.size];
                    break;
                case PdfAnnotationViewType::Highlighter:
                    tool = [[PKInkingTool alloc] initWithInkType:PKInkTypeMarker color:toolColor width:newViewProps.brushSettings.size];
                    break;
                case PdfAnnotationViewType::Eraser:
                    if (@available(iOS 16.4, *)) {
                        tool = [[PKEraserTool alloc] initWithEraserType:PKEraserTypeVector width:newViewProps.brushSettings.size];
                    } else {
                        tool = [[PKEraserTool alloc] initWithEraserType:PKEraserTypeVector];
                    }
                    break;
                case PdfAnnotationViewType::Marker:
                default:
                    tool = [[PKInkingTool alloc] initWithInkType:PKInkTypePen color:toolColor width:newViewProps.brushSettings.size];
                    break;
            }
            _canvasView.tool = tool;
            [_canvasView setRulerActive:newViewProps.brushSettings.lineal];
        } else if (@available(iOS 16.0, *)) {
            [_view setInMarkupMode:newViewProps.brushSettings.type != PdfAnnotationViewType::None && newViewProps.brushSettings.type != PdfAnnotationViewType::Link];
            [_pencilKitCoordinator setDrawingTool:_view.currentPage brushSettings:newViewProps.brushSettings];
        } else {
            [_pencilKitCoordinator setDrawingTool:_view.currentPage brushSettings:newViewProps.brushSettings];
        }
    }
    if (oldViewProps.iosToolPickerVisible != newViewProps.iosToolPickerVisible) {
        if (newViewProps.canvasMode) {
            [self updateCanvasToolPickerVisibility:newViewProps.iosToolPickerVisible];
        } else if (@available(iOS 16.0, *)) {
            // In pencil-always-draws mode markup stays on so the pencil can
            // draw with the tool picker hidden.
            [_view setInMarkupMode:(newViewProps.iosToolPickerVisible || newViewProps.iosPencilAlwaysDraws)];
            [_pencilKitCoordinator setToolPickerVisible:_view.currentPage isVisible:newViewProps.iosToolPickerVisible];
        } else {
            [_pencilKitCoordinator setToolPickerVisible:_view.currentPage isVisible:newViewProps.iosToolPickerVisible];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshPencilTouchFiltering];
        });
    }
    if (oldViewProps.iosPencilAlwaysDraws != newViewProps.iosPencilAlwaysDraws) {
        if (!newViewProps.canvasMode) {
            if (@available(iOS 16.0, *)) {
                [_view setInMarkupMode:(newViewProps.iosToolPickerVisible || newViewProps.iosPencilAlwaysDraws)];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshPencilTouchFiltering];
        });
    }
    if (oldViewProps.annotationFile != newViewProps.annotationFile) {
        NSString * filePath = [[NSString alloc] initWithUTF8String: newViewProps.annotationFile.c_str()];
        if (newViewProps.canvasMode) {
            [self loadCanvasDrawingFromDisk:filePath];
            _loadedCanvasAnnotationFile = filePath;
        } else {
            [(MyPDFDocument* )_view.document loadDrawingsFromDisk:filePath];
            [_pencilKitCoordinator updateDrawings:(MyPDFDocument *)_view.document];
        }
    }
    if (oldViewProps.thumbnailMode != newViewProps.thumbnailMode) {
        [self updateThumbnailMode:newViewProps.thumbnailMode];
    }
    if (oldViewProps.pageNavigationEnabled != newViewProps.pageNavigationEnabled) {
        [_view usePageViewController:newViewProps.pageNavigationEnabled withViewOptions:NULL];
    }
    if (oldViewProps.backgroundColor != newViewProps.backgroundColor) {
        NSString * hexColor = [[NSString alloc] initWithUTF8String: newViewProps.backgroundColor.c_str()];
        if ([hexColor isEqualToString:@"transparent"]) {
            _view.backgroundColor = [UIColor clearColor];
            [self applyClearBackgroundToScrollViews:_view];
        } else {
            _view.backgroundColor = [self hexStringToColor:hexColor];
        }
        _view.pageShadowsEnabled = false;
    }

    // --- Recycled-view invariants ---------------------------------------
    // Diff-based handlers above miss stale native state when a recycled
    // view's remembered props happen to match the new ones. Enforce the
    // final configuration unconditionally: a canvas view never shows a PDF
    // document, and a PDF view with a URL always has its document loaded.
    if (newViewProps.canvasMode) {
        if (_view.document != nil) {
            _view.document = nil;
        }
        if (self.contentView != _canvasView) {
            [self updateCanvasMode:true];
        }
        // Reload ink whenever the canvas doesn't hold this file's drawing —
        // covers first mount and recycled views whose remembered props match
        // the new ones (where the diff above never fires).
        if (!newViewProps.annotationFile.empty()) {
            NSString *filePath = [[NSString alloc] initWithUTF8String: newViewProps.annotationFile.c_str()];
            if (![filePath isEqualToString:_loadedCanvasAnnotationFile]) {
                [self loadCanvasDrawingFromDisk:filePath];
                _loadedCanvasAnnotationFile = filePath;
            }
        }
    } else if (!newViewProps.pdfUrl.empty() && _view.document == nil) {
        NSString * pdfUrl = [[NSString alloc] initWithUTF8String: newViewProps.pdfUrl.c_str()];
        if ([pdfUrl hasPrefix:@"file://"]) {
            pdfUrl = [pdfUrl stringByReplacingOccurrencesOfString:@"file://" withString:@""];
        }
        pdfUrl = [pdfUrl stringByRemovingPercentEncoding];
        NSURL* url = [NSURL fileURLWithPath:pdfUrl isDirectory:NO];
        _view.document = [[MyPDFDocument alloc] initWithURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            PdfAnnotationViewEventEmitter::OnPageCount result = PdfAnnotationViewEventEmitter::OnPageCount{(int)self->_view.document.pageCount};
            if (self->_eventEmitter != nullptr) {
                std::dynamic_pointer_cast<const PdfAnnotationViewEventEmitter>(self->_eventEmitter)->onPageCount(result);
            }
        });
    }

    [super updateProps:props oldProps:oldProps];
}

- (void)pencilKitCoordinatorDrawingDidChange:(PencilKitCoordinator *)coordinator {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (!props.autoSave) {
        return;
    }
    NSString * filePath = [[NSString alloc] initWithUTF8String: props.annotationFile.c_str()];
    if (props.canvasMode) {
        [self saveCanvasDrawingToDisk:filePath];
    } else {
        [_pencilKitCoordinator prepareForPersistance:(MyPDFDocument *)_view.document];
        [(MyPDFDocument* )_view.document saveDrawingsToDisk:filePath];
    }
}

- (void)updateThumbnailMode:(bool) isThumbnail {
    // The generation guard keeps a pending async snapshot from stamping a
    // stale PDF image onto a view that has since been recycled or
    // reconfigured (e.g. reused as another game's ink canvas).
    NSUInteger generation = ++_thumbnailGeneration;
    if (isThumbnail) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_thumbnailGeneration) return;
            if (!self->_props) return;
            const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(self->_props);
            if (!props.thumbnailMode) return;
            PDFDocument *document = self->_view.document;
            if (document) {
                PDFPage *firstPage = [document pageAtIndex:0];
                UIImage *thumbnailImage = [firstPage thumbnailOfSize:self->_view.frame.size forBox:kPDFDisplayBoxMediaBox];
                UIImageView *imageView = [[UIImageView alloc] initWithImage:thumbnailImage];
                imageView.frame = self->_view.frame;
                self.contentView = imageView;
            }
        });
    } else {
        self.contentView = _view;
    }
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args {
    if ([commandName isEqual:@"saveAnnotations"]) {
        if (args.count == 0) {
            return NSLog(@"Missing parameter for loading annotations!");
        }
        const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
        if (props.canvasMode) {
            [self saveCanvasDrawingToDisk:(NSString *)args[0]];
        } else {
            [_pencilKitCoordinator prepareForPersistance:(MyPDFDocument *)_view.document];
            [(MyPDFDocument* )_view.document saveDrawingsToDisk:(NSString*) args[0]];
        }
    }
    if ([commandName isEqual:@"loadAnnotations"]) {
        if (args.count == 0) {
            return NSLog(@"Missing parameter for loading annotations!");
        }
        const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
        if (props.canvasMode) {
            [self loadCanvasDrawingFromDisk:(NSString *)args[0]];
        } else {
            [(MyPDFDocument* )_view.document loadDrawingsFromDisk:(NSString*) args[0]];
            [_pencilKitCoordinator updateDrawings:(MyPDFDocument *)_view.document];
        }
    }
    if ([commandName isEqual:@"undo"]) {
        const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
        if (props.canvasMode) {
            [[_canvasView undoManager] undo];
        } else {
            [_pencilKitCoordinator undo:_view.currentPage];
        }
    }
    if ([commandName isEqual:@"redo"]) {
        const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
        if (props.canvasMode) {
            [[_canvasView undoManager] redo];
        } else {
            [_pencilKitCoordinator redo:_view.currentPage];
        }
    }
    if ([commandName isEqual:@"clear"]) {
        const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
        if (props.canvasMode) {
            [_canvasView setDrawing:[[PKDrawing alloc] init]];
        } else {
            PDFPage *currentPage = _view.currentPage;
            if (currentPage) {
                NSArray<PDFAnnotation *> *annotations = [currentPage annotations];
                if (!annotations) return;
                for (PDFAnnotation *annotation in annotations) {
                    if ([annotation isKindOfClass:[RoundedTriangleAnnotation class]]) {
                        [currentPage removeAnnotation:annotation];
                    }
                }
            }
            [_pencilKitCoordinator clear:_view.currentPage];
        }
    }
    if ([commandName isEqual:@"setPage"]) {
        if (args.count == 0) {
            return NSLog(@"Missing parameter page!");
        }
        id firstElement = [args objectAtIndex:0];
        if ([firstElement respondsToSelector:@selector(integerValue)]) {
            NSInteger firstInt = [firstElement integerValue];
            [_view goToPage:[_view.document pageAtIndex:firstInt]];
        }
    }
}

- (void)canvasViewDrawingDidChange:(PKCanvasView *)canvasView {
    const auto &props = *std::static_pointer_cast<PdfAnnotationViewProps const>(_props);
    if (!props.autoSave || !props.canvasMode) {
        return;
    }
    NSString * filePath = [[NSString alloc] initWithUTF8String: props.annotationFile.c_str()];
    [self saveCanvasDrawingToDisk:filePath];
}

Class<RCTComponentViewProtocol> PdfAnnotationViewCls(void)
{
    return PdfAnnotationView.class;
}

- (UIColor *)hexStringToColor:(NSString *)colorString {
    // Ensure the string starts with "#" and has the correct length (8 characters for AARRGGBB format)
    if ([colorString hasPrefix:@"#"] && (colorString.length == 9 || colorString.length == 7)) {
        // Remove the "#" and process the hex string
        NSString *hexString = [colorString substringFromIndex:1];
        unsigned int hexValue;
        NSScanner *scanner = [NSScanner scannerWithString:hexString];
        [scanner scanHexInt:&hexValue];

        // Extract alpha, red, green, and blue components
        CGFloat alpha = ((hexValue >> 24) & 0xFF) / 255.0;
        CGFloat red = ((hexValue >> 16) & 0xFF) / 255.0;
        CGFloat green = ((hexValue >> 8) & 0xFF) / 255.0;
        CGFloat blue = (hexValue & 0xFF) / 255.0;

        if (hexString.length == 8) {
            return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
        }
        if (hexString.length == 6) {
            return [UIColor colorWithRed:red green:green blue:blue alpha:1];
        }
    }

    // If the string is not a valid hex color with alpha or RGB, return default color (black)
    return [UIColor blackColor];
}

@end
