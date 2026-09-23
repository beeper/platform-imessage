#import "EmojiSPIObjc.h"

@interface EMFEmojiToken : NSObject
- (instancetype _Nullable)initWithString:(NSString *)string localeIdentifier:(NSString *)localeIdentifier;
@end

@interface EMFEmojiSearchEngine : NSObject
- (instancetype _Nullable)initWithLocale:(NSLocale *)locale;
@end

NSObject *_Nullable EmojiSPITokenCreate(Class objectClass,
                                       NSString *string,
                                       NSString *localeIdentifier) {
    return [(EMFEmojiToken *)[objectClass alloc] initWithString:string localeIdentifier:localeIdentifier];
}

NSObject *_Nullable EmojiSPISearchEngineCreate(Class objectClass,
                                              NSLocale *locale) {
    return [(EMFEmojiSearchEngine *)[objectClass alloc] initWithLocale:locale];
}
