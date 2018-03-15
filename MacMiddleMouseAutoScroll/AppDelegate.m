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
@property (strong) NSStatusItem *statusItem;

@property (weak) id middleClickMonitor;
@property (weak) id anyClickMonitor;
@property (weak) id moveMonitor;

@property NSPoint middleClickLocation;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.menu = [[NSMenu alloc] initWithTitle:@""];
    [self.statusItem.menu addItemWithTitle:@"Show" action:@selector(showWindow) keyEquivalent:@""];
    [self.statusItem.menu addItem:NSMenuItem.separatorItem];
    [self.statusItem.menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];

    AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES}); // 10.9+
    [self installMiddleClickMonitor];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSEvent removeMonitor:self.middleClickMonitor];
    [NSEvent removeMonitor:self.anyClickMonitor];
    [NSEvent removeMonitor:self.moveMonitor];
}

#pragma mark - Actions

- (void)showWindow {
    [self.window setIsVisible:YES];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - Private

- (void)installMiddleClickMonitor {
    self.statusItem.title = @"passive";

    self.middleClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent * _Nonnull event) {
        if (event.buttonNumber != 2) // handle only middle button click
            return;
        if ([NSCursor.currentSystemCursor.image.TIFFRepresentation isEqualToData:NSCursor.pointingHandCursor.image.TIFFRepresentation]) // ignore clicking on links
            return;

        self.middleClickLocation = NSEvent.mouseLocation;

        CGPoint carbonPoint = [self carbonScreenPointFromCocoaScreenPoint:self.middleClickLocation];
        AXUIElementRef sysElement = AXUIElementCreateSystemWide(), curElement;
        AXUIElementCopyElementAtPosition(sysElement, carbonPoint.x, carbonPoint.y, &curElement);
        CFRelease(sysElement);

        // TODO: try to read element's objc class like Accessibility Inspector does
        // valid classes (from Safari): WKPDFPluginAccessibilityObject, WKAccessibilityWebPageObject
        BOOL isScrollArea = NO;
        while (curElement)
        {
            CFTypeRef role;
            if (AXUIElementCopyAttributeValue(curElement, kAXRoleAttribute, &role) == kAXErrorSuccess)
            {
                isScrollArea = CFStringCompare(role, kAXScrollAreaRole, kNilOptions) == kCFCompareEqualTo;
                CFRelease(role);
            }

            if (!isScrollArea)
            {
                // when Safari displays a PDF, it has "AXRoleDescription = PDF Content", but it's not contained in a scroll area
                CFTypeRef roleDesc;
                if (AXUIElementCopyAttributeValue(curElement, kAXRoleDescriptionAttribute, &roleDesc) == kAXErrorSuccess)
                {
                    isScrollArea = CFStringFind(roleDesc, CFSTR("pdf"), kCFCompareCaseInsensitive).length > 0;
                    CFRelease(roleDesc);
                }
            }
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

        [NSEvent removeMonitor:self.middleClickMonitor];
        self.middleClickMonitor = nil;
        [self installAnyClickOrWheelMonitor];
        [self installMouseMoveMonitor];

        self.statusItem.title = @"active";
    }];
}

- (void)installAnyClickOrWheelMonitor {
    self.anyClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel handler:^(NSEvent * _Nonnull event) {
        [NSEvent removeMonitor:self.anyClickMonitor];
        self.anyClickMonitor = nil;
        [NSEvent removeMonitor:self.moveMonitor];
        self.moveMonitor = nil;
        [self installMiddleClickMonitor];
    }];
}

- (void)installMouseMoveMonitor {
    self.moveMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent * _Nonnull event) {
        if (event.subtype != NSEventSubtypeMouseEvent)
            return;

        NSString *direction;
        CGFloat xDiff = NSEvent.mouseLocation.x - self.middleClickLocation.x, yDiff = NSEvent.mouseLocation.y - self.middleClickLocation.y;
        if (fabs(xDiff) > fabs(yDiff))
            direction = xDiff > 0 ? @"right" : @"left";
        else
            direction = yDiff > 0 ? @"up" : @"down";
    }];
}

- (void)dumpAttributesOfAXUIElement:(AXUIElementRef)element {
    NSLog(@"attributes of %@:", element);
    if (!element)
        return;

    typedef AXError(*AttributeNamesFn)(AXUIElementRef element, CFArrayRef __nullable * __nonnull CF_RETURNS_RETAINED names);
    NSString *(^dumpAttributes)(AttributeNamesFn f) = ^NSString *(AttributeNamesFn f) {
        CFArrayRef attributes;
        if (f(element, &attributes) != kAXErrorSuccess)
            return nil;

        NSMutableString *attributesStr = [NSMutableString new];
        for (NSString *attribute in (NSArray *)CFBridgingRelease(attributes)) {
            CFTypeRef value;
            AXUIElementCopyAttributeValue(element, (CFStringRef)attribute, &value);
            [attributesStr appendFormat:@"%@ = %@\n", attribute, value];
            if (value)
                CFRelease(value);
        }
        return attributesStr;
    };

    NSLog(@"simple: %@", dumpAttributes(AXUIElementCopyAttributeNames));
    NSLog(@"parametrized: %@", dumpAttributes(AXUIElementCopyParameterizedAttributeNames));
}

// https://developer.apple.com/library/content/samplecode/UIElementInspector/Listings/UIElementUtilities_m.html
- (CGPoint)carbonScreenPointFromCocoaScreenPoint:(NSPoint)cocoaPoint {
    NSScreen *screen = [NSScreen.screens filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSScreen *screen, NSDictionary<NSString *,id> *bindings) {
        return NSPointInRect(cocoaPoint, screen.frame);
    }]].firstObject;
    return screen ? CGPointMake(cocoaPoint.x, NSMaxY(screen.frame) - cocoaPoint.y - 1) : CGPointZero;
}

@end
