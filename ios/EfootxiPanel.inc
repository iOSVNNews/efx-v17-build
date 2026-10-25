// Efootxi in-game panel (25 Oct). A small draggable "EFX" button floats over the game; tapping it opens
// PESmobile.app/efootxi/panel/index.html in a WKWebView. The page calls window.webkit.messageHandlers.efx
// .postMessage({cmd, req}) and awaits the reply (WKScriptMessageHandlerWithReply, iOS 14+). Native commands:
// close, fps_get, fps_set, hide_button. Everything else goes to efootxi_panel_ios.dispatch(cmd, req) in the
// embedded Python, under gPythonMu like the game's own requests (same SQLite connection, never concurrent).
#ifdef EFOOTXI_IOS
#import <WebKit/WebKit.h>

static NSString* efootxiPanelCall(NSString* cmd, NSString* req) {
  BackendIOScope backendIO;
  std::lock_guard<std::mutex> lock(gPythonMu);
  if (!gPythonAttempted) initializeEfootxi();
  if (!gPythonServe) return @"{\"ok\":false,\"error\":\"Máy chủ offline chưa chạy\"}";
  PyGILState_STATE gil = PyGILState_Ensure();
  NSString* out = nil;
  PyObject* module = PyImport_ImportModule("efootxi_panel_ios");
  PyObject* result = module ? PyObject_CallMethod(module, "dispatch", "ss", cmd.UTF8String, req.UTF8String ?: "{}") : nullptr;
  if (result && PyUnicode_Check(result)) {
    const char* text = PyUnicode_AsUTF8(result);
    if (text) out = [NSString stringWithUTF8String:text];
  }
  if (!out) {
    PyErr_Print();
    out = @"{\"ok\":false,\"error\":\"Lỗi Python trong bảng điều khiển, xem nhật ký\"}";
  }
  Py_XDECREF(result); Py_XDECREF(module); PyGILState_Release(gil);
  return out;
}

@interface EfootxiPassWindow : UIWindow @end
@implementation EfootxiPassWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  UIView* hit = [super hitTest:point withEvent:event];
  // Touches outside the button / open panel go to the game window below.
  return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface EfootxiPanelVC : UIViewController <WKScriptMessageHandlerWithReply, WKNavigationDelegate>
@property(nonatomic,strong) WKWebView* web;
@property(nonatomic,copy) void (^onClose)(void);
@end

@interface EfootxiRootVC : UIViewController
@property(nonatomic,strong) UIButton* button;
@end

static UIWindow* gEfootxiPanelWindow;
static EfootxiRootVC* gEfootxiRoot;

@implementation EfootxiPanelVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.09 alpha:1];
  WKWebViewConfiguration* cfg = [WKWebViewConfiguration new];
  [cfg.userContentController addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"efx"];
  self.web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
  self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.web.opaque = NO; self.web.backgroundColor = UIColor.clearColor;
  self.web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  [self.view addSubview:self.web];
  NSString* dir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"efootxi/panel"];
  NSURL* page = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"index.html"]];
  [self.web loadFileURL:page allowingReadAccessToURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  // The user content controller retains its handler; drop it so the closed panel is released.
  [self.web.configuration.userContentController removeScriptMessageHandlerForName:@"efx" contentWorld:WKContentWorld.pageWorld];
  [self.web removeFromSuperview]; self.web = nil;
}
- (void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)message
               replyHandler:(void (^)(id _Nullable, NSString* _Nullable))reply {
  NSDictionary* body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
  NSString* cmd = [body[@"cmd"] isKindOfClass:NSString.class] ? body[@"cmd"] : @"";
  NSString* req = [body[@"req"] isKindOfClass:NSString.class] ? body[@"req"] : @"{}";
  if ([cmd isEqualToString:@"close"]) { reply(@"{\"ok\":true,\"data\":{}}", nil); if (self.onClose) self.onClose(); return; }
  if ([cmd isEqualToString:@"hide_button"]) {
    reply(@"{\"ok\":true,\"data\":{}}", nil);
    if (self.onClose) self.onClose();
    gEfootxiRoot.button.hidden = YES;
    return;
  }
  if ([cmd isEqualToString:@"fps_get"]) {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"efootxi.fps"];
    reply([NSString stringWithFormat:@"{\"ok\":true,\"data\":{\"fps\":%ld,\"screen\":%ld}}", (long)(v ?: 120),
           (long)UIScreen.mainScreen.maximumFramesPerSecond], nil);
    return;
  }
  if ([cmd isEqualToString:@"fps_set"]) {
    NSDictionary* r = [NSJSONSerialization JSONObjectWithData:[req dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSInteger v = [r isKindOfClass:NSDictionary.class] ? [r[@"fps"] integerValue] : 0;
    [NSUserDefaults.standardUserDefaults setInteger:(v == 60 ? 60 : 120) forKey:@"efootxi.fps"];
    reply(@"{\"ok\":true,\"data\":{}}", nil);
    return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString* out = efootxiPanelCall(cmd, req);
    dispatch_async(dispatch_get_main_queue(), ^{ reply(out, nil); });
  });
}
@end

@implementation EfootxiRootVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:@"EFX" forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
  [b setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
  b.backgroundColor = [UIColor colorWithRed:0.71 green:0.95 blue:0.24 alpha:0.55];
  b.layer.cornerRadius = 20; b.clipsToBounds = YES;
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  CGFloat x = [d objectForKey:@"efootxi.button.x"] ? [d doubleForKey:@"efootxi.button.x"] : 44;
  CGFloat y = [d objectForKey:@"efootxi.button.y"] ? [d doubleForKey:@"efootxi.button.y"] : 70;
  b.frame = CGRectMake(x, y, 40, 40);
  [b addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
  [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
  self.button = b;
  [self.view addSubview:b];
}
- (void)drag:(UIPanGestureRecognizer*)g {
  CGPoint t = [g translationInView:self.view];
  CGRect f = self.button.frame; f.origin.x += t.x; f.origin.y += t.y;
  CGRect bounds = self.view.bounds;
  f.origin.x = fmax(0, fmin(bounds.size.width - f.size.width, f.origin.x));
  f.origin.y = fmax(0, fmin(bounds.size.height - f.size.height, f.origin.y));
  self.button.frame = f; [g setTranslation:CGPointZero inView:self.view];
  if (g.state == UIGestureRecognizerStateEnded) {
    [NSUserDefaults.standardUserDefaults setDouble:f.origin.x forKey:@"efootxi.button.x"];
    [NSUserDefaults.standardUserDefaults setDouble:f.origin.y forKey:@"efootxi.button.y"];
  }
}
- (void)open {
  if (self.presentedViewController) return;
  EfootxiPanelVC* vc = [EfootxiPanelVC new];
  vc.modalPresentationStyle = UIModalPresentationFullScreen;
  __weak EfootxiRootVC* weak = self;
  UIWindow* previous = nil;
  for (UIWindow* w in self.view.window.windowScene.windows) if (w.isKeyWindow) previous = w;
  __weak UIWindow* game = previous;
  vc.onClose = ^{
    [weak dismissViewControllerAnimated:YES completion:^{ if (game) [game makeKeyWindow]; }];
  };
  [self.view.window makeKeyWindow];   // text fields in the page need the keyboard
  diagnosticEvent(@"lifecycle.jsonl", @{@"event": @"efootxi_panel_open"});
  [self presentViewController:vc animated:YES completion:nil];
}
@end

static void efootxiInstallPanelButton() {
  if (gEfootxiPanelWindow) return;
  if (@available(iOS 14.0, *)) {} else { ZLog(@"[PANEL] needs iOS 14"); return; }
  UIWindowScene* scene = nil;
  for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene*)s; break; }
  EfootxiPassWindow* w = scene ? [[EfootxiPassWindow alloc] initWithWindowScene:scene]
                               : [[EfootxiPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  w.windowLevel = UIWindowLevelAlert + 2;
  w.backgroundColor = UIColor.clearColor;
  gEfootxiRoot = [EfootxiRootVC new];
  w.rootViewController = gEfootxiRoot;
  w.hidden = NO;   // never key: the game keeps keyboard/focus until the panel is opened
  gEfootxiPanelWindow = w;
  ZLog(@"[PANEL] EFX button installed");
}
#endif
