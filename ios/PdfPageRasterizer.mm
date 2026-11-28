#import "PdfPageRasterizer.h"

#import <PDFKit/PDFKit.h>
#import <UIKit/UIKit.h>

static NSString *stripFileScheme(NSString *path) {
    if ([path hasPrefix:@"file://"]) {
        path = [path substringFromIndex:7];
    }
    return [path stringByRemovingPercentEncoding] ?: path;
}

@implementation PdfPageRasterizer

RCT_EXPORT_MODULE(PdfPageRasterizer)

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

// Renders every page of a PDF to a PNG in outputDir, scaled so the longest
// side is maxDimension pixels. Resolves with the ordered list of file:// URIs.
RCT_EXPORT_METHOD(renderPdfToImages:(NSString *)pdfPath
                  outputDir:(NSString *)outputDir
                  maxDimension:(nonnull NSNumber *)maxDimension
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = stripFileScheme(pdfPath);
        NSString *outDir = stripFileScheme(outputDir);

        PDFDocument *document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
        if (!document) {
            reject(@"pdf_load_failed", [NSString stringWithFormat:@"Could not open PDF at %@", path], nil);
            return;
        }

        NSError *dirError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirError];
        if (dirError) {
            reject(@"pdf_output_dir_failed", dirError.localizedDescription, dirError);
            return;
        }

        CGFloat maxDim = maxDimension.doubleValue > 0 ? maxDimension.doubleValue : 2048;
        NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:document.pageCount];

        for (NSUInteger i = 0; i < document.pageCount; i++) {
            PDFPage *page = [document pageAtIndex:i];
            CGRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
            if (bounds.size.width <= 0 || bounds.size.height <= 0) {
                reject(@"pdf_page_invalid", [NSString stringWithFormat:@"Page %lu has invalid bounds", (unsigned long)i], nil);
                return;
            }
            CGFloat scale = maxDim / MAX(bounds.size.width, bounds.size.height);
            CGSize size = CGSizeMake(round(bounds.size.width * scale), round(bounds.size.height * scale));

            UIImage *image = [page thumbnailOfSize:size forBox:kPDFDisplayBoxMediaBox];
            NSData *png = UIImagePNGRepresentation(image);
            if (!png) {
                reject(@"pdf_render_failed", [NSString stringWithFormat:@"Could not render page %lu", (unsigned long)i], nil);
                return;
            }

            NSString *fileName = [NSString stringWithFormat:@"pdfpage_%lu.png", (unsigned long)i];
            NSString *outPath = [outDir stringByAppendingPathComponent:fileName];
            if (![png writeToFile:outPath atomically:YES]) {
                reject(@"pdf_write_failed", [NSString stringWithFormat:@"Could not write page %lu", (unsigned long)i], nil);
                return;
            }
            [uris addObject:[@"file://" stringByAppendingString:outPath]];
        }

        resolve(uris);
    });
}

// Renders some pages of a PDF as small JPEGs named pdfpage_<index>.jpg in outputDir, for a
// page overview that fills in as it goes. A page whose file is already there is skipped, so
// the folder is a cache: opening the overview again costs nothing. Resolves with the indexes done.
RCT_EXPORT_METHOD(renderPdfPages:(NSString *)pdfPath
                  outputDir:(NSString *)outputDir
                  maxDimension:(nonnull NSNumber *)maxDimension
                  pages:(NSArray<NSNumber *> *)pages
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *outDir = stripFileScheme(outputDir);
        NSFileManager *files = [NSFileManager defaultManager];
        [files createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

        PDFDocument *document = nil;
        CGFloat maxDim = maxDimension.doubleValue > 0 ? maxDimension.doubleValue : 400;
        NSMutableArray<NSNumber *> *done = [NSMutableArray arrayWithCapacity:pages.count];
        for (NSNumber *index in pages) {
            NSString *outPath = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"pdfpage_%ld.jpg", (long)index.integerValue]];
            if ([files fileExistsAtPath:outPath]) { [done addObject:index]; continue; }
            if (!document) {
                document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:stripFileScheme(pdfPath)]];
                if (!document) {
                    reject(@"pdf_load_failed", @"Could not open PDF", nil);
                    return;
                }
            }
            if (index.integerValue < 0 || index.unsignedIntegerValue >= document.pageCount) continue;
            @autoreleasepool {
                PDFPage *page = [document pageAtIndex:index.unsignedIntegerValue];
                CGRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
                if (bounds.size.width <= 0 || bounds.size.height <= 0) continue;
                CGFloat scale = maxDim / MAX(bounds.size.width, bounds.size.height);
                CGSize size = CGSizeMake(round(bounds.size.width * scale), round(bounds.size.height * scale));
                UIImage *image = [page thumbnailOfSize:size forBox:kPDFDisplayBoxMediaBox];
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.8);
                if (jpeg && [jpeg writeToFile:outPath atomically:YES]) [done addObject:index];
            }
        }
        resolve(done);
    });
}

@end
