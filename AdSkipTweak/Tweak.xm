#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 全局开关（开启后持续生效）

static BOOL gSkipAdEnabled      = NO;
static BOOL gCustomSpeedEnabled = NO;
static BOOL gAdBlockEnabled     = NO;
static BOOL gBlockShakeEnabled  = NO;
static BOOL gTouchTrailEnabled  = NO;
static BOOL gForce120FPSEnabled = NO;

#define kEOEOBlue      [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0]
#define kCustomSpeed   8.0f

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

#pragma mark - eoeo 悬浮窗（可拖动的药丸）

@interface EOEOFloatingView : UIView
@property (nonatomic, copy) void(^onTap)(void);
@end

@implementation EOEOFloatingView {
    CGPoint _startOrigin;
    CGPoint _startTouch;
    BOOL _didDrag;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];
        self.layer.cornerRadius = 7;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 6;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"eoeo";
        label.textColor = kEOEOBlue;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        [self addSubview:label];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    _startTouch = [t locationInView:self.superview];
    _startOrigin = self.frame.origin;
    _didDrag = NO;
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self.superview];
    CGFloat dx = p.x - _startTouch.x;
    CGFloat dy = p.y - _startTouch.y;
    if (fabs(dx) > 4 || fabs(dy) > 4) _didDrag = YES;
    if (_didDrag) {
        CGRect f = self.frame;
        f.origin.x = _startOrigin.x + dx;
        f.origin.y = _startOrigin.y + dy;
        CGSize s = self.superview.bounds.size;
        f.origin.x = MAX(0, MIN(f.origin.x, s.width - f.size.width));
        f.origin.y = MAX(0, MIN(f.origin.y, s.height - f.size.height));
        self.frame = f;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_didDrag && self.onTap) self.onTap();
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
}

@end

#pragma mark - AdSkipManager

@interface AdSkipManager : NSObject
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) EOEOFloatingView *floatView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *dimmerView;
@property (nonatomic, assign) BOOL panelExpanded;
+ (instancetype)sharedManager;
- (void)install;
- (void)togglePanel;
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

    self.floatWindow = [[UIWindow alloc] initWithFrame:bounds];
    self.floatWindow.windowLevel = UIWindowLevelAlert + 2000;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.rootViewController = [[UIViewController alloc] init];
    self.floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

    CGFloat fw = 68, fh = 28;
    self.floatView = [[EOEOFloatingView alloc] initWithFrame:CGRectMake(bounds.size.width - fw - 14,
                                                                        bounds.size.height/2 - fh/2,
                                                                        fw, fh)];
    __weak typeof(self) weakSelf = self;
    self.floatView.onTap = ^{ [weakSelf togglePanel]; };
    [self.floatWindow.rootViewController.view addSubview:self.floatView];

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

- (void)togglePanel {
    if (self.panelExpanded) {
        [self dismissPanel];
        return;
    }
    self.panelExpanded = YES;

    UIWindow *keyWin = AS_KeyWindow();
    CGRect bounds = keyWin.bounds;

    self.dimmerView = [[UIView alloc] initWithFrame:bounds];
    self.dimmerView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPanel)];
    [self.dimmerView addGestureRecognizer:tap];
    [self.floatWindow.rootViewController.view addSubview:self.dimmerView];

    CGFloat cardW = MIN(bounds.size.width - 40, 340);
    CGFloat cardH = 200;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width-cardW)/2,
                                                              (bounds.size.height-cardH)/2,
                                                              cardW, cardH)];
    self.panelView.backgroundColor = [UIColor whiteColor];
    self.panelView.layer.cornerRadius = 18;
    self.panelView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panelView.layer.shadowOpacity = 0.22;
    self.panelView.layer.shadowOffset = CGSizeMake(0, 8);
    self.panelView.layer.shadowRadius = 24;
    [self.floatWindow.rootViewController.view addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, cardW-40, 24)];
    title.text = @"eoeo";
    title.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [self.panelView addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, cardW-40, 18)];
    subtitle.text = @"广告控制";
    subtitle.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [self.panelView addSubview:subtitle];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.frame = CGRectMake(cardW - 60, 18, 50, 28);
    [doneBtn setTitle:@"缩小" forState:UIControlStateNormal];
    doneBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [doneBtn setTitleColor:kEOEOBlue forState:UIControlStateNormal];
    [doneBtn addTarget:self action:@selector(dismissPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:doneBtn];

    NSArray *rows = @[
        @{@"title": @"跳过激励广告", @"desc": @"自动关闭并发放奖励"},
        @{@"title": @"广告加速", @"desc": @"所有播放器 x8 倍速"},
    ];
    CGFloat rowY = 84;
    for (NSInteger i = 0; i < rows.count; i++) {
        NSDictionary *r = rows[i];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(16, rowY, cardW-32, 56)];
        row.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        row.layer.cornerRadius = 12;

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cardW-120, 20)];
        t.text = r[@"title"];
        t.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [row addSubview:t];

        UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(14, 32, cardW-120, 16)];
        d.text = r[@"desc"];
        d.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
        d.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        [row addSubview:d];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW-32-16-51, 12, 51, 31)];
        sw.onTintColor = kEOEOBlue;
        sw.tag = 2000 + i;
        sw.on = (i == 0) ? gSkipAdEnabled : gSpeedAdEnabled;
        [sw addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        [self.panelView addSubview:row];
        rowY += 64;
    }
}

- (void)onSwitchChanged:(UISwitch *)sw {
    NSInteger i = sw.tag - 2000;
    if (i == 0) {
        gSkipAdEnabled = sw.isOn;
        [self toast:gSkipAdEnabled ? @"已开启：自动跳过激励广告" : @"已关闭：跳过激励广告"];
        if (gSkipAdEnabled) [self dismissAllAdsNow];
    } else {
        gSpeedAdEnabled = sw.isOn;
        [self toast:gSpeedAdEnabled ? @"已开启：广告加速 x8" : @"已关闭：广告加速"];
        if (gSpeedAdEnabled) [self speedUpAllPlayersNow];
    }
}

- (void)dismissPanel {
    [UIView animateWithDuration:0.2 animations:^{
        self.dimmerView.alpha = 0;
        self.panelView.alpha = 0;
    } completion:^(BOOL f){
        [self.panelView removeFromSuperview];
        [self.dimmerView removeFromSuperview];
        self.panelView = nil;
        self.dimmerView = nil;
        self.panelExpanded = NO;
    }];
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
