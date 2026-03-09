
#import "MyPDFKitToolPickerModel.h"

@implementation MyPDFKitToolPickerModel

// Singleton pattern
+ (instancetype)sharedInstance {
    static MyPDFKitToolPickerModel *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[MyPDFKitToolPickerModel alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _toolPicker = [[PKToolPicker alloc] init];
        if (@available(iOS 14.0, *)) {
            _toolPicker.showsDrawingPolicyControls = YES;
        }
    }
    return self;
}

@end
