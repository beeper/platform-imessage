#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// typedstream payloads still need this deprecated decoder.
@interface _NSUnarchiver : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable instancetype)initForReadingWithData:(NSData *)data
    NS_SWIFT_NAME(init(forReadingWith:));

- (nullable id)decodeObject;

@end

NS_ASSUME_NONNULL_END
