
#import "MyPDFDocument.h"

@implementation MyPDFDocument

// Override the pageClass getter to return MyPDFPage
- (Class)pageClass {
    return [MyPDFPage class];
}

- (void)saveDrawingsToDisk:(NSString *)filePath {
    if ([filePath hasPrefix:@"file://"]) {
        filePath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    }
    
    NSMutableDictionary *dataToSave = [NSMutableDictionary dictionary];
    
    for (NSUInteger pageIndex = 0; pageIndex < self.pageCount; pageIndex++) {
        MyPDFPage *page = (MyPDFPage *)[self pageAtIndex:pageIndex];
        
        NSMutableDictionary *pageData = [NSMutableDictionary dictionary];
        if (page.drawing) {
            // Archive the drawing using secure coding
            NSData *drawingData = [page.drawing dataRepresentation];
            pageData[@"drawing"] = drawingData;
        }
        
        // Speichern der Link-Annotationen. Only the fork's own link
        // annotations are persisted: documents ship with native link
        // annotations too (e.g. a rulebook's table of contents), whose
        // GoTo actions match the class check but have no backgroundColor —
        // CGColorGetComponents(nil) returned NULL and crashed on deref.
        NSMutableArray *linkAnnotations = [NSMutableArray array];
        for (PDFAnnotation *annotation in page.annotations) {
            if (![annotation isKindOfClass:[RoundedTriangleAnnotation class]]) continue;
            RoundedTriangleAnnotation *linkAnnotation = (RoundedTriangleAnnotation *)annotation;
            PDFActionGoTo *goToAction = (PDFActionGoTo *)linkAnnotation.action;
            if (![goToAction isKindOfClass:[PDFActionGoTo class]] || goToAction.destination.page == nil) continue;
            NSUInteger targetPageIndex = [self indexForPage:goToAction.destination.page];
            CGColorRef cgColor = linkAnnotation.backgroundColor.CGColor;
            const CGFloat *components = cgColor ? CGColorGetComponents(cgColor) : NULL;
            NSArray *color = (components && CGColorGetNumberOfComponents(cgColor) >= 3)
                ? @[@(components[0]), @(components[1]), @(components[2]), @(CGColorGetAlpha(cgColor))]
                : @[@0, @0, @0, @1];
            NSDictionary *linkData = @{
                @"bounds": NSStringFromCGRect(linkAnnotation.bounds),
                @"targetPage": @(targetPageIndex),
                @"color": color
            };
            [linkAnnotations addObject:linkData];
        }

        if (linkAnnotations.count > 0) {
            pageData[@"links"] = linkAnnotations;
        }
        
        if (pageData.count > 0) {
            dataToSave[@(pageIndex)] = pageData;
        }
    }
    
    // Archive the dictionary of drawings using secure coding
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dataToSave requiringSecureCoding:NO error:NULL];
    [data writeToFile:filePath atomically:YES];
}


- (void)loadDrawingsFromDisk:(NSString *)filePath {
    if ([filePath hasPrefix:@"file://"]) {
        filePath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    }

    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        NSLog(@"⚠️ Error while reading file");
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:
        [NSDictionary class], [NSArray class], [NSNumber class], [NSString class],
        [NSData class], [UIColor class], nil];
    id loadedObject = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:data error:&error];

    if (error) {
        NSLog(@"❌ Error while unarchiving: %@", error);
        return;
    }

    if ([loadedObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *loadedData = (NSDictionary *)loadedObject;

        for (NSNumber *pageIndexKey in loadedData) {
            id pageData = loadedData[pageIndexKey];
            MyPDFPage *page = (MyPDFPage *)[self pageAtIndex:pageIndexKey.integerValue];

            if ([pageData isKindOfClass:[NSDictionary class]]) {
                NSDictionary *pageDict = (NSDictionary *)pageData;

                if ([pageDict[@"drawing"] isKindOfClass:[NSData class]]) {
                    NSData *drawingData = pageDict[@"drawing"];
                    PKDrawing *drawing = [[PKDrawing alloc] initWithData:drawingData error:&error];
                    if (!error) {
                        page.drawing = drawing;
                    }
                }

                if ([pageDict[@"links"] isKindOfClass:[NSArray class]]) {
                    NSArray *linkAnnotations = pageDict[@"links"];
                    for (NSDictionary *linkData in linkAnnotations) {
                        //if (![linkData isKindOfClass:[NSDictionary class]]) continue;

                        CGRect bounds = CGRectFromString(linkData[@"bounds"]);
                        NSUInteger targetPageIndex = [linkData[@"targetPage"] unsignedIntegerValue];
                        NSArray *colorComponents = linkData[@"color"];
                        UIColor *color = [UIColor colorWithRed:[colorComponents[0] floatValue]
                                                                                             green:[colorComponents[1] floatValue]
                                                                                              blue:[colorComponents[2] floatValue]
                                                                                             alpha:[colorComponents[3] floatValue]];

                        RoundedTriangleAnnotation *linkAnnotation = [[RoundedTriangleAnnotation alloc] initWithBounds:bounds forType:PDFAnnotationSubtypeWidget withProperties:nil];
                        linkAnnotation.backgroundColor = color;
                        linkAnnotation.rotation = pageIndexKey.integerValue > targetPageIndex ? 0 : 180;
                        PDFActionGoTo *goToAction = [[PDFActionGoTo alloc] initWithDestination:[[PDFDestination alloc] initWithPage:[self pageAtIndex:targetPageIndex] atPoint:CGPointZero]];
                        linkAnnotation.action = goToAction;

                        [page addAnnotation:linkAnnotation];
                    }
                }
            } else if ([pageData isKindOfClass:[NSData class]]) {
                // backwards compatibility when no links were stored!
                NSData *drawingData = (NSData *)pageData;
                PKDrawing *drawing = [[PKDrawing alloc] initWithData:drawingData error:&error];
                if (!error) {
                    page.drawing = drawing;
                }
            }
        }
    }
}



@end
