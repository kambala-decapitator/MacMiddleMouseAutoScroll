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

@property (weak) id middleClickMonitor;
@property (weak) id anyClickMonitor;
@property (weak) id moveMonitor;

@property NSPoint middleClickLocation;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"accessibility enabled: %d", AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES})); // 10.9+
    [self installMiddleClickMonitor];

    NSTextField *l = [NSTextField new];
    l.editable = NO;
    [self.window.contentView addSubview:l];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSEvent removeMonitor:self.middleClickMonitor];
    [NSEvent removeMonitor:self.anyClickMonitor];
    [NSEvent removeMonitor:self.moveMonitor];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

#pragma mark - Private

- (NSTextField *)label {
    return self.window.contentView.subviews.firstObject;
}

- (void)installMiddleClickMonitor {
    __typeof__(self) __weak welf = self;
    self.middleClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent * _Nonnull event) {
        if (event.buttonNumber != 2) // handle only middle button click
            return;
        self.middleClickLocation = NSEvent.mouseLocation;

        AXUIElementRef sysElement = AXUIElementCreateSystemWide(), curElement;
        AXUIElementCopyElementAtPosition(sysElement, NSEvent.mouseLocation.x, NSEvent.mouseLocation.y, &curElement);
        CFRelease(sysElement);

        pid_t pid;
        AXUIElementGetPid(curElement, &pid);

        BOOL isScrollArea = NO;
        while (curElement)
        {
            CFTypeRef role;
            AXUIElementCopyAttributeValue(curElement, kAXRoleAttribute, &role);
            isScrollArea = CFStringCompare(role, kAXScrollAreaRole, kNilOptions) == kCFCompareEqualTo;
            CFRelease(role);
            if (isScrollArea)
            {
                CFRelease(curElement);
                break;
            }

            AXUIElementRef parentElement;
            AXUIElementCopyAttributeValue(curElement, kAXParentAttribute, (CFTypeRef *)&parentElement);
            CFRelease(curElement);
            curElement = parentElement;
        }
        if (!isScrollArea)
            return;

        // wheel1 - vertical, wheel2 - horizontal
        // > 0 - up/left, < 0 - down/right
        //        CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, -15);
        //        if (scrollEvent)
        //        {
        //            CGEventPost(kCGHIDEventTap, scrollEvent);
        //            CFRelease(scrollEvent);
        //        }

        __typeof__(welf) sself = welf;
        [sself label].stringValue = [@"captured " stringByAppendingFormat:@"%d", pid];
        [[sself label] sizeToFit];

        [NSEvent removeMonitor:sself.middleClickMonitor];
        sself.middleClickMonitor = nil;
        [sself installAnyClickOrWheelMonitor];
        [sself installMouseMoveMonitor];
    }];
}

- (void)installAnyClickOrWheelMonitor {
    __typeof__(self) __weak welf = self;
    self.anyClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel handler:^(NSEvent * _Nonnull event) {
        __typeof__(welf) sself = welf;
        [sself label].stringValue = @"released";
        [[sself label] sizeToFit];

        [NSEvent removeMonitor:sself.anyClickMonitor];
        sself.anyClickMonitor = nil;
        [NSEvent removeMonitor:sself.moveMonitor];
        sself.moveMonitor = nil;
        [sself installMiddleClickMonitor];
    }];
}

- (void)installMouseMoveMonitor {
    __typeof__(self) __weak welf = self;
    self.moveMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent * _Nonnull event) {
        if (event.subtype != NSEventSubtypeMouseEvent)
            return;

        NSString *direction;
        CGFloat xDiff = NSEvent.mouseLocation.x - self.middleClickLocation.x, yDiff = NSEvent.mouseLocation.y - self.middleClickLocation.y;
        if (fabs(xDiff) > fabs(yDiff))
            direction = xDiff > 0 ? @"right" : @"left";
        else
            direction = yDiff > 0 ? @"up" : @"down";

        __typeof__(welf) sself = welf;
        [sself label].stringValue = [@"move " stringByAppendingString:direction];
        [[sself label] sizeToFit];
    }];
}

@end
