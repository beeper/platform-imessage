#import "NSKeyedUnarchiver+LegacyFoundationShims.h"

@implementation NSKeyedUnarchiver (LegacyFoundationShims)

+ (nullable id)_unarchiveTopLevelObjectWithData:(NSData *)data error:(NSError **)error {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:error];
#pragma clang diagnostic pop
}

@end
