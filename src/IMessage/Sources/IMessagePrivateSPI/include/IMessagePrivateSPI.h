#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime-resolved SkyLight bridge. No private symbol addresses or injections.
NSObject *_Nullable IMPrivateSPISpaceBridgeCreate(void);
uint64_t IMPrivateSPISpaceBridgeCreateSpace(NSObject *bridge, NSDictionary *values);
BOOL IMPrivateSPISpaceBridgeMoveWindow(NSObject *bridge, uint32_t windowID, uint64_t spaceID);
BOOL IMPrivateSPISpaceBridgeDestroySpace(NSObject *bridge, uint64_t spaceID);
NSArray<NSNumber *> *_Nullable IMPrivateSPISpacesForWindow(uint32_t windowID);
uint64_t IMPrivateSPIActiveSpace(void);
NSArray<NSDictionary *> *_Nullable IMPrivateSPICopyManagedDisplaySpaces(void);

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
