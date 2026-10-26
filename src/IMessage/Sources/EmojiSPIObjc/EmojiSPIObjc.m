#import "EmojiSPIObjc.h"

@interface EMFEmojiToken : NSObject
- (instancetype _Nullable)initWithString:(NSString *)string localeIdentifier:(NSString *)localeIdentifier;
@end

@interface CPKDefaultDataSource : NSObject
+ (NSArray<NSString *> *)preferredLanguagesForSearch;
+ (void)emojiTokensForSearchString:(NSString *)query
                       inLanguages:(NSArray<NSString *> *)languages
                        maxResults:(NSUInteger)maximum
                        usingBlock:(void (^)(NSArray *results, BOOL stopped))block;
@end

@interface NSObject (EmojiSPITokenString)
- (NSString *)string;
@end

NSArray<NSString *> *_Nullable EmojiSPIPickerSearch(Class objectClass, NSString *query) {
    // This wrapper is called on the Messages automation queue, never the main
    // queue: CharacterPicker may need the main queue to deliver its callback.
    if ([NSThread isMainThread]) { return nil; }
    if (![objectClass respondsToSelector:@selector(preferredLanguagesForSearch)] ||
        ![objectClass respondsToSelector:@selector(emojiTokensForSearchString:inLanguages:maxResults:usingBlock:)]) {
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray<NSString *> *strings = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [objectClass emojiTokensForSearchString:query
                                   inLanguages:[objectClass preferredLanguagesForSearch]
                                    maxResults:500
                                    usingBlock:^(NSArray *results, BOOL stopped) {
            if (![results isKindOfClass:NSArray.class]) { dispatch_semaphore_signal(semaphore); return; }
            NSMutableArray<NSString *> *values = [NSMutableArray array];
            for (id token in results) {
                // The caller navigates by result index. Dropping a token would
                // shift subsequent positions and could select a different emoji.
                if (![token respondsToSelector:@selector(string)]) { values = nil; break; }
                NSString *value = [token string];
                if (![value isKindOfClass:NSString.class] || value.length == 0) { values = nil; break; }
                [values addObject:value];
            }
            @synchronized (semaphore) { strings = [values copy]; }
            dispatch_semaphore_signal(semaphore);
        }];
    });
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        return nil;
    }
    @synchronized (semaphore) { return strings; }
}

NSObject *_Nullable EmojiSPITokenCreate(Class objectClass,
                                       NSString *string,
                                       NSString *localeIdentifier) {
    return [(EMFEmojiToken *)[objectClass alloc] initWithString:string localeIdentifier:localeIdentifier];
}
