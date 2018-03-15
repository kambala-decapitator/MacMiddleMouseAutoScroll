//
//  AppDelegate.m
//  MacMiddleMouseAutoScroll
//
//  Created by Andrey Filipenkov on 12/03/18.
//  Copyright © 2018 kambala. All rights reserved.
//

#import "AppDelegate.h"

static const CGFloat MinimumActivationDistanceFromClick = 10.0;

typedef enum : NSUInteger {
    AutoScrollDirectionUp,
    AutoScrollDirectionRight,
    AutoScrollDirectionDown,
    AutoScrollDirectionLeft
} AutoScrollDirection;

@interface AppDelegate ()
@property (weak) IBOutlet NSWindow *window;
@property (strong) NSStatusItem *statusItem;

@property (weak) id middleClickMonitor;
@property (weak) id anyClickMonitor;
@property (weak) id moveMonitor;

@property NSPoint middleClickLocation;
@property (weak) NSTimer *autoScrollTimer;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.menu = [[NSMenu alloc] initWithTitle:@""];
    [self.statusItem.menu addItemWithTitle:@"Show" action:@selector(showWindow) keyEquivalent:@""];
    [self.statusItem.menu addItem:NSMenuItem.separatorItem];
    [self.statusItem.menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];

    AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    [self installMiddleClickMonitor];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSEvent removeMonitor:self.middleClickMonitor];
    [NSEvent removeMonitor:self.anyClickMonitor];
    [self stopAutoScroll];
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
        // seems not possible: https://stackoverflow.com/a/45599806/1971301
        // AXClassName attribute is available only for Apple's private entitlement com.apple.private.accessibility.inspection
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

        [NSEvent removeMonitor:self.middleClickMonitor];
        self.middleClickMonitor = nil;
        [self installAnyClickOrWheelMonitor];
        [self installMouseMoveMonitor];

        self.statusItem.title = @"active";
    }];
}

- (void)installAnyClickOrWheelMonitor {
    self.anyClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown handler:^(NSEvent * _Nonnull event) {
        [NSEvent removeMonitor:self.anyClickMonitor];
        self.anyClickMonitor = nil;
        [self stopAutoScroll];
        [self installMiddleClickMonitor];
    }];
}

- (void)installMouseMoveMonitor {
    self.moveMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent * _Nonnull event) {
        if (event.subtype != NSEventSubtypeMouseEvent || self.autoScrollTimer)
            return;

        CGFloat xDiff = NSEvent.mouseLocation.x - self.middleClickLocation.x, xDiffAbs = fabs(xDiff);
        CGFloat yDiff = NSEvent.mouseLocation.y - self.middleClickLocation.y, yDiffAbs = fabs(yDiff);
        if (xDiffAbs < MinimumActivationDistanceFromClick && yDiffAbs < MinimumActivationDistanceFromClick)
            return;

        AutoScrollDirection direction;
        if (xDiffAbs > yDiffAbs)
            direction = xDiff > 0 ? AutoScrollDirectionRight : AutoScrollDirectionLeft;
        else
            direction = yDiff > 0 ? AutoScrollDirectionUp : AutoScrollDirectionDown;

        NSTimer *timer = [NSTimer timerWithTimeInterval:0.01 target:self selector:@selector(performAutoScroll) userInfo:@{@"direction": @(direction)} repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        self.autoScrollTimer = timer;

        [self postScrollWheelEventWithPhase:kCGScrollPhaseBegan];
    }];
}

- (void)postScrollWheelEventWithPhase:(CGScrollPhase)scrollPhase {
    AutoScrollDirection direction = [self.autoScrollTimer.userInfo[@"direction"] unsignedIntegerValue];
    BOOL isVerticalScroll = direction == AutoScrollDirectionUp || direction == AutoScrollDirectionDown;
    int32_t distance = (direction == AutoScrollDirectionDown || direction == AutoScrollDirectionRight ? -1 : 1) * 1;
    // wheel1 - vertical, wheel2 - horizontal
    // > 0 - up/left, < 0 - down/right
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, isVerticalScroll ? 1 : 2, isVerticalScroll ? distance : 0, isVerticalScroll ? 0 : distance);
    if (scrollEvent)
    {
        // synthesizing trackpad event ensures that Smooze app doesn't modify our scroll event
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, scrollPhase);
        CGEventPost(kCGSessionEventTap, scrollEvent);
        CFRelease(scrollEvent);
    }
}

- (void)performAutoScroll {
    [self postScrollWheelEventWithPhase:kCGScrollPhaseChanged];
}

- (void)stopAutoScroll {
    [self postScrollWheelEventWithPhase:kCGScrollPhaseEnded];

    [self.autoScrollTimer invalidate];
    self.autoScrollTimer = nil;

    [NSEvent removeMonitor:self.moveMonitor];
    self.moveMonitor = nil;
}

// https://developer.apple.com/library/content/samplecode/UIElementInspector/Listings/UIElementUtilities_m.html
- (CGPoint)carbonScreenPointFromCocoaScreenPoint:(NSPoint)cocoaPoint {
    NSScreen *screen = [NSScreen.screens filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSScreen *screen, NSDictionary<NSString *,id> *bindings) {
        return NSPointInRect(cocoaPoint, screen.frame);
    }]].firstObject;
    return screen ? CGPointMake(cocoaPoint.x, NSMaxY(screen.frame) - cocoaPoint.y - 1) : CGPointZero;
}

@end
