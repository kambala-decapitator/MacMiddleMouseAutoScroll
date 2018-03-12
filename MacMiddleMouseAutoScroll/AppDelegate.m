//
//  AppDelegate.m
//  MacMiddleMouseAutoScroll
//
//  Created by Andrey Filipenkov on 12/03/18.
//  Copyright © 2018 kambala. All rights reserved.
//

#import "AppDelegate.h"

@interface AppDelegate ()
@property (weak) IBOutlet NSWindow *window;
@property (nonatomic, weak) id monitor;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"accessibility enabled: %d", AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES})); // 10.9+

    self.monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent * _Nonnull event) {
        if (event.buttonNumber != 2) { // handle only middle button click
            return;
        }

        AXUIElementRef sysElement = AXUIElementCreateSystemWide(), curElement;
        AXUIElementCopyElementAtPosition(sysElement, NSEvent.mouseLocation.x, NSEvent.mouseLocation.y, &curElement);
        CFRelease(sysElement);

        while (curElement) {
            CFTypeRef role;
            AXUIElementCopyAttributeValue(curElement, kAXRoleAttribute, &role);
            BOOL isScrollArea = CFStringCompare(role, kAXScrollAreaRole, kNilOptions) == kCFCompareEqualTo;
            CFRelease(role);
            if (isScrollArea)
                break;

            AXUIElementRef parentElement;
            AXUIElementCopyAttributeValue(curElement, kAXParentAttribute, (CFTypeRef *)&parentElement);
            CFRelease(curElement);
            curElement = parentElement;
        }
        if (!curElement)
            return;

        AXUIElementRef scrollAreaElement = curElement;
        NSMutableString *attributesStr;
        CFArrayRef attributes;
        if (AXUIElementCopyAttributeNames(scrollAreaElement, &attributes) == kAXErrorSuccess) {
            attributesStr = [NSMutableString new];
            for (NSString *attribute in (__bridge NSArray *)attributes) {
                CFTypeRef value;
                BOOL hasValue = AXUIElementCopyAttributeValue(scrollAreaElement, (CFStringRef)attribute, &value) == kAXErrorSuccess;
                [attributesStr appendFormat:@"\n%@ = %@", attribute, value];
                if (hasValue)
                    CFRelease(value);
            }
            CFRelease(attributes);
        }
        NSLog(@"scrollarea %@ attributes:%@", scrollAreaElement, attributesStr);
        CFRelease(scrollAreaElement);
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSEvent removeMonitor:self.monitor];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
