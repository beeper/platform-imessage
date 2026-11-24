#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NSObject *_Nullable IMPrivateSPIPluginPayloadCreate(NSData *payloadData,
                                                    NSString *bundleID,
                                                    NSString *messageGUID,
                                                    BOOL isFromMe);

NSObject *_Nullable IMPrivateSPIPluginPayloadDataSourceCreate(NSString *className,
                                                              NSObject *payload);

NSObject *_Nullable IMPrivateSPIDigitalTouchControllerCreate(NSObject *dataSource,
                                                             BOOL isFromMe);

NSURL *_Nullable IMPrivateSPIDigitalTouchAssetURL(NSObject *controller);

BOOL IMPrivateSPIDigitalTouchCreateFallbackMedia(NSObject *controller,
                                                 void (^completion)(void));

NSObject *_Nullable IMPrivateSPIHandwritingFromPayload(NSObject *dataSource);

BOOL IMPrivateSPIHandwritingWriteThumbnail(NSString *rendererClassName,
                                           NSObject *handwriting,
                                           CGSize size,
                                           BOOL useHighFidelityInk,
                                           void (^completion)(NSURL *url));

NS_ASSUME_NONNULL_END
