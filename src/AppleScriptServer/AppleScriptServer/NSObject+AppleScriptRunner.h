#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppleScriptRunner:NSObject

@property NSDictionary *scripts;

- (void) generateJSON;
- (void) loadFromEmbeddedJSON;
- (void) loadScripts: (NSURL *)directory;
- (NSData *) executeScript: (NSString *)name :(NSString *)tag :(NSArray *)args;

@end

NS_ASSUME_NONNULL_END
