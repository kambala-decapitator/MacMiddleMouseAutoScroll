//
//  AppDelegate.m
//  MacMiddleMouseAutoScroll
//
//  Created by Andrey Filipenkov on 12/03/18.
//  Copyright © 2018 kambala. All rights reserved.
//

#import "AppDelegate.h"

static const CGFloat MinimumActivationDistanceFromClick = 10.0;
static NSString *const SafariBundleIdentifier = @"com.apple.Safari";

static NSString *const IsAutoscrollEnabledDefaultsKey = @"enableAutoscroll";
static NSString *const IsInterceptingSafariTopSiteDefaultsKey = @"interceptSafariTopSite";

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

    self.window.title = [self.window.title stringByAppendingFormat:@" v%@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
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
    if (![self isAutoscrollEnabled] && ![self isInterceptingSafariTopSite])
        return;
    self.statusItem.title = @"passive";

    self.middleClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent * _Nonnull event) {
        if (event.buttonNumber != 2) // handle only middle button click
            return;
        if ([NSCursor.currentSystemCursor.image.TIFFRepresentation isEqualToData:NSCursor.pointingHandCursor.image.TIFFRepresentation]) // ignore clicking on links
            return;

        CGPoint carbonPoint = [self carbonScreenPointFromCocoaScreenPoint:NSEvent.mouseLocation];
        AXUIElementRef sysElement = AXUIElementCreateSystemWide(), clickedElement;
        AXUIElementCopyElementAtPosition(sysElement, carbonPoint.x, carbonPoint.y, &clickedElement);
        CFRelease(sysElement);
        if (!clickedElement)
            return;

        self.middleClickLocation = NSEvent.mouseLocation;

        // TODO: try to read element's objc class like Accessibility Inspector does
        // valid classes (from Safari): WKPDFPluginAccessibilityObject, WKAccessibilityWebPageObject
        // seems not possible: https://stackoverflow.com/a/45599806/1971301
        // AXClassName attribute is available only for Apple's private entitlement com.apple.private.accessibility.inspection
        BOOL isScrollArea = NO;
        AXUIElementRef curElement = CFRetain(clickedElement);
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
                break;

            AXUIElementRef parentElement = NULL;
            AXUIElementCopyAttributeValue(curElement, kAXParentAttribute, (CFTypeRef *)&parentElement);
            CFRelease(curElement);
            curElement = parentElement;
        }
        if (!isScrollArea)
        {
            CFRelease(clickedElement);
            return;
        }
        CFTypeRef clickedRole = NULL;

        // detect if middle-clicked on a Top Site or Bookmark in Safari
        if (![self isInterceptingSafariTopSite] || clickedElement == curElement)
            goto ENABLE_AUTOSCROLL;

        // sanity check that it's really Safari
        pid_t appPid = -1;
        AXUIElementGetPid(clickedElement, &appPid);
        if (appPid != -1 && ![[NSRunningApplication runningApplicationWithProcessIdentifier:appPid].bundleIdentifier isEqualToString:SafariBundleIdentifier])
            goto ENABLE_AUTOSCROLL;

        BOOL isTopSites = NO, isBookmarks = NO;
        CFTypeRef scrollAreaLabel;
        // this attribute is absent in Edit Bookmarks
        if (AXUIElementCopyAttributeValue(curElement, kAXDescriptionAttribute, &scrollAreaLabel) == kAXErrorSuccess)
        {
            isTopSites  = CFStringCompare(scrollAreaLabel, CFSTR("top sites"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
            isBookmarks = CFStringCompare(scrollAreaLabel, CFSTR("bookmarks"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
            CFRelease(scrollAreaLabel);
        }

        if (AXUIElementCopyAttributeValue(clickedElement, kAXRoleAttribute, &clickedRole) != kAXErrorSuccess)
            goto ENABLE_AUTOSCROLL;

        if (isTopSites)
        {
            // Top Site is a button that contains a label
            AXUIElementRef buttonElement = NULL;
            if (CFStringCompare(clickedRole, kAXStaticTextRole, kNilOptions) == kCFCompareEqualTo)
                AXUIElementCopyAttributeValue(clickedElement, kAXParentAttribute, (CFTypeRef *)&buttonElement);
            else
                buttonElement = CFRetain(clickedElement);
            if (!buttonElement)
                goto ENABLE_AUTOSCROLL;

            CFTypeRef buttonRoleDesc;
            AXError err = AXUIElementCopyAttributeValue(buttonElement, kAXRoleDescriptionAttribute, &buttonRoleDesc);
            CFRelease(buttonElement);
            if (err != kAXErrorSuccess)
                goto ENABLE_AUTOSCROLL;

            // verify that it's the proper element
            BOOL isTopSiteButton = CFStringCompare(buttonRoleDesc, CFSTR("Button"), kNilOptions) == kCFCompareEqualTo;
            CFRelease(buttonRoleDesc);
            if (isTopSiteButton)
                goto SEND_CMD_LEFTCLICK;
            else
                goto ENABLE_AUTOSCROLL;
        }
        else // probably it's bookmarks
        {
            if (!isBookmarks) // probably it's Edit Bookmarks
            {
                // check that one of scrollArea's children is named Bookmarks (with role AXOutline, but let's ignore that)
                CFArrayRef scrollAreaChildren;
                if (AXUIElementCopyAttributeValue(curElement, kAXChildrenAttribute, (CFTypeRef *)&scrollAreaChildren) != kAXErrorSuccess)
                    goto ENABLE_AUTOSCROLL;

                NSUInteger i = [CFBridgingRelease(scrollAreaChildren) indexOfObjectPassingTest:^BOOL(id _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    AXUIElementRef element = (__bridge AXUIElementRef)(obj);
                    CFTypeRef label;
                    if (AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute, &label) != kAXErrorSuccess)
                        return NO;

                    BOOL result = CFStringCompare(label, CFSTR("bookmarks"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
                    CFRelease(label);
                    return result;
                }];
                if (i == NSNotFound)
                    goto ENABLE_AUTOSCROLL;
                isBookmarks = YES;
            }

            if (CFStringCompare(clickedRole, kAXTextFieldRole, kNilOptions) == kCFCompareEqualTo)
                goto SEND_CMD_LEFTCLICK;
            else
                goto ENABLE_AUTOSCROLL;
        }

    SEND_CMD_LEFTCLICK: {
        NSUserDefaults *safariDefaults = [[NSUserDefaults alloc] initWithSuiteName:SafariBundleIdentifier];
        BOOL isNewTabWithCmdClick = [safariDefaults boolForKey:@"CommandClickMakesTabs"];

        BOOL(^postMouseEventWithType)(CGEventType) = ^BOOL(CGEventType mouseType) {
            CGEventRef mouseEvent = CGEventCreateMouseEvent(NULL, mouseType, carbonPoint, kCGMouseButtonLeft);
            if (!mouseEvent)
                return NO;

            CGEventFlags flags = kCGEventFlagMaskCommand;
            if (!isNewTabWithCmdClick)
                flags |= kCGEventFlagMaskAlternate;
            CGEventSetFlags(mouseEvent, flags);

            if (isBookmarks) // opening a bookmark in new tab requires double-click
                CGEventSetIntegerValueField(mouseEvent, kCGMouseEventClickState, 2);

            CGEventPost(kCGSessionEventTap, mouseEvent);
            CFRelease(mouseEvent);
            return YES;
        };
        if (postMouseEventWithType(kCGEventLeftMouseDown) && postMouseEventWithType(kCGEventLeftMouseUp))
            goto RELEASE_ELEMENTS;
    }

    ENABLE_AUTOSCROLL:
        if (![self isAutoscrollEnabled])
            goto RELEASE_ELEMENTS;

        [NSEvent removeMonitor:self.middleClickMonitor];
        self.middleClickMonitor = nil;
        [self installAnyClickMonitor];
        [self installMouseMoveMonitor];

        self.statusItem.title = @"active";

    RELEASE_ELEMENTS:
        if (clickedRole)
            CFRelease(clickedRole);
        CFRelease(curElement);
        CFRelease(clickedElement);
    }];
}

- (void)installAnyClickMonitor {
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

- (BOOL)isAutoscrollEnabled {
    return [[NSUserDefaultsController.sharedUserDefaultsController.values valueForKey:IsAutoscrollEnabledDefaultsKey] boolValue];
}

- (BOOL)isInterceptingSafariTopSite {
    return [[NSUserDefaultsController.sharedUserDefaultsController.values valueForKey:IsInterceptingSafariTopSiteDefaultsKey] boolValue];
}

@end
