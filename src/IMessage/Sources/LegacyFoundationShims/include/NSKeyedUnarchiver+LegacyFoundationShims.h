#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSKeyedUnarchiver (LegacyFoundationShims)

// underscore marks the deprecated keyed unarchive path.
+ (nullable id)_unarchiveTopLevelObjectWithData:(NSData *)data error:(NSError **)error
    NS_SWIFT_NAME(_unarchiveTopLevelObjectWithData(_:));

@end

NS_ASSUME_NONNULL_END
