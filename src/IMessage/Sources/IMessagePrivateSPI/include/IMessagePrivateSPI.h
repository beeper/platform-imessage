#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime-resolved SkyLight bridge. No private symbol addresses or injections.
NSObject *_Nullable IMPrivateSPISpaceBridgeCreate(void);
uint64_t IMPrivateSPISpaceBridgeCreateSpace(NSObject *bridge, NSDictionary *values);
/// Creates an unknown, unmanaged Space using creation option 1, with no Dock owner metadata.
uint64_t IMPrivateSPISpaceBridgeCreateUnknownSpace(NSObject *bridge, NSString *uuid);
/// Enqueues unknown membership addition; existing memberships must be removed separately and verified.
BOOL IMPrivateSPISpaceBridgeAddWindowToUnknownSpace(NSObject *bridge, uint32_t windowID, uint64_t spaceID);
/// Enqueues membership removal; success means accepted, not independently verified.
BOOL IMPrivateSPISpaceBridgeRemoveWindowFromSpaces(NSObject *bridge, uint32_t windowID, NSArray<NSNumber *> *spaces);
BOOL IMPrivateSPISpaceBridgeMoveWindow(NSObject *bridge, uint32_t windowID, uint64_t spaceID);
BOOL IMPrivateSPISpaceBridgeDestroySpace(NSObject *bridge, uint64_t spaceID);
/// Includes unknown/OS Spaces (mask 15), unlike the legacy mask-7 query.
NSArray<NSNumber *> *_Nullable IMPrivateSPISpacesForWindow(uint32_t windowID);
uint64_t IMPrivateSPIActiveSpace(void);
NSArray<NSDictionary *> *_Nullable IMPrivateSPICopyManagedDisplaySpaces(void);
/// Reads the intrinsic Space type; -1 means the binding or WindowServer connection is unavailable.
int32_t IMPrivateSPISpaceType(uint64_t spaceID);
/// Copies Space metadata independently of its type; nil means the read failed.
NSDictionary *_Nullable IMPrivateSPICopySpaceValues(uint64_t spaceID);

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
