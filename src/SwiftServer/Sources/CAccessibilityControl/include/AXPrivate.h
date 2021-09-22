#ifndef AXPrivate_h
#define AXPrivate_h

#import <ApplicationServices/ApplicationServices.h>

AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outID);

#endif /* AXPrivate_h */
