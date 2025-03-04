@import Foundation;

// MARK: - CoreEmoji

typedef void* CEMEmojiTokenRef;

CEMEmojiTokenRef CEMEmojiTokenCreateWithString(NSString *string, void *preferredEmojiLocale);
CFStringRef CEMEmojiTokenCopyName(CEMEmojiTokenRef token, int flags);

// - MARK: EmojiFoundation

@interface EMFEmojiToken : NSObject <NSCopying, NSSecureCoding>
@property(copy, nonatomic) NSString *string;
@property(retain, nonatomic) NSString *localeIdentifier;
@property(readonly, nonatomic) int presentationStyle;
@end

// used to override query results (e.g. how "moof" returns both cow and dog: https://en.wikipedia.org/wiki/Dogcow)
@interface EMFQueryResultOverride : NSObject
- (instancetype)initWithOverridesArray:(NSArray *)overrides
                            searchType:NSUInteger
                              behavior:NSUinteger;
@property (nonatomic, readonly) NSString *description;
@property (nonatomic, readonly) NSArray *results;
@property (nonatomic, readonly) NSUInteger overrideSearchType;
@property (nonatomic, readonly) NSUInteger overrideBehavior;
@end

@interface EMFQueryResultOverrideList : NSObject {
    NSDictionary<NSString *, EMFQueryResultOverride *> *_overrideMap;
}
@end

@interface EMFEmojiSearchEngine : NSObject
@property (nonatomic, readonly) NSLocale *locale;
@property (nonatomic, readonly) id indexManager;
@property (nonatomic, readonly) id stringStemmer;
@property (nonatomic, readonly) EMFQueryResultOverrideList *overrideList;
// returns with nil if no asset bundle for locale
+ (bool)isLocaleSupported:(NSLocale * _Nonnull)locale;
- (instancetype _Nullable)initWithLocale:(NSLocale * _Nonnull)locale;
- (void)preheat;
- (NSArray *)performStringQuery:(NSString *)query;
@end

// MARK: - CharacterPicker

// doesn't return special characters, doesn't return stickers
@interface CPKDefaultDataSource : NSObject
+ (NSArray<NSString *> *)preferredLanguagesForSearch;
+ (void)emojiTokensForSearchString:(NSString *)query
                       inLanguages:(NSArray<NSString *> *)languages
                        maxResults:(unsigned long long)maximum
                        usingBlock:(void (^)(NSArray<EMFEmojiToken *> *results, bool stopped /* ? */))block NS_SWIFT_ASYNC(4);
+ (NSString *)localizedCharacterName:(NSString *)emoji;
@end

// returns both stickers, characters, and symbols, closest to Messages.app
@interface CPSearchManager : NSObject
+ (CPSearchManager *)sharedSearchManager;

// only available on macOS 15 and later
// https://github.com/blacktop/ipsw-diffs/blob/f5e0a0028bdfa2d74b362a2862ec36709b786675/15_0_24A5279h__vs_15_0_24A5289g/DYLIBS/CharacterPicker.md?plain=1#L91
- (void)searchForStickersEmojiAndCharactersWithSearchString:(NSString *)query
                                                   maxCount:(NSNumber *)count
                                      withCompletionHandler:(void (^)(NSArray<id> *results))block;
@end

// represents a sticker, character, or emoji
@protocol CPKCharacterEntity <NSObject>
@property (nonatomic, readonly) BOOL isSticker;
@property (nonatomic, readonly) NSUInteger glyphID;
@property (nonatomic, readonly) NSImage * _Nullable image;
@property (nonatomic, readonly) NSURL * _Nullable imageURL;
@property (nonatomic, readonly) id _Nullable textEquivalent;
@property (nonatomic, readonly) NSInteger numberOfSectionedCharacters;
@property (nonatomic, readonly) NSString *identifier;
@end

// testing function
void CPKAttemptQueryingCPSearchManager(NSString *query, void (^completionHandler)(NSArray/* <CPKCharacterEntity *> */ *results));
