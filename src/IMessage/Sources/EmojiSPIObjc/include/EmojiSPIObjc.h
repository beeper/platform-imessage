#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The caller must verify that objectClass implements the initializer.
NSObject *_Nullable EmojiSPITokenCreate(Class objectClass,
                                       NSString *string,
                                       id localeIdentifier);

NSObject *_Nullable EmojiSPISearchEngineCreate(Class objectClass,
                                              NSLocale *locale);

NS_ASSUME_NONNULL_END
