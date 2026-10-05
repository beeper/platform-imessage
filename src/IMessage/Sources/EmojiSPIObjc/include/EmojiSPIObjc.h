#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The caller must verify that objectClass implements the initializer.
NSObject *_Nullable EmojiSPITokenCreate(Class objectClass,
                                       NSString *string,
                                       NSString *localeIdentifier);

NSObject *_Nullable EmojiSPISearchEngineCreate(Class objectClass,
                                              NSLocale *locale);

NS_ASSUME_NONNULL_END

// Returns nil when search is unavailable or its callback times out.
NSArray<NSString *> *_Nullable EmojiSPIPickerSearch(Class _Nonnull objectClass,
                                                   NSString *_Nonnull query);
