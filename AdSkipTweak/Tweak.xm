#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 全局开关（开启后持续生效）

static BOOL   gSkipAdEnabled      = NO;
static BOOL   gCustomSpeedEnabled = NO;
static float  gCustomSpeedValue   = 1.0f;
static BOOL   gAdBlockEnabled     = NO;
static BOOL   gBlockShakeEnabled  = NO;
static BOOL   gTouchTrailEnabled  = NO;
static BOOL   gForce120FPSEnabled = NO;
static BOOL   gShowFPSEnabled     = NO;

#define kEOEOBlue [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0]

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

static void AS_ClearAdCache(void) {
    @try {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        NSHTTPCookieStorage *cs = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSHTTPCookie *c in [cs cookies]) {
            NSString *d = c.domain.lowercaseString;
            if ([d containsString:@"ad"] || [d containsString:@"doubleclick"] ||
                [d containsString:@"admob"] || [d containsString:@"googleadservices"] ||
                [d containsString:@"unityads"] || [d containsString:@"applovin"] ||
                [d containsString:@"ironsrc"] || [d containsString:@"vungle"]) {
                [cs deleteCookie:c];
            }
        }
    } @catch(NSException *e) {}
}

#pragma mark - 触摸轨迹视图

@interface AOTouchTrailView : UIView
@property (nonatomic, strong) NSMutableArray<NSValue *> *points;
- (void)addPoint:(CGPoint)p;
@end

@implementation AOTouchTrailView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.points = [NSMutableArray array];
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)addPoint:(CGPoint)p {
    [self.points addObject:[NSValue valueWithCGPoint:p]];
    if (self.points.count > 40) [self.points removeObjectAtIndex:0];
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    if (self.points.count < 2) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, kEOEOBlue.CGColor);
    CGContextSetLineWidth(ctx, 3);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    for (NSInteger i = 1; i < self.points.count; i++) {
        CGPoint a = [self.points[i-1] CGPointValue];
        CGPoint b = [self.points[i] CGPointValue];
        CGFloat alpha = (CGFloat)i / (CGFloat)self.points.count;
        CGContextSetAlpha(ctx, alpha);
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
    }
}
@end

static AOTouchTrailView *gTrailView = nil;

static void AS_UpdateTrailView(void) {
    UIWindow *keyWin = AS_KeyWindow();
    if (!keyWin) return;
    if (gTouchTrailEnabled) {
        if (!gTrailView) {
            gTrailView = [[AOTouchTrailView alloc] initWithFrame:keyWin.bounds];
            gTrailView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        [keyWin addSubview:gTrailView];
    } else {
        [gTrailView removeFromSuperview];
        gTrailView = nil;
    }
}

#pragma mark - 穿透触摸视图

@interface EOEPassthroughView : UIView
@property (nonatomic, weak) UIView *floatView;
@property (nonatomic, weak) UIView *panelView;
@property (nonatomic, assign) BOOL panelExpanded;
@end

@implementation EOEPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.panelExpanded) {
        UIView *hit = [super hitTest:point withEvent:event];
        return hit;
    }
    if (self.floatView && CGRectContainsPoint(self.floatView.frame, point)) {
        return [super hitTest:point withEvent:event];
    }
    return nil;
}
@end

#pragma mark - eoeo 悬浮窗

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
        self.layer.cornerRadius = 4;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 6;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"eoeo";
        label.textColor = kEOEOBlue;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
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
@property (nonatomic, strong) EOEPassthroughView *rootView;
@property (nonatomic, strong) EOEOFloatingView *floatView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *dimmerView;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) CADisplayLink *fpsLink;
@property (nonatomic, assign) NSInteger fpsCount;
@property (nonatomic, assign) CFTimeInterval fpsLastTime;
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

    UIViewController *vc = [[UIViewController alloc] init];
    self.rootView = [[EOEPassthroughView alloc] initWithFrame:bounds];
    self.rootView.backgroundColor = [UIColor clearColor];
    vc.view = self.rootView;
    self.floatWindow.rootViewController = vc;

    CGFloat fw = 56, fh = 22;
    self.floatView = [[EOEOFloatingView alloc] initWithFrame:CGRectMake(bounds.size.width - fw - 14,
                                                                        bounds.size.height/2 - fh/2,
                                                                        fw, fh)];
    __weak typeof(self) weakSelf = self;
    self.floatView.onTap = ^{ [weakSelf togglePanel]; };
    [self.rootView addSubview:self.floatView];
    self.rootView.floatView = self.floatView;

    self.floatWindow.hidden = NO;
    // 延迟一个 runloop 后再 resign，避免 install 时机太早
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([self.floatWindow respondsToSelector:@selector(resignKeyWindow)]) {
                [self.floatWindow resignKeyWindow];
            }
        } @catch(NSException *e) {}
    });

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
    self.rootView.panelExpanded = YES;

    CGRect bounds = self.floatWindow.bounds;

    self.dimmerView = [[UIView alloc] initWithFrame:bounds];
    self.dimmerView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPanel)];
    [self.dimmerView addGestureRecognizer:tap];
    [self.rootView addSubview:self.dimmerView];

    CGFloat cardW = MIN(bounds.size.width - 40, 340);
    CGFloat cardH = 560;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width-cardW)/2,
                                                              (bounds.size.height-cardH)/2,
                                                              cardW, cardH)];
    self.panelView.backgroundColor = [UIColor whiteColor];
    self.panelView.layer.cornerRadius = 18;
    self.panelView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panelView.layer.shadowOpacity = 0.22;
    self.panelView.layer.shadowOffset = CGSizeMake(0, 8);
    self.panelView.layer.shadowRadius = 24;
    [self.rootView addSubview:self.panelView];
    self.rootView.panelView = self.panelView;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, cardW-40, 24)];
    title.text = @"eoeo";
    title.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [self.panelView addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, cardW-40, 18)];
    subtitle.text = @"通用工具箱";
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

    NSArray *switchRows = @[
        @{@"title": @"跳过激励广告", @"desc": @"自动关闭并发放奖励"},
        @{@"title": @"更新广告屏蔽", @"desc": @"清除广告缓存并拦截"},
        @{@"title": @"禁用摇广", @"desc": @"屏蔽摇一摇触发广告"},
        @{@"title": @"触摸轨迹", @"desc": @"显示手指滑动轨迹"},
        @{@"title": @"强制120帧率", @"desc": @"强制 120Hz 刷新率"},
        @{@"title": @"显示帧数", @"desc": @"屏幕显示实时 FPS"},
    ];
    CGFloat rowY = 84;

    UIView *speedRow = [[UIView alloc] initWithFrame:CGRectMake(16, rowY, cardW-32, 72)];
    speedRow.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    speedRow.layer.cornerRadius = 12;

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 120, 20)];
    st.text = @"广告速度";
    st.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    st.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [speedRow addSubview:st];

    UILabel *sVal = [[UILabel alloc] initWithFrame:CGRectMake(cardW-32-80, 10, 66, 20)];
    sVal.text = [NSString stringWithFormat:@"x%.1f", gCustomSpeedValue];
    sVal.textColor = kEOEOBlue;
    sVal.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sVal.textAlignment = NSTextAlignmentRight;
    sVal.tag = 3001;
    [speedRow addSubview:sVal];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(14, 40, cardW-32-28, 20)];
    slider.minimumValue = 1.0;
    slider.maximumValue = 50.0;
    slider.value = gCustomSpeedValue;
    slider.minimumTrackTintColor = kEOEOBlue;
    slider.tag = 3000;
    [slider addTarget:self action:@selector(onSpeedChanged:) forControlEvents:UIControlEventValueChanged];
    [speedRow addSubview:slider];

    [self.panelView addSubview:speedRow];
    rowY += 80;

    for (NSInteger i = 0; i < switchRows.count; i++) {
        NSDictionary *r = switchRows[i];
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
        BOOL on = NO;
        if (i == 0) on = gSkipAdEnabled;
        else if (i == 1) on = gAdBlockEnabled;
        else if (i == 2) on = gBlockShakeEnabled;
        else if (i == 3) on = gTouchTrailEnabled;
        else if (i == 4) on = gForce120FPSEnabled;
        else if (i == 5) on = gShowFPSEnabled;
        sw.on = on;
        [sw addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];

        [self.panelView addSubview:row];
        rowY += 64;
    }
}

- (void)onSpeedChanged:(UISlider *)slider {
    gCustomSpeedValue = roundf(slider.value);
    slider.value = gCustomSpeedValue;
    gCustomSpeedEnabled = (gCustomSpeedValue > 1.0f);
    UILabel *val = (UILabel *)[self.panelView viewWithTag:3001];
    val.text = [NSString stringWithFormat:@"x%.1f", gCustomSpeedValue];
    if (gCustomSpeedEnabled) [self speedUpAllPlayersNow];
}

- (void)onSwitchChanged:(UISwitch *)sw {
    NSInteger i = sw.tag - 2000;
    if (i == 0) {
        gSkipAdEnabled = sw.isOn;
        [self toast:gSkipAdEnabled ? @"已开启：自动跳过激励广告" : @"已关闭：跳过激励广告"];
        if (gSkipAdEnabled) [self dismissAllAdsNow];
    } else if (i == 1) {
        gAdBlockEnabled = sw.isOn;
        [self toast:gAdBlockEnabled ? @"已开启：更新广告屏蔽" : @"已关闭：更新广告屏蔽"];
        if (gAdBlockEnabled) { AS_ClearAdCache(); [self dismissAllAdsNow]; }
    } else if (i == 2) {
        gBlockShakeEnabled = sw.isOn;
        [self toast:gBlockShakeEnabled ? @"已开启：禁用摇广" : @"已关闭：禁用摇广"];
    } else if (i == 3) {
        gTouchTrailEnabled = sw.isOn;
        [self toast:gTouchTrailEnabled ? @"已开启：触摸轨迹" : @"已关闭：触摸轨迹"];
        AS_UpdateTrailView();
    } else if (i == 4) {
        gForce120FPSEnabled = sw.isOn;
        [self toast:gForce120FPSEnabled ? @"已开启：强制120帧率" : @"已关闭：强制120帧率"];
        if (gForce120FPSEnabled) [self apply120FPS];
    } else if (i == 5) {
        gShowFPSEnabled = sw.isOn;
        [self toast:gShowFPSEnabled ? @"已开启：显示帧数" : @"已关闭：显示帧数"];
        if (gShowFPSEnabled) [self startFPSCounter]; else [self stopFPSCounter];
    }
}

- (void)startFPSCounter {
    if (self.fpsLink) return;
    UIWindow *keyWin = AS_KeyWindow();
    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 40, 90, 24)];
    self.fpsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.fpsLabel.textColor = [UIColor whiteColor];
    self.fpsLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.fpsLabel.textAlignment = NSTextAlignmentCenter;
    self.fpsLabel.layer.cornerRadius = 6;
    self.fpsLabel.layer.masksToBounds = YES;
    self.fpsLabel.text = @"FPS: --";
    [keyWin addSubview:self.fpsLabel];

    self.fpsCount = 0;
    self.fpsLastTime = 0;
    self.fpsLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(fpsTick:)];
    [self.fpsLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopFPSCounter {
    [self.fpsLink invalidate];
    self.fpsLink = nil;
    [self.fpsLabel removeFromSuperview];
    self.fpsLabel = nil;
}

- (void)fpsTick:(CADisplayLink *)link {
    if (self.fpsLastTime == 0) {
        self.fpsLastTime = link.timestamp;
        return;
    }
    self.fpsCount++;
    CFTimeInterval dt = link.timestamp - self.fpsLastTime;
    if (dt >= 1.0) {
        NSInteger fps = (NSInteger)round((double)self.fpsCount / dt);
        self.fpsLabel.text = [NSString stringWithFormat:@"FPS: %ld", (long)fps];
        self.fpsCount = 0;
        self.fpsLastTime = link.timestamp;
    }
}

- (void)apply120FPS {
    for (UIWindow *w in AS_AllWindows()) {
        @try { [w setValue:@(120) forKey:@"maximumFramesPerSecond"]; } @catch(NSException *e) {}
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
        self.rootView.panelExpanded = NO;
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
        if (layer.player) layer.player.rate = gCustomSpeedValue;
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
    if (gCustomSpeedEnabled) {
        %orig(gCustomSpeedValue);
    } else {
        %orig;
    }
}

- (void)play {
    %orig;
    if (gCustomSpeedEnabled) {
        self.rate = gCustomSpeedValue;
    }
}

%end

#pragma mark - 全局 Hook：禁用摇广 + 触摸轨迹 + 广告屏蔽拦截

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeMotion && gBlockShakeEnabled) {
        return;
    }
    if (gTouchTrailEnabled && event.type == UIEventTypeTouches) {
        UITouch *t = [[event allTouches] anyObject];
        if (t && gTrailView) {
            CGPoint p = [t locationInView:gTrailView];
            if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
                [gTrailView.points removeAllObjects];
                [gTrailView setNeedsDisplay];
            } else {
                [gTrailView addPoint:p];
            }
        }
    }
    %orig;
}

%end

%hook UIResponder

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (gBlockShakeEnabled) return;
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (gBlockShakeEnabled) return;
    %orig;
}

- (void)motionCancelled:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (gBlockShakeEnabled) return;
    %orig;
}

%end

#pragma mark - 全局 Hook：120 帧率

%hook UIWindow

- (NSInteger)maximumFramesPerSecond {
    if (gForce120FPSEnabled) return 120;
    return %orig;
}

%end

%hook CADisplayLink

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    if (gForce120FPSEnabled) {
        %orig(120);
    } else {
        %orig;
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
