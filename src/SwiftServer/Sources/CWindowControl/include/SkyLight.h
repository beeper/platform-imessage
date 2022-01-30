// https://github.com/tombell/skylight/blob/1b2c7c63cf4d321742ce277961d2bb27efcd44c1/Sources/SkyLight/SkyLight.h

#import <AppKit/AppKit.h>

#ifndef SKYLIGHT_H
#define SKYLIGHT_H

typedef int SLSConnectionID;
typedef size_t SLSSpaceID;
typedef NSObject SLSTransaction;

// Get the window ID for the given AXUIElementRef.
AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *vid);

// Get the connection ID for the default connection for this process.
int SLSMainConnectionID(void);

// Get the space ID for the currently active space.
uint64 SLSGetActiveSpace(SLSConnectionID cid);

// Add the given windows (window IDs) to the given spaces (space IDs).
void SLSAddWindowsToSpaces(SLSConnectionID cid, CFArrayRef window_list, CFArrayRef space_list);

// Remove the given windows (window IDs) from the given spaces (space IDs).
void SLSRemoveWindowsFromSpaces(SLSConnectionID cid, CFArrayRef window_list, CFArrayRef space_list);

// Move the given windows (window IDs) to the given space.
void SLSMoveWindowsToManagedSpace(SLSConnectionID cid, CFArrayRef window_list, SLSSpaceID sid);

// SLSTransactionAddWindowToSpaceAndRemoveFromSpaces

// Get the space ID for the currently active space for the given screen.
uint64 SLSManagedDisplayGetCurrentSpace(SLSConnectionID cid, CFStringRef uuid);

// Get all spaces (space IDs) in order.
CFArrayRef SLSCopyManagedDisplaySpaces(SLSConnectionID cid);

// Get all spaces (space IDs) for the given windows (window IDs).
CFArrayRef SLSCopySpacesForWindows(SLSConnectionID cid, int selector, CFArrayRef window_list);

/// Given an array of space IDs, each space is shown to the user.
void SLSShowSpaces(SLSConnectionID cid, CFArrayRef spaces);

/// Given an array of space IDs, each space is hidden from the user.
void SLSHideSpaces(SLSConnectionID cid, CFArrayRef spaces);

/// Removes and destroys the space corresponding to the given space ID.
void SLSSpaceDestroy(SLSConnectionID cid, SLSSpaceID sid);

// Get the type of space for the given space.
int SLSSpaceGetType(SLSConnectionID cid, uint64 sid);

// SLSTransactionCreate returns Optional(<SLSTransaction [0x600002300ac0] cid: 493239, data: 0x109664000, size: 0, capacity: 16384, valid>)
SLSTransaction* SLSTransactionCreate(SLSConnectionID cid);
int SLSTransactionCommit(SLSConnectionID cid, SLSTransaction* txID);

// these cause a SIGSEGV, hopper shows the same bytecode for all three functions
void SLSTransactionAddWindowToSpace(SLSConnectionID cid, CGWindowID window, SLSSpaceID space);
void SLSTransactionRemoveWindowFromSpace(SLSConnectionID cid, CGWindowID window, SLSSpaceID space);
void SLSTransactionRemoveWindowFromSpaces(SLSConnectionID cid, CGWindowID window, CFArrayRef spaces);
#endif
