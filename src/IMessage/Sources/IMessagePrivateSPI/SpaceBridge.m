#import "IMessagePrivateSPI.h"
#import <dlfcn.h>
#import <objc/message.h>

NSArray<NSNumber *> *IMPrivateSPISpacesForWindow(uint32_t windowID) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    CFArrayRef (*copy)(int, int, CFArrayRef) = dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
    if (!connection || !copy) return nil;
    // Mask 7 omits unknown Spaces; include OS Spaces for independent readback.
    return CFBridgingRelease(copy(connection(), 15, (__bridge CFArrayRef)@[@(windowID)]));
}

uint64_t IMPrivateSPIActiveSpace(void) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    uint64_t (*active)(int) = dlsym(RTLD_DEFAULT, "SLSGetActiveSpace");
    return connection && active ? active(connection()) : 0;
}

NSArray<NSDictionary *> *IMPrivateSPICopyManagedDisplaySpaces(void) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    CFArrayRef (*copy)(int) = dlsym(RTLD_DEFAULT, "SLSCopyManagedDisplaySpaces");
    if (!connection || !copy) return nil;
    return CFBridgingRelease(copy(connection()));
}

int32_t IMPrivateSPISpaceType(uint64_t spaceID) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    int32_t (*type)(int, uint64_t) = dlsym(RTLD_DEFAULT, "SLSSpaceGetType");
    if (!connection || !type) return -1;
    int client = connection();
    return client ? type(client, spaceID) : -1;
}

NSDictionary *_Nullable IMPrivateSPICopySpaceValues(uint64_t spaceID) {
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    CFDictionaryRef (*copy)(int, uint64_t) = dlsym(RTLD_DEFAULT, "SLSSpaceCopyValues");
    if (!connection || !copy) return nil;
    int client = connection();
    return client ? CFBridgingRelease(copy(client, spaceID)) : nil;
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

static uint64_t SpaceBridgeCreateSpaceWithOptions(NSObject *bridge, uint32_t options, NSDictionary *values) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithOptions:values:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedSpaceCreateOperation", initializer);
        if (!allocated) return 0;
        id operation = ((id (*)(id, SEL, uint32_t, id))objc_msgSend)(allocated, initializer, options, values);
        id result = ((id (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performSynchronousBridgedWindowManagementOperation:"), operation);
        SEL getter = NSSelectorFromString(@"spaceID");
        if (![result respondsToSelector:getter]) return 0;
        return ((uint64_t (*)(id, SEL))objc_msgSend)(result, getter);
    } @catch (NSException *exception) { return 0; }
}

uint64_t IMPrivateSPISpaceBridgeCreateSpace(NSObject *bridge, NSDictionary *values) {
    return SpaceBridgeCreateSpaceWithOptions(bridge, 0, values);
}

uint64_t IMPrivateSPISpaceBridgeCreateUnknownSpace(NSObject *bridge, NSString *uuid) {
    // Option 1 creates an intrinsically unknown Space. A type=3 dictionary
    // with option 0 still creates a managed user Space on current macOS.
    return SpaceBridgeCreateSpaceWithOptions(bridge, 1, @{@"type": @3, @"uuid": uuid});
}

BOOL IMPrivateSPISpaceBridgeAddWindowToUnknownSpace(NSObject *bridge, uint32_t windowID, uint64_t spaceID) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithSpaceID:windows:options:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation", initializer);
        if (!allocated) return NO;
        id operation = ((id (*)(id, SEL, uint64_t, id, uint32_t))objc_msgSend)(allocated, initializer,
            spaceID, @[@(windowID)], 0);
        if (!operation) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performAsynchronousBridgedWindowManagementOperation:"), operation);
        return YES; // Accepted, not verified; managed memberships remain until explicitly removed.
    } @catch (NSException *exception) { return NO; }
}

BOOL IMPrivateSPISpaceBridgeRemoveWindowFromSpaces(NSObject *bridge, uint32_t windowID, NSArray<NSNumber *> *spaces) {
    @try {
        SEL initializer = NSSelectorFromString(@"initWithWindows:spaces:");
        id allocated = SpaceBridgeOperation(@"SLSBridgedRemoveWindowsFromSpacesOperation", initializer);
        if (!allocated) return NO;
        id operation = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, initializer, @[@(windowID)], spaces);
        if (!operation) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(bridge,
            NSSelectorFromString(@"performAsynchronousBridgedWindowManagementOperation:"), operation);
        return YES; // Accepted, not verified: the caller must read Space membership.
    } @catch (NSException *exception) { return NO; }
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
