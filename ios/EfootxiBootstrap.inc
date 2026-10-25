#ifdef EFOOTXI_IOS
@interface EfootxiBootstrapVC : UIViewController
@property(nonatomic,strong) UILabel* detail;
@property(nonatomic,strong) UIProgressView* progress;
@property(nonatomic,strong) UIButton* retry;
@property(nonatomic,copy) void (^ready)(void);
@property(nonatomic,assign) BOOL working;
@end
static UIWindow* gEfootxiBootWindow;
@implementation EfootxiBootstrapVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor=PESNight();
  UILabel* title=[UILabel new]; title.textColor=PESLime(); title.font=[UIFont boldSystemFontOfSize:25];
  title.text=[gEfootxiDataMode isEqualToString:@"china-data"] ? @"Efootxi • Thử data China" : @"Efootxi • Offline trên iOS quốc tế";
  title.textAlignment=NSTextAlignmentCenter; title.numberOfLines=0;
  self.detail=[UILabel new]; self.detail.textColor=UIColor.whiteColor; self.detail.numberOfLines=0;
  self.detail.textAlignment=NSTextAlignmentCenter; self.detail.text=@"Đang khởi động máy chủ offline…";
  self.progress=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; self.progress.tintColor=PESLime();
  self.retry=[UIButton buttonWithType:UIButtonTypeSystem]; [self.retry setTitle:@"Thử lại" forState:UIControlStateNormal];
  [self.retry addTarget:self action:@selector(begin) forControlEvents:UIControlEventTouchUpInside]; self.retry.hidden=YES;
  UILabel* note=[UILabel new]; note.textColor=PESMuted(); note.numberOfLines=0; note.textAlignment=NSTextAlignmentCenter;
  note.font=[UIFont systemFontOfSize:12];
  note.text=[NSString stringWithFormat:@"Giữ app mở khi chuẩn bị data.\nNhật ký: Documents/%@\nEfootxi by maxlzyver • Bộ chạy iOS quốc tế",gSessionRoot.lastPathComponent];
  UIStackView* stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.detail,self.progress,self.retry,note]];
  stack.axis=UILayoutConstraintAxisVertical; stack.spacing=18; stack.translatesAutoresizingMaskIntoConstraints=NO;
  [self.view addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[[stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [stack.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8]]];
}
- (void)begin {
  if (self.working) return;
  self.working=YES; self.retry.hidden=YES;
  self.detail.text=@"Đang kiểm tra máy chủ offline và dữ liệu…";
  UIApplication.sharedApplication.idleTimerDisabled=YES;
  __weak EfootxiBootstrapVC* weak=self;
  gEfootxiProgress=^(NSString* message,double value) {
    EfootxiBootstrapVC* current=weak; if (!current) return;
    current.detail.text=message; current.progress.progress=(float)fmax(0,fmin(1,value));
  };
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
    NSString* error=efootxiPrepareResources();
    dispatch_async(dispatch_get_main_queue(), ^{
      self.working=NO; UIApplication.sharedApplication.idleTimerDisabled=NO;
      if (error) {
        self.detail.text=[@"Chưa thể chuẩn bị data:\n" stringByAppendingString:error]; self.retry.hidden=NO;
        ZLog(@"[BOOTSTRAP_FAILED] %@",error);
      } else {
        gEfootxiPrepared=true; gEfootxiProgress=nil;
        diagnosticInventory(); diagnosticSnapshot(@"resources ready before game launch");
        if (self.ready) self.ready();
        gEfootxiBootWindow.hidden=YES; gEfootxiBootWindow=nil;
      }
    });
  });
}
@end

static void startEfootxiBootstrap(void (^ready)(void)) {
  EfootxiBootstrapVC* vc=[EfootxiBootstrapVC new]; vc.ready=ready;
  gEfootxiBootWindow=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  gEfootxiBootWindow.windowLevel=UIWindowLevelAlert+1; gEfootxiBootWindow.rootViewController=vc;
  [gEfootxiBootWindow makeKeyAndVisible];
  dispatch_async(dispatch_get_main_queue(), ^{ [vc begin]; });
}
#endif
