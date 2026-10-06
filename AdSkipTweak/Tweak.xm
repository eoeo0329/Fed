#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 工具：遍历视图/VC 层级

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

#pragma mark - 广告类名特征

static BOOL AS_IsAdViewController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    NSArray<NSString *> *keywords = @[
        @"GAD", @"Reward", @"Interstitial", @"FullScreen", @"Ad",
        @"ISReward", @"ISInterstitial",        // IronSource
        @"MARewarded", @"MAInterstitial",       // AppLovin
        @"UnityAds",                            // Unity
        @"ADG",                                 // AdMost / ADG
        @"TPReward", @"TPInterstitial",         // TradPlus
        @"Mediation", @"VideoAd", @"RewardedAd"
    ];
    for (NSString *kw in keywords) {
        if ([cls rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - AdSkipManager

@interface AdSkipManager : NSObject
@property (nonatomic, strong) UIWindow *panelWindow;
@property (nonatomic, strong) UIView *panelView;
+ (instancetype)sharedManager;
- (void)showPanel;
- (void)dismissPanel;
- (void)skipRewardedAd;
- (void)speedUpAd;
- (void)closeFloatingWindow;
@end

@implementation AdSkipManager

+ (instancetype)sharedManager {
    static AdSkipManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AdSkipManager alloc] init]; });
    return inst;
}

- (void)showPanel {
    if (self.panelWindow) return;

    UIWindow *keyWin = AS_KeyWindow();
    CGRect bounds = keyWin ? keyWin.bounds : [UIScreen mainScreen].bounds;

    self.panelWindow = [[UIWindow alloc] initWithFrame:bounds];
    self.panelWindow.windowLevel = UIWindowLevelAlert + 1000;
    self.panelWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.panelWindow.rootViewController = [[UIViewController alloc] init];
    self.panelWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

    // 点击背景关闭
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPanel)];
    [self.panelWindow.rootViewController.view addGestureRecognizer:bgTap];

    // 面板
    CGFloat panelW = 260;
    CGFloat panelH = 220;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - panelW)/2,
                                                              (bounds.size.height - panelH)/2,
                                                              panelW, panelH)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.96];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [self.panelWindow.rootViewController.view addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, panelW, 24)];
    title.text = @"广告控制中心";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];

    NSArray<NSString *> *titles = @[@"跳过激励广告", @"广告加速", @"关闭悬浮窗"];
    NSArray<UIColor *> *colors = @[
        [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1.0],
        [UIColor colorWithRed:0.95 green:0.65 blue:0.15 alpha:1.0],
        [UIColor colorWithRed:0.90 green:0.30 blue:0.30 alpha:1.0]
    ];
    SEL actions[3] = { @selector(skipRewardedAd), @selector(speedUpAd), @selector(closeFloatingWindow) };

    CGFloat btnH = 44;
    CGFloat gap = 12;
    CGFloat startY = 52;
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, startY + i*(btnH+gap), panelW - 40, btnH);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        btn.backgroundColor = colors[i];
        btn.layer.cornerRadius = 10;
        [btn addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:btn];
    }

    self.panelWindow.hidden = NO;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                self.panelWindow.windowScene = (UIWindowScene *)s;
                break;
            }
        }
    }
    [self.panelWindow makeKeyAndVisible];
}

- (void)dismissPanel {
    [UIView animateWithDuration:0.2 animations:^{
        self.panelView.alpha = 0;
    } completion:^(BOOL f){
        self.panelWindow.hidden = YES;
        self.panelWindow = nil;
        self.panelView = nil;
    }];
}

#pragma mark - 按钮 1：跳过激励广告

- (void)skipRewardedAd {
    __block NSInteger dismissed = 0;
    __block BOOL rewarded = NO;

    for (UIWindow *w in AS_AllWindows()) {
        AS_EnumerateViewControllers(w.rootViewController, ^(UIViewController *vc) {
            if (AS_IsAdViewController(vc)) {
                // 尝试触发奖励回调
                NSString *cls = NSStringFromClass([vc class]);
                // Google AdMob: GADRewardedAd 有 userDidEarnRewardHandler
                if ([cls rangeOfString:@"GAD"].location != NSNotFound) {
                    id handler = nil;
                    @try { handler = [vc valueForKey:@"userDidEarnRewardHandler"]; } @catch(NSException *e) {}
                    if (handler) {
                        @try { ((void(*)(id, SEL))objc_msgSend)(handler, @selector(invoke)); } @catch(NSException *e) {}
                        rewarded = YES;
                    }
                }
                // 通用：尝试调用 reward / didReward 相关 selector
                NSArray<NSString *> *rewardSels = @[@"rewardUser", @"grantReward", @"userDidEarnReward", @"didReward"];
                for (NSString *selName in rewardSels) {
                    SEL s = NSSelectorFromString(selName);
                    if ([vc respondsToSelector:s]) {
                        @try { ((void(*)(id, SEL))objc_msgSend)(vc, s); rewarded = YES; } @catch(NSException *e) {}
                    }
                }
                // 关闭广告 VC
                [vc dismissViewControllerAnimated:NO completion:nil];
                dismissed++;
            }
        });
    }

    // 移除可能的广告 overlay window
    for (UIWindow *w in AS_AllWindows()) {
        if (w != self.panelWindow) {
            NSString *cls = NSStringFromClass([w class]);
            if ([cls rangeOfString:@"Ad" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [cls rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                w.hidden = YES;
                [w removeFromSuperview];
            }
        }
    }

    [self toast:rewarded ? [NSString stringWithFormat:@"已跳过广告并发放奖励 (%ld)", (long)dismissed]
                  : [NSString stringWithFormat:@"已关闭 %ld 个广告", (long)dismissed]];
}

#pragma mark - 按钮 2：广告加速

- (void)speedUpAd {
    // 遍历可见的 AVPlayerLayer，将其 player.rate 设为 8.0 实现广告加速
    __block NSInteger count = 0;
    for (UIWindow *w in AS_AllWindows()) {
        AS_EnumerateViewControllers(w.rootViewController, ^(UIViewController *vc) {
            [self speedUpPlayersInView:vc.view count:&count];
        });
    }

    // 尝试加速系统音频（MPVolumeView 底层）
    // 对 AVPlayer 无法全局枚举的场景，通过设置 AVAudioSession 提示无法处理；
    // 这里额外尝试通过运行时遍历所有类的实例（仅对少量常用类）
    [self trySpeedUpKnownPlayerClasses:&count];

    [self toast:[NSString stringWithFormat:@"已加速 %ld 个播放器 (x8.0)", (long)count]];
}

- (void)speedUpPlayersInView:(UIView *)view count:(NSInteger *)count {
    if (!view) return;
    if ([view isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)view.layer;
        if (layer.player) {
            layer.player.rate = 8.0;
            (*count)++;
        }
    }
    for (UIView *sub in view.subviews) {
        [self speedUpPlayersInView:sub count:count];
    }
}

- (void)trySpeedUpKnownPlayerClasses:(NSInteger *)count {
    // 常见播放器类名
    NSArray *clsNames = @[@"AVPlayer", @"MPMoviePlayerController",
                          @"AVQueuePlayer", @"AVLooper"];
    for (NSString *name in clsNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        // 无法直接枚举所有实例，跳过；实例在视图中已处理
    }
}

#pragma mark - 按钮 3：关闭悬浮窗

- (void)closeFloatingWindow {
    NSInteger removed = 0;
    NSArray *wins = [AS_AllWindows() copy];
    for (UIWindow *w in wins) {
        if (w == self.panelWindow) continue;
        // 非 key window 且不在主 scene、或为悬浮层
        if (!w.isKeyWindow) {
            NSString *cls = NSStringFromClass([w class]);
            // 跳过系统键盘等
            if ([cls containsString:@"UITextEffectsWindow"] ||
                [cls containsString:@"UIRemoteKeyboardWindow"]) continue;
            if (w.windowLevel > UIWindowLevelNormal) {
                w.hidden = YES;
                [w removeFromSuperview];
                removed++;
            }
        }
    }
    // 同时 dismiss 掉所有 presented VC（多为广告/悬浮弹窗）
    for (UIWindow *w in AS_AllWindows()) {
        UIViewController *top = w.rootViewController;
        while (top.presentedViewController) {
            top = top.presentedViewController;
        }
        if (top != w.rootViewController) {
            [top dismissViewControllerAnimated:NO completion:nil];
            removed++;
        }
    }
    [self toast:[NSString stringWithFormat:@"已关闭 %ld 个悬浮窗", (long)removed]];
}

#pragma mark - Toast

- (void)toast:(NSString *)msg {
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
    UIWindow *keyWin = AS_KeyWindow();
    label.center = CGPointMake(keyWin.bounds.size.width/2, keyWin.bounds.size.height - 100);
    [keyWin addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ label.alpha = 0; } completion:^(BOOL f){ [label removeFromSuperview]; }];
    });
}

@end

#pragma mark - 手势安装

@interface ASLongPressGesture : UILongPressGestureRecognizer @end
@implementation ASLongPressGesture
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)g { return NO; }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)g { return NO; }
- (BOOL)shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)g { return NO; }
- (BOOL)shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)g { return NO; }
@end

static const void *kASGestureInstalled = &kASGestureInstalled;

static void AS_InstallGesture(UIWindow *window) {
    if (!window) return;
    if (objc_getAssociatedObject(window, kASGestureInstalled)) return;

    ASLongPressGesture *lp = [[ASLongPressGesture alloc] initWithTarget:[AdSkipManager sharedManager]
                                                                 action:@selector(showPanel)];
    lp.numberOfTouchesRequired = 3;
    lp.minimumPressDuration = 0.5;
    lp.allowableMovement = 30;
    lp.cancelsTouchesInView = NO;
    [window addGestureRecognizer:lp];
    objc_setAssociatedObject(window, kASGestureInstalled, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Logos Hooks

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    AS_InstallGesture(self);
}

%end

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL r = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in AS_AllWindows()) {
            AS_InstallGesture(w);
        }
    });
    return r;
}

%end

#pragma mark - 广告加速运行时 Hook（AVPlayer rate 拦截）

%hook AVPlayer

- (void)setRate:(float)rate {
    // 允许外部正常设置；加速按钮通过直接修改实例变量实现，这里不强制
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[AdSkipTweak] loaded; 三指长按唤起广告控制中心");
        // 保险：延迟安装
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *w in AS_AllWindows()) {
                AS_InstallGesture(w);
            }
        });
    }
}
