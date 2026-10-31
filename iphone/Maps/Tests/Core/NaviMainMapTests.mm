#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "MapsAppDelegate.h"
#import "MapViewController.h"
#import <CoreApi/Framework.h>

namespace {
UIView * FindNaviControl(UIView * root, NSString * identifier) {
  if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
  for (UIView * child in root.subviews) if (UIView * found = FindNaviControl(child, identifier)) return found;
  return nil;
}
void AwaitNaviUI(NSDate * deadline, BOOL (^condition)(void), void (^completion)(BOOL)) {
  if (condition()) { completion(YES); return; }
  if ([deadline timeIntervalSinceNow] <= 0) { completion(NO); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    AwaitNaviUI(deadline, condition, completion);
  });
}
}
@interface NaviMainMapTests : XCTestCase
@end
@implementation NaviMainMapTests
- (void)captureWindow:(UIWindow *)window name:(NSString *)name {
  UIGraphicsImageRenderer * renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
  UIImage * image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * context) {
    [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
  }];
  XCTAttachment * attachment = [XCTAttachment attachmentWithImage:image];
  attachment.name = name; attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
  [self addAttachment:attachment];
}
- (void)testMainMapOpensFriendsWithoutAnAccountOrLegacyRenderer {
  XCTestExpectation * finished = [self expectationWithDescription:@"Real main map Friends action"];
  dispatch_async(dispatch_get_main_queue(), ^{
    MapsAppDelegate * app = MapsAppDelegate.theApp;
    MapViewController * root = app.mapViewController;
    [root loadViewIfNeeded];
    XCTAssertNotNil(root); XCTAssertTrue(root.usesExternalMap);
    XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
    UIButton * friends = (UIButton *)FindNaviControl(root.view, @"navi-friends");
    XCTAssertTrue([friends isKindOfClass:UIButton.class]);
    XCTAssertTrue(friends.enabled);
    XCTAssertNotNil(app.window);
    if (!root || !friends || !app.window) { [finished fulfill]; return; }
    [self captureWindow:app.window name:@"main-map"];
    [friends sendActionsForControlEvents:UIControlEventTouchUpInside];
    AwaitNaviUI([NSDate dateWithTimeIntervalSinceNow:6], ^BOOL {
      return FindNaviControl(root.presentedViewController.view, @"friends.group.setup") != nil;
    }, ^(BOOL ready) {
      XCTAssertTrue(ready, @"Main-map action did not open the actual group setup sheet");
      if (ready) [self captureWindow:app.window name:@"main-friends-unconfigured"];
      XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
      if (root.presentedViewController) [root dismissViewControllerAnimated:NO completion:^{ [finished fulfill]; }];
      else [finished fulfill];
    });
  });
  [self waitForExpectationsWithTimeout:12 handler:nil];
}
@end
