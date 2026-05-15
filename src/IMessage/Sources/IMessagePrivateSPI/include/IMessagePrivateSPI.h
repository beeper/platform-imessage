#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSObject (IMessagePrivateSPI)
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSString *pluginBundleID;
@property (nonatomic, copy) NSString *messageGUID;
@property (nonatomic) BOOL isFromMe;

- (instancetype)initWithPluginPayload:(id)payload NS_SWIFT_NAME(init(pluginPayload:));
- (instancetype)initWithDataSource:(id)dataSource
                          isFromMe:(BOOL)isFromMe NS_SWIFT_NAME(init(dataSource:isFromMe:));
- (NSURL *_Nullable)getAssetURL;
- (void)_createFallbackMediaWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(createFallbackMedia(completion:));
- (id _Nullable)handwritingFromPayload;

+ (void)_writeThumbnailOfHandwriting:(id)handwriting
                              atSize:(CGSize)size
                  useHighFidelityInk:(BOOL)useHighFidelityInk
          toDiskWithCompletionHandler:(void (^)(NSURL *url))completion
    NS_SWIFT_NAME(writeThumbnail(of:atSize:useHighFidelityInk:completion:));
@end

NS_ASSUME_NONNULL_END
