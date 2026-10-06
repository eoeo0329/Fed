#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface FSOverlayRootViewController : UIViewController
@end

@interface FSAdAccelManager : NSObject

@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *skipButton;
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSHashTable<AVPlayer *> *trackedPlayers;
@property (nonatomic, weak) UIViewController *activeAdController;
@property (nonatomic, weak) id activeRewardObject;
@property (nonatomic, weak) id activeRewardDelegate;
@property (nonatomic, assign) BOOL overlayVisible;
@property (nonatomic, assign) BOOL multiTouchArmed;
@property (nonatomic, assign) CGFloat targetPlaybackRate;

+ (instancetype)sharedInstance;
- (void)handleApplicationEvent:(UIEvent *)event;
- (void)capturePotentialRewardContextFromObject:(id)object;
- (void)captureDelegate:(id)delegate forRewardObject:(id)object;
- (void)registerPlayer:(AVPlayer *)player;
- (void)applyConfiguredRateToPlayer:(AVPlayer *)player;
- (float)patchedRateForRate:(float)rate;

@end

static id FSInvokeObjectGetter(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnLength != sizeof(id)) {
        return nil;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];
    [invocation invoke];

    __unsafe_unretained id returnValue = nil;
    [invocation getReturnValue:&returnValue];
    return returnValue;
}

static void FSInvokeCallback(id target, NSString *selectorName, id firstArg, id secondArg) {
    if (!target || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (!selector || ![target respondsToSelector:selector]) {
        return;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) {
        return;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];

    if (signature.numberOfArguments > 2) {
        id arg = firstArg;
        [invocation setArgument:&arg atIndex:2];
    }
    if (signature.numberOfArguments > 3) {
        id arg = secondArg;
        [invocation setArgument:&arg atIndex:3];
    }

    [invocation invoke];
}

static BOOL FSClassNameLooksLikeRewardedAd(NSString *className) {
    if (className.length == 0) {
        return NO;
    }

    NSString *lower = className.lowercaseString;
    NSArray<NSString *> *keywords = @[
        @"reward",
        @"incent",
        @"excitation",
        @"videoad",
        @"rewarded",
        @"advert",
        @"adview"
    ];

    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) {
            return YES;
        }
    }

    return NO;
}

@implementation FSOverlayRootViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end

@implementation FSAdAccelManager

+ (instancetype)sharedInstance {
    static FSAdAccelManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackedPlayers = [NSHashTable weakObjectsHashTable];
        _targetPlaybackRate = 0.0;
    }
    return self;
}

- (void)handleApplicationEvent:(UIEvent *)event {
    if (!event || event.type != UIEventTypeTouches) {
        return;
    }

    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count == 0) {
        self.multiTouchArmed = NO;
        return;
    }

    NSUInteger activeTouchCount = 0;
    BOOL hasNewTouch = NO;
    for (UITouch *touch in touches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            activeTouchCount += 1;
        }
        if (touch.phase == UITouchPhaseBegan) {
            hasNewTouch = YES;
        }
    }

    if (activeTouchCount >= 3 && hasNewTouch && !self.multiTouchArmed) {
        self.multiTouchArmed = YES;
        [self toggleOverlay];
    } else if (activeTouchCount < 3) {
        self.multiTouchArmed = NO;
    }
}

- (void)capturePotentialRewardContextFromObject:(id)object {
    if (!object) {
        return;
    }

    self.activeRewardObject = object;

    if ([object isKindOfClass:[UIViewController class]]) {
        self.activeAdController = (UIViewController *)object;
    }

    id delegate = FSInvokeObjectGetter(object, NSSelectorFromString(@"delegate"));
    if (!delegate) {
        delegate = FSInvokeObjectGetter(object, NSSelectorFromString(@"rewardedVideoDelegate"));
    }
    if (!delegate) {
        delegate = FSInvokeObjectGetter(object, NSSelectorFromString(@"fullScreenContentDelegate"));
    }
    if (delegate) {
        self.activeRewardDelegate = delegate;
    }
}

- (void)captureDelegate:(id)delegate forRewardObject:(id)object {
    if (delegate) {
        self.activeRewardDelegate = delegate;
    }
    if (object) {
        self.activeRewardObject = object;
    }
}

- (UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

- (void)buildOverlayIfNeeded {
    if (self.overlayWindow) {
        return;
    }

    CGRect frame = UIScreen.mainScreen.bounds;
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene) {
            window = [[UIWindow alloc] initWithWindowScene:scene];
            window.frame = frame;
        }
    }

    if (!window) {
        window = [[UIWindow alloc] initWithFrame:frame];
    }

    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelAlert + 1000.0;
    window.hidden = NO;

    FSOverlayRootViewController *rootViewController = [[FSOverlayRootViewController alloc] init];
    rootViewController.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = rootViewController;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(20.0, 140.0, 176.0, 124.0)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    panel.layer.cornerRadius = 14.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18].CGColor;
    panel.clipsToBounds = YES;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 10.0, 152.0, 18.0)];
    titleLabel.text = @"广告控制台";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [panel addSubview:titleLabel];

    UIButton *skipButton = [self configuredButtonWithTitle:@"跳过激励广告"];
    skipButton.frame = CGRectMake(12.0, 36.0, 152.0, 32.0);
    [skipButton addTarget:self action:@selector(skipCurrentRewardedAd) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:skipButton];

    UIButton *speedButton = [self configuredButtonWithTitle:@"广告倍速加速：关闭"];
    speedButton.frame = CGRectMake(12.0, 78.0, 152.0, 32.0);
    [speedButton addTarget:self action:@selector(toggleSpeedMode) forControlEvents:UIControlEventTouchUpInside];
    speedButton.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    [panel addSubview:speedButton];

    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    [panel addGestureRecognizer:panGesture];

    [rootViewController.view addSubview:panel];

    self.overlayWindow = window;
    self.panelView = panel;
    self.skipButton = skipButton;
    self.speedButton = speedButton;
    self.titleLabel = titleLabel;
    self.overlayVisible = NO;

    [self updateOverlayHiddenState];
    [self refreshButtonTitles];
}

- (UIButton *)configuredButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.95];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 9.0;
    return button;
}

- (void)toggleOverlay {
    [self buildOverlayIfNeeded];
    self.overlayVisible = !self.overlayVisible;
    [self updateOverlayHiddenState];
}

- (void)updateOverlayHiddenState {
    if (!self.overlayWindow || !self.panelView) {
        return;
    }

    self.panelView.hidden = !self.overlayVisible;
    self.overlayWindow.userInteractionEnabled = self.overlayVisible;
}

- (void)refreshButtonTitles {
    NSString *speedTitle = @"广告倍速加速：关闭";
    if (self.targetPlaybackRate > 0.0) {
        speedTitle = [NSString stringWithFormat:@"广告倍速加速：%.1fx", self.targetPlaybackRate];
    }
    [self.speedButton setTitle:speedTitle forState:UIControlStateNormal];
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)gesture {
    UIView *panel = gesture.view;
    if (!panel || !self.overlayWindow) {
        return;
    }

    CGPoint translation = [gesture translationInView:self.overlayWindow];
    CGPoint center = CGPointMake(panel.center.x + translation.x, panel.center.y + translation.y);

    CGFloat halfWidth = CGRectGetWidth(panel.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(panel.bounds) * 0.5;
    CGFloat maxX = CGRectGetWidth(self.overlayWindow.bounds) - halfWidth - 8.0;
    CGFloat maxY = CGRectGetHeight(self.overlayWindow.bounds) - halfHeight - 8.0;

    center.x = MAX(halfWidth + 8.0, MIN(maxX, center.x));
    center.y = MAX(halfHeight + 8.0, MIN(maxY, center.y));

    panel.center = center;
    [gesture setTranslation:CGPointZero inView:self.overlayWindow];
}

- (void)skipCurrentRewardedAd {
    [self simulateRewardCallbacks];
    [self dismissKnownAdController];
}

- (void)toggleSpeedMode {
    if (self.targetPlaybackRate <= 0.0) {
        self.targetPlaybackRate = 2.0;
    } else if (self.targetPlaybackRate < 2.5) {
        self.targetPlaybackRate = 3.0;
    } else if (self.targetPlaybackRate < 3.5) {
        self.targetPlaybackRate = 4.0;
    } else {
        self.targetPlaybackRate = 0.0;
    }

    for (AVPlayer *player in self.trackedPlayers) {
        [self applyConfiguredRateToPlayer:player];
    }

    [self refreshButtonTitles];
}

- (void)registerPlayer:(AVPlayer *)player {
    if (!player) {
        return;
    }

    [self.trackedPlayers addObject:player];
}

- (float)patchedRateForRate:(float)rate {
    if (self.targetPlaybackRate <= 0.0 || rate <= 0.0f) {
        return rate;
    }

    return MAX(rate, (float)self.targetPlaybackRate);
}

- (void)applyConfiguredRateToPlayer:(AVPlayer *)player {
    if (!player) {
        return;
    }

    if (self.targetPlaybackRate <= 0.0) {
        if (player.rate > 1.0f) {
            [player setRate:1.0f];
        }
        return;
    }

    if (player.currentItem.status == AVPlayerItemStatusReadyToPlay || player.currentItem == nil) {
        [player setRate:(float)self.targetPlaybackRate];
    }
}

- (NSArray<id> *)candidateCallbackTargets {
    NSMutableArray<id> *targets = [NSMutableArray array];
    if (self.activeRewardDelegate) {
        [targets addObject:self.activeRewardDelegate];
    }
    if (self.activeRewardObject && self.activeRewardObject != self.activeRewardDelegate) {
        [targets addObject:self.activeRewardObject];
    }
    if (self.activeAdController && self.activeAdController != self.activeRewardObject) {
        [targets addObject:self.activeAdController];
    }

    UIViewController *topController = [self topViewController];
    if (topController && ![targets containsObject:topController] && FSClassNameLooksLikeRewardedAd(NSStringFromClass(topController.class))) {
        [targets addObject:topController];
    }

    return targets;
}

- (void)simulateRewardCallbacks {
    id rewardObject = self.activeRewardObject;
    id placeholderReward = [NSObject new];

    NSArray<NSString *> *zeroArgumentSelectors = @[
        @"rewardedVideoAdDidPlayFinish",
        @"rewardedVideoDidComplete",
        @"rewardedAdDidRewardEffective",
        @"rewardedAdDidDismiss",
        @"rewardVideoAdDidClose",
        @"rewardedVideoAdDidClose",
        @"rewardedAdDidClose",
        @"rewardVideoDidComplete"
    ];

    NSArray<NSString *> *singleArgumentSelectors = @[
        @"rewardedAdDidDismiss:",
        @"rewardedVideoAdDidClose:",
        @"rewardVideoAdDidClose:",
        @"rewardedAdDidRewardEffective:",
        @"rewardVideoAdDidRewardEffective:"
    ];

    NSArray<NSString *> *doubleArgumentSelectors = @[
        @"rewardedAd:didRewardUserWithReward:",
        @"rewardedAd:userDidEarnReward:",
        @"rewardVideoAd:didRewardEffective:",
        @"rewardedVideoAd:didRewardEffective:"
    ];

    for (id target in [self candidateCallbackTargets]) {
        for (NSString *selectorName in zeroArgumentSelectors) {
            FSInvokeCallback(target, selectorName, nil, nil);
        }
        for (NSString *selectorName in singleArgumentSelectors) {
            FSInvokeCallback(target, selectorName, rewardObject, nil);
        }
        for (NSString *selectorName in doubleArgumentSelectors) {
            FSInvokeCallback(target, selectorName, rewardObject, placeholderReward);
        }
    }
}

- (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) {
                break;
            }
        }
    }

    if (!keyWindow) {
        keyWindow = UIApplication.sharedApplication.keyWindow;
    }

    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)dismissKnownAdController {
    UIViewController *controller = self.activeAdController;
    if (!controller) {
        UIViewController *topController = [self topViewController];
        if (FSClassNameLooksLikeRewardedAd(NSStringFromClass(topController.class))) {
            controller = topController;
        }
    }

    if (controller.presentingViewController || controller.isBeingPresented) {
        [controller dismissViewControllerAnimated:NO completion:nil];
    }
}

@end

%group CoreHooks

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    [[FSAdAccelManager sharedInstance] handleApplicationEvent:event];
    %orig;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    if (FSClassNameLooksLikeRewardedAd(className)) {
        [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:self];
    }
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (viewControllerToPresent && FSClassNameLooksLikeRewardedAd(NSStringFromClass([viewControllerToPresent class]))) {
        [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:viewControllerToPresent];
    }
    %orig(viewControllerToPresent, flag, completion);
}

%end

%hook AVPlayer

- (void)play {
    [[FSAdAccelManager sharedInstance] registerPlayer:self];
    %orig;
    [[FSAdAccelManager sharedInstance] applyConfiguredRateToPlayer:self];
}

- (void)setRate:(float)rate {
    [[FSAdAccelManager sharedInstance] registerPlayer:self];
    float patchedRate = [[FSAdAccelManager sharedInstance] patchedRateForRate:rate];
    %orig(patchedRate);
}

%end

%end

%group GMAHooks

%hook GADRewardedAd

- (void)setFullScreenContentDelegate:(id)delegate {
    [[FSAdAccelManager sharedInstance] captureDelegate:delegate forRewardObject:self];
    %orig(delegate);
}

- (void)presentFromRootViewController:(id)rootViewController userDidEarnRewardHandler:(id)handler {
    [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:self];
    %orig(rootViewController, handler);
}

%end

%end

%group PangleHooks

%hook BURewardedVideoAd

- (void)setDelegate:(id)delegate {
    [[FSAdAccelManager sharedInstance] captureDelegate:delegate forRewardObject:self];
    %orig(delegate);
}

- (void)showAdFromRootViewController:(id)rootViewController {
    [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:self];
    %orig(rootViewController);
}

%end

%end

%group GDTHooks

%hook GDTRewardVideoAd

- (void)setDelegate:(id)delegate {
    [[FSAdAccelManager sharedInstance] captureDelegate:delegate forRewardObject:self];
    %orig(delegate);
}

- (void)showAdFromRootViewController:(id)rootViewController {
    [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:self];
    %orig(rootViewController);
}

%end

%end

%group KSHooks

%hook KSRewardedVideoAd

- (void)setDelegate:(id)delegate {
    [[FSAdAccelManager sharedInstance] captureDelegate:delegate forRewardObject:self];
    %orig(delegate);
}

- (void)showRewardedVideoAd {
    [[FSAdAccelManager sharedInstance] capturePotentialRewardContextFromObject:self];
    %orig;
}

%end

%end

%ctor {
    @autoreleasepool {
        %init(CoreHooks);

        Class gadRewardedAdClass = objc_getClass("GADRewardedAd");
        if (gadRewardedAdClass) {
            %init(GMAHooks, GADRewardedAd = gadRewardedAdClass);
        }

        Class buRewardedVideoAdClass = objc_getClass("BURewardedVideoAd");
        if (buRewardedVideoAdClass) {
            %init(PangleHooks, BURewardedVideoAd = buRewardedVideoAdClass);
        }

        Class gdtRewardVideoAdClass = objc_getClass("GDTRewardVideoAd");
        if (gdtRewardVideoAdClass) {
            %init(GDTHooks, GDTRewardVideoAd = gdtRewardVideoAdClass);
        }

        Class ksRewardedVideoAdClass = objc_getClass("KSRewardedVideoAd");
        if (ksRewardedVideoAdClass) {
            %init(KSHooks, KSRewardedVideoAd = ksRewardedVideoAdClass);
        }
    }
}
