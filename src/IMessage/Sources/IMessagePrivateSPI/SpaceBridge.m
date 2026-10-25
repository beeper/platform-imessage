#import "IMessagePrivateSPI.h"
#import <dlfcn.h>
#import <objc/message.h>

NSArray<NSNumber *> *IMPrivateSPISpacesForWindow(uint32_t windowID) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    CFArrayRef (*copy)(int, int, CFArrayRef) = dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
    if (!connection || !copy) return nil;
    return CFBridgingRelease(copy(connection(), 7, (__bridge CFArrayRef)@[@(windowID)]));
}

uint64_t IMPrivateSPIActiveSpace(void) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    uint64_t (*active)(int) = dlsym(RTLD_DEFAULT, "SLSGetActiveSpace");
    return connection && active ? active(connection()) : 0;
}

static id SpaceBridgeOperation(NSString *name, SEL initializer) {
    Class cls = NSClassFromString(name);
    if (!cls || ![cls instancesRespondToSelector:initializer]) return nil;
    return [cls alloc];
}

NSObject *IMPrivateSPISpaceBridgeCreate(void) {
    // Keep the image loaded while objects instantiated from it remain alive.
    static void *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    });
    if (!image) return nil;
    @try {
        Class cls = NSClassFromString(@"SLSWindowManagementFallbackBridge");
        if (![cls instancesRespondToSelector:NSSelectorFromString(@"performSynchronousBridgedWindowManagementOperation:")] ||
            ![cls instancesRespondToSelector:NSSelectorFromString(@"performAsynchronousBridgedWindowManagementOperation:")]) return nil;
        return [[cls alloc] init];
    } @catch (NSException *exception) { return nil; }
}

uint64_t IMPrivateSPISpaceBridgeCreateSpace(NSObject *bridge, NSDictionary *values) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithOptions:values:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedSpaceCreateOperation", initializer);
        if (!allocated) return 0;
        id operation = ((id (*)(id, SEL, unsigned, id))objc_msgSend)(allocated, initializer, 0, values);
        id result = ((id (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performSynchronousBridgedWindowManagementOperation:"), operation);
        SEL getter = NSSelectorFromString(@"spaceID");
        if (![result respondsToSelector:getter]) return 0;
        return ((uint64_t (*)(id, SEL))objc_msgSend)(result, getter);
    } @catch (NSException *exception) { return 0; }
}

BOOL IMPrivateSPISpaceBridgeMoveWindow(NSObject *bridge, uint32_t windowID, uint64_t spaceID) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithWindows:spaceID:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedMoveWindowsToManagedSpaceOperation", initializer);
        if (!allocated) return NO;
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(allocated, initializer, @[@(windowID)], spaceID);
        ((void (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performAsynchronousBridgedWindowManagementOperation:"), operation);
        return YES; // Accepted, not verified: the caller must read Space membership.
    } @catch (NSException *exception) { return NO; }
}

BOOL IMPrivateSPISpaceBridgeDestroySpace(NSObject *bridge, uint64_t spaceID) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithSpaceID:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedSpaceDestroyOperation", initializer);
        if (!allocated) return NO;
        id operation = ((id (*)(id, SEL, uint64_t))objc_msgSend)(allocated, initializer, spaceID);
        ((void (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performAsynchronousBridgedWindowManagementOperation:"), operation);
        return YES;
    } @catch (NSException *exception) { return NO; }
}
