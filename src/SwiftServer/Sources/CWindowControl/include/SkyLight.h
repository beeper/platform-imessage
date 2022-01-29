// https://github.com/tombell/skylight/blob/1b2c7c63cf4d321742ce277961d2bb27efcd44c1/Sources/SkyLight/SkyLight.h

#import <AppKit/AppKit.h>

#ifndef SKYLIGHT_H
#define SKYLIGHT_H

// Get the window ID for the given AXUIElementRef.
AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *vid);

// Get the connection ID for the default connection for this process.
int SLSMainConnectionID(void);

// Get the space ID for the currently active space.
uint64 SLSGetActiveSpace(int cid);

// Add the given windows (window IDs) to the given spaces (space IDs).
void SLSAddWindowsToSpaces(int cid, CFArrayRef window_list, CFArrayRef space_list);

// Remove the given windows (window IDs) from the given spaces (space IDs).
void SLSRemoveWindowsFromSpaces(int cid, CFArrayRef window_list, CFArrayRef space_list);

// Move the given windows (window IDs) to the given space.
void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);

// Get the space ID for the currently active space for the given screen.
uint64 SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);

// Get all spaces (space IDs) in order.
CFArrayRef SLSCopyManagedDisplaySpaces(int cid);

// Get all spaces (space IDs) for the given windows (window IDs).
CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);

// Get the type of space for the given space.
int SLSSpaceGetType(int cid, uint64 sid);

#endif
