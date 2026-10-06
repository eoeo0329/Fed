#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 全局开关（开启后持续生效）

static BOOL gSkipAdEnabled  = NO;   // 跳过激励广告
static BOOL gSpeedAdEnabled = NO;   // 广告加速

#pragma mark - 工具

static void AS_EnumerateViewControllers(UIViewController *vc, void(^block)(UIViewController *vc)) {
    if (!vc || !block) return;
    block(vc);
    for (UIViewController *child in vc.childViewControllers) {
        AS_EnumerateViewControllers(child, block);
    }
    if (vc.presentedViewController) {
        AS_EnumerateViewControllers(vc.presentedViewController, block);
    }
}

static NSArray<UIWindow *> *AS_AllWindows(void) {
    if (@available(iOS 13.0, *)) {
        NSMutableArray *wins = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [wins addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        return wins;
    }
    return [UIApplication sharedApplication].windows;
}

static UIWindow *AS_KeyWindow(void) {
    for (UIWindow *w in AS_AllWindows()) {
        if (w.isKeyWindow) return w;
    }
    return AS_AllWindows().firstObject;
}

static BOOL AS_IsAdViewController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    NSArray<NSString *> *keywords = @[
        @"GAD", @"Reward", @"Interstitial", @"FullScreen",
        @"ISReward", @"ISInterstitial",
        @"MARewarded", @"MAInterstitial",
        @"UnityAds", @"ADG",
        @"TPReward", @"TPInterstitial",
        @"Mediation", @"VideoAd", @"RewardedAd", @"OpenAd"
    ];
    for (NSString *kw in keywords) {
        if ([cls rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void AS_GrantRewardForAd(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    // Google AdMob
    if ([cls rangeOfString:@"GAD"].location != NSNotFound) {
        @try {
            id handler = [vc valueForKey:@"userDidEarnRewardHandler"];
            if (handler) ((void(*)(id, SEL))objc_msgSend)(handler, @selector(invoke));
        } @catch(NSException *e) {}
    }
    NSArray<NSString *> *sels = @[@"rewardUser", @"grantReward", @"userDidEarnReward", @"didReward", @"reward"];
    for (NSString *sn in sels) {
        SEL s = NSSelectorFromString(sn);
        if ([vc respondsToSelector:s]) {
            @try { ((void(*)(id, SEL))objc_msgSend)(vc, s); } @catch(NSException *e) {}
        }
    }
}

#pragma mark - AdSkipManager（eoeo 悬浮窗）

@interface AdSkipManager : NSObject
@property (nonatomic, strong) UIWindow *floatWindow;   // eoeo 常驻悬浮窗
@property (nonatomic, strong) UIButton *eoeoButton;    // 显示 "eoeo"
@property (nonatomic, strong) UIView *panelView;       // 展开的开关面板
@property (nonatomic, assign) BOOL panelExpanded;
+ (instancetype)sharedManager;
- (void)install;
- (void)togglePanel;
- (void)closeFloatWindow;
- (void)toast:(NSString *)msg;
@end

@implementation AdSkipManager

+ (instancetype)sharedManager {
    static AdSkipManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AdSkipManager alloc] init]; });
    return inst;
}

- (void)install {
    if (self.floatWindow) return;

    UIWindow *keyWin = AS_KeyWindow();
    CGRect bounds = keyWin ? keyWin.bounds : [UIScreen mainScreen].bounds;

    self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(bounds.size.width - 70,
                                                                  bounds.size.height/2 - 30,
                                                                  60, 60)];
    self.floatWindow.windowLevel = UIWindowLevelAlert + 2000;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.rootViewController = [[UIViewController alloc] init];
    self.floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

    self.eoeoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.eoeoButton.frame = self.floatWindow.bounds;
    [self.eoeoButton setTitle:@"eoeo" forState:UIControlStateNormal];
    [self.eoeoButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.eoeoButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.eoeoButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.55 blue:0.95 alpha:0.9];
    self.eoeoButton.layer.cornerRadius = 30;
    self.eoeoButton.layer.borderWidth = 1.5;
    self.eoeoButton.layer.borderColor = [UIColor whiteColor].CGColor;
    self.eoeoButton.showsTouchWhenHighlighted = YES;
    [self.eoeoButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.floatWindow.rootViewController.view addSubview:self.eoeoButton];

    // 拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.eoeoButton addGestureRecognizer:pan];

    self.floatWindow.hidden = NO;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                self.floatWindow.windowScene = (UIWindowScene *)s;
                break;
            }
        }
    }
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint t = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + t.x, btn.center.y + t.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

- (void)togglePanel {
    if (self.panelExpanded) {
        [self.panelView removeFromSuperview];
        self.panelView = nil;
        self.panelExpanded = NO;
        return;
    }
    self.panelExpanded = YES;

    UIWindow *keyWin = AS_KeyWindow();
    CGRect bounds = keyWin.bounds;
    CGFloat panelW = 240;
    CGFloat panelH = 200;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width-panelW)/2,
                                                              (bounds.size.height-panelH)/2,
                                                              panelW, panelH)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:0.97];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [keyWin addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, panelW, 22)];
    title.text = @"eoeo 控制中心";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];

    NSArray<NSString *> *labels = @[@"跳过激励广告", @"广告加速", @"关闭悬浮窗"];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, 46 + i*46, panelW-40, 38);
        [btn setTitle:labels[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        btn.layer.cornerRadius = 9;
        btn.tag = 1000 + i;
        [self updateButton:btn atIndex:i];
        [btn addTarget:self action:@selector(onButtonTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:btn];
    }
}

- (void)updateButton:(UIButton *)btn atIndex:(NSInteger)i {
    BOOL on = NO;
    UIColor *base = [UIColor colorWithRed:0.25 green:0.27 blue:0.30 alpha:1.0];
    if (i == 0) { on = gSkipAdEnabled;  base = on ? [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1.0] : base; }
    if (i == 1) { on = gSpeedAdEnabled; base = on ? [UIColor colorWithRed:0.95 green:0.65 blue:0.15 alpha:1.0] : base; }
    if (i == 2) { base = [UIColor colorWithRed:0.90 green:0.30 blue:0.30 alpha:1.0]; }
    btn.backgroundColor = base;
    NSString *title = (i == 2) ? @"关闭悬浮窗" : ([NSString stringWithFormat:@"%@ %@",
                      (i==0?@"跳过激励广告":@"广告加速"), on ? @"✅" : @"⚪"]);
    [btn setTitle:title forState:UIControlStateNormal];
}

- (void)onButtonTap:(UIButton *)sender {
    NSInteger i = sender.tag - 1000;
    if (i == 0) {
        gSkipAdEnabled = !gSkipAdEnabled;
        [self toast:gSkipAdEnabled ? @"已开启：自动跳过激励广告" : @"已关闭：跳过激励广告"];
        if (gSkipAdEnabled) [self dismissAllAdsNow];
    } else if (i == 1) {
        gSpeedAdEnabled = !gSpeedAdEnabled;
        [self toast:gSpeedAdEnabled ? @"已开启：广告加速 x8" : @"已关闭：广告加速"];
        if (gSpeedAdEnabled) [self speedUpAllPlayersNow];
    } else if (i == 2) {
        [self closeFloatWindow];
        return;
    }
    [self updateButton:sender atIndex:i];
}

- (void)dismissAllAdsNow {
    for (UIWindow *w in AS_AllWindows()) {
        AS_EnumerateViewControllers(w.rootViewController, ^(UIViewController *vc) {
            if (AS_IsAdViewController(vc)) {
                AS_GrantRewardForAd(vc);
                [vc dismissViewControllerAnimated:NO completion:nil];
            }
        });
    }
}

- (void)speedUpAllPlayersNow {
    for (UIWindow *w in AS_AllWindows()) {
        AS_EnumerateViewControllers(w.rootViewController, ^(UIViewController *vc) {
            [self speedUpPlayersInView:vc.view];
        });
    }
}

- (void)speedUpPlayersInView:(UIView *)view {
    if (!view) return;
    if ([view isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)view.layer;
        if (layer.player) layer.player.rate = 8.0;
    }
    for (UIView *sub in view.subviews) [self speedUpPlayersInView:sub];
}

- (void)closeFloatWindow {
    [self.panelView removeFromSuperview];
    self.panelView = nil;
    self.panelExpanded = NO;
    self.floatWindow.hidden = YES;
    self.floatWindow = nil;
    gSkipAdEnabled = NO;
    gSpeedAdEnabled = NO;
    [self toast:@"eoeo 悬浮窗已关闭"];
}

- (void)toast:(NSString *)msg {
    UIWindow *keyWin = AS_KeyWindow();
    if (!keyWin) return;
    UILabel *label = [[UILabel alloc] init];
    label.text = msg;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    label.font = [UIFont systemFontOfSize:14];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 8;
    label.layer.masksToBounds = YES;
    CGSize s = [msg sizeWithAttributes:@{NSFontAttributeName: label.font}];
    label.frame = CGRectMake(0, 0, s.width + 24, 32);
    label.center = CGPointMake(keyWin.bounds.size.width/2, keyWin.bounds.size.height - 100);
    [keyWin addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ label.alpha = 0; } completion:^(BOOL f){ [label removeFromSuperview]; }];
    });
}

@end

#pragma mark - 全局 Hook：广告自动跳过

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gSkipAdEnabled && AS_IsAdViewController(self)) {
        // 延迟一点确保 reward handler 已设置
        UIViewController *vc = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gSkipAdEnabled) {
                AS_GrantRewardForAd(vc);
                [vc dismissViewControllerAnimated:NO completion:nil];
            }
        });
    }
}

%end

#pragma mark - 全局 Hook：广告自动加速

%hook AVPlayer

- (void)setRate:(float)rate {
    if (gSpeedAdEnabled) {
        %orig(8.0);
    } else {
        %orig;
    }
}

- (void)play {
    %orig;
    if (gSpeedAdEnabled) {
        self.rate = 8.0;
    }
}

%end

#pragma mark - 入口

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL r = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AdSkipManager sharedManager] install];
    });
    return r;
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[eoeo] tweak loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AdSkipManager sharedManager] install];
        });
    }
}
