#import "IMessagePrivateSPI.h"
#import <objc/message.h>

NSObject *_Nullable IMPrivateSPIPluginPayloadCreate(NSData *payloadData,
                                                    NSString *bundleID,
                                                    NSString *messageGUID,
                                                    BOOL isFromMe) {
    Class payloadClass = NSClassFromString(@"IMPluginPayload");
    if (payloadClass == nil) {
        return nil;
    }

    NSObject *payload = [[payloadClass alloc] init];
    [payload setValue:payloadData forKey:@"data"];
    [payload setValue:bundleID forKey:@"pluginBundleID"];
    [payload setValue:messageGUID forKey:@"messageGUID"];
    [payload setValue:@(isFromMe) forKey:@"isFromMe"];
    return payload;
}

NSObject *_Nullable IMPrivateSPIPluginPayloadDataSourceCreate(NSString *className,
                                                              NSObject *payload) {
    Class dataSourceClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(@"initWithPluginPayload:");
    if (dataSourceClass == nil || ![dataSourceClass instancesRespondToSelector:selector]) {
        return nil;
    }

    id allocated = [dataSourceClass alloc];
    return ((id (*)(id, SEL, id))objc_msgSend)(allocated, selector, payload);
}

NSObject *_Nullable IMPrivateSPIDigitalTouchControllerCreate(NSObject *dataSource,
                                                             BOOL isFromMe) {
    Class controllerClass = NSClassFromString(@"ETMacBalloonPluginController");
    SEL selector = NSSelectorFromString(@"initWithDataSource:isFromMe:");
    if (controllerClass == nil || ![controllerClass instancesRespondToSelector:selector]) {
        return nil;
    }

    id allocated = [controllerClass alloc];
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)(allocated, selector, dataSource, isFromMe);
}

NSURL *_Nullable IMPrivateSPIDigitalTouchAssetURL(NSObject *controller) {
    SEL selector = NSSelectorFromString(@"getAssetURL");
    if (![controller respondsToSelector:selector]) {
        return nil;
    }

    return ((NSURL *(*)(id, SEL))objc_msgSend)(controller, selector);
}

BOOL IMPrivateSPIDigitalTouchCreateFallbackMedia(NSObject *controller,
                                                 void (^completion)(void)) {
    SEL selector = NSSelectorFromString(@"_createFallbackMediaWithCompletion:");
    if (![controller respondsToSelector:selector]) {
        return NO;
    }

    ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(controller, selector, completion);
    return YES;
}

NSObject *_Nullable IMPrivateSPIHandwritingFromPayload(NSObject *dataSource) {
    SEL selector = NSSelectorFromString(@"handwritingFromPayload");
    if (![dataSource respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(dataSource, selector);
}

BOOL IMPrivateSPIHandwritingWriteThumbnail(NSString *rendererClassName,
                                           NSObject *handwriting,
                                           CGSize size,
                                           BOOL useHighFidelityInk,
                                           void (^completion)(NSURL *url)) {
    Class rendererClass = NSClassFromString(rendererClassName);
    SEL selector = NSSelectorFromString(@"_writeThumbnailOfHandwriting:atSize:useHighFidelityInk:toDiskWithCompletionHandler:");
    if (rendererClass == nil || ![rendererClass respondsToSelector:selector]) {
        return NO;
    }

    ((void (*)(id, SEL, id, CGSize, BOOL, void (^)(NSURL *)))objc_msgSend)(
        rendererClass,
        selector,
        handwriting,
        size,
        useHighFidelityInk,
        completion
    );
    return YES;
}
