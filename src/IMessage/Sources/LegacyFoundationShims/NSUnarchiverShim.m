#import "NSUnarchiverShim.h"

@implementation _NSUnarchiver {
    id _unarchiver;
}

- (nullable instancetype)initForReadingWithData:(NSData *)data {
    self = [super init];
    if (self == nil) {
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
#pragma clang diagnostic pop

    if (_unarchiver == nil) {
        return nil;
    }
    return self;
}

- (nullable id)decodeObject {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [_unarchiver decodeObject];
#pragma clang diagnostic pop
}

@end
