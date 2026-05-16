#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IMPluginPayload : NSObject
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSString *pluginBundleID;
@property (nonatomic, copy) NSString *messageGUID;
@property (nonatomic) BOOL isFromMe;
@end

@interface ETBalloonPluginDataSource : NSObject
- (instancetype)initWithPluginPayload:(IMPluginPayload *)payload NS_SWIFT_NAME(init(pluginPayload:));
@end

@interface ETMacBalloonPluginController : NSObject
- (instancetype)initWithDataSource:(ETBalloonPluginDataSource *)dataSource
                          isFromMe:(BOOL)isFromMe NS_SWIFT_NAME(init(dataSource:isFromMe:));
- (NSURL *_Nullable)getAssetURL;
- (void)_createFallbackMediaWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(createFallbackMedia(completion:));
@end

@interface HWBalloonDataSource : NSObject
- (instancetype)initWithPluginPayload:(IMPluginPayload *)payload NS_SWIFT_NAME(init(pluginPayload:));
- (id _Nullable)handwritingFromPayload;
@end

@interface HWAbstractBalloonController : NSObject
+ (void)_writeThumbnailOfHandwriting:(id)handwriting
                              atSize:(CGSize)size
                  useHighFidelityInk:(BOOL)useHighFidelityInk
          toDiskWithCompletionHandler:(void (^)(NSURL *url))completion
    NS_SWIFT_NAME(writeThumbnail(of:atSize:useHighFidelityInk:completion:));
@end

NS_ASSUME_NONNULL_END
