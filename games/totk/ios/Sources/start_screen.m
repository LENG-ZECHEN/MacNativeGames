#import "start_screen.h"
#import <GameController/GameController.h>
#include "totk_ui_lang.h"

static BOOL zh(void) { return totk_ui_zh(); }   // the language of the host's other text (boot screen, overlays; TOTK_UI_LANG overrides)
static NSString *T(NSString *z, NSString *e) { return zh() ? z : e; }

@implementation TOTKStartView {
    void (^_onStart)(void);
    UISegmentedControl *_picture, *_fps, *_save;
    UIButton *_start;
    NSInteger _row;          // -1 save, 0 picture, 1 frame rate, 2 start (controller focus)
    NSTimer *_poll;
    BOOL _held, _done;       // a controller button or direction held since the last poll
    BOOL _hasPicture;        // the game's Settings pane has Full HD (docked): the picture row is shown
    BOOL _hasScene;          // and a docked scene row (Breath of the Wild): 1080p comes as original and HD
    BOOL _pictureSet, _fpsSet;   // changed on this screen: only these are written back (not the values read at launch)
    UIStackView *_pictureRow, *_fpsRow;
    UILabel *_customInfo, *_note;
    id _foreground;          // the foreground observer, removed at start
}

- (instancetype)initWithFrame:(CGRect)frame onStart:(void (^)(void))onStart {
    if (!(self = [super initWithFrame:frame])) return nil;
    _onStart = [onStart copy];
    _row = 2;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[(id)[UIColor colorWithRed:0.10 green:0.11 blue:0.15 alpha:1].CGColor, (id)[UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1].CGColor];
    bg.frame = self.bounds; bg.needsDisplayOnBoundsChange = YES;
    [self.layer addSublayer:bg];

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Game";

    UIImageView *icon = [[UIImageView alloc] initWithImage:[self appIcon]];
    icon.layer.cornerRadius = 28; icon.layer.cornerCurve = kCACornerCurveContinuous; icon.clipsToBounds = YES;
    icon.contentMode = UIViewContentModeScaleAspectFill; icon.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [icon.widthAnchor constraintEqualToConstant:128].active = YES; [icon.heightAnchor constraintEqualToConstant:128].active = YES;

    UILabel *title = [UILabel new];
    title.text = name; title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold]; title.textColor = UIColor.whiteColor;
    title.adjustsFontSizeToFitWidth = YES; title.minimumScaleFactor = 0.6;

    /* Breath of the Wild's pane also has the docked scene (TOTK_BOTW_SCENE, build_ipa.py botw_pane): 1080p original is
       the Switch's 1600x900 scene upscaled to 1920x1080, 1080p HD the scene at 1920x1080. */
    _hasScene = [self settingsPaneHas:@"TOTK_BOTW_SCENE"];
    _picture = _hasScene
        ? [[UISegmentedControl alloc] initWithItems:@[T(@"720p（掌机）", @"720p (handheld)"), T(@"1080p 原始", @"1080p original"), T(@"1080p 高清", @"1080p HD")]]
        : [[UISegmentedControl alloc] initWithItems:@[T(@"720p（掌机）", @"720p (handheld)"), T(@"1080p（底座）", @"1080p (docked)")]];
    _fps = [[UISegmentedControl alloc] initWithItems:@[@"30 fps", @"40 fps", @"60 fps"]];
    for (UISegmentedControl *s in @[_picture, _fps]) {
        s.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [s.widthAnchor constraintEqualToConstant:_hasScene && s == _picture ? 420 : 340].active = YES;   // three picture choices need the room
        [s addTarget:self action:@selector(picked:) forControlEvents:UIControlEventValueChanged];
    }
    _save = [[UISegmentedControl alloc] initWithItems:@[T(@"我的存档", @"My save"), T(@"100% 存档", @"100% save")]];
    _save.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [_save.widthAnchor constraintEqualToConstant:340].active = YES;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    BOOL ready = [NSFileManager.defaultManager fileExistsAtPath:[docs stringByAppendingPathComponent:@"save-personal/sync-ready.txt"]];
    [_save setEnabled:ready forSegmentAtIndex:0];
    _save.selectedSegmentIndex = ready && [[d stringForKey:@"TOTK_SAVE_PROFILE"] isEqualToString:@"personal"] ? 0 : 1;
    [_save addTarget:self action:@selector(savePicked:) forControlEvents:UIControlEventValueChanged];
    _pictureRow = [self row:T(@"画面", @"Picture") control:_picture];
    _fpsRow = [self row:T(@"帧率", @"Frame rate") control:_fps];
    _hasPicture = [self settingsPaneHas:@"TOTK_DOCKED"];
    /* With the Settings app's custom picture on, the two rows above (the presets) do not apply: the screen says what
       does instead of offering choices that change nothing. */
    _customInfo = [UILabel new];
    _customInfo.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium]; _customInfo.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _customInfo.numberOfLines = 0; _customInfo.textAlignment = NSTextAlignmentCenter;
    [_customInfo.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;

    UILabel *note = [UILabel new]; _note = note;
    if (_hasScene)
        note.text = T(@"1080p 原始：输出 1920×1080，画面 1600×900，和 Switch 底座一样。1080p 高清：画面也是 1920×1080，更清晰也更吃性能。设置也可以在“设置”App 里改。",
                      @"1080p original: 1920×1080 output with a 1600×900 scene, as the Switch docked. 1080p HD: the scene at 1920×1080 too, sharper and heavier. The Settings app has these choices too.");
    else   // Tears of the Kingdom's docked settings keep the scene at 1600x900 (main.m apply_display_settings)
        note.text = T(@"1080p：输出 1920×1080，画面 1600×900，和 Switch 底座一样，更清晰也更吃性能。设置也可以在“设置”App 里改。",
                      @"1080p: 1920×1080 output with a 1600×900 scene, as the Switch docked; sharper and heavier. The Settings app has these choices too.");
    note.font = [UIFont systemFontOfSize:13]; note.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    note.numberOfLines = 0; note.textAlignment = NSTextAlignmentCenter;
    [note.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;

    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.title = T(@"开始游戏", @"Play"); cfg.image = [UIImage systemImageNamed:@"play.fill"]; cfg.imagePadding = 8;
    cfg.baseBackgroundColor = [UIColor colorWithRed:0.10 green:0.63 blue:1.0 alpha:1]; cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(14, 40, 14, 40);
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = a.mutableCopy; m[NSFontAttributeName] = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; return m; };
    _start = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; [self start]; }]];

    /* The icon only on an iPad: on an iPhone in landscape the rows did not fit with it (user 2026-11-01). */
    NSMutableArray<UIView *> *rows = [NSMutableArray arrayWithObject:title];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) [rows insertObject:icon atIndex:0];
    [rows addObjectsFromArray:@[[self row:T(@"存档", @"Save") control:_save], _pictureRow, _fpsRow, _customInfo, note, _start]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter; stack.spacing = 12;
    [stack setCustomSpacing:16 afterView:title]; [stack setCustomSpacing:16 afterView:note];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
                                              [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                                              [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:24]]];
    [self reload];
    /* The Settings app may change these while this screen waits (the player switches to it and back): read them again. */
    __weak TOTKStartView *weak = self;
    _foreground = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { (void)n; [weak reload]; }];
    _poll = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { (void)t; [weak pollController]; }];
    return self;
}

/* Whether the app's Settings pane offers a setting: the start screen shows only what the Settings app has. */
- (BOOL)settingsPaneHas:(NSString *)key {
    NSString *path = [NSBundle.mainBundle pathForResource:@"Root" ofType:@"plist" inDirectory:@"Settings.bundle"];
    for (NSDictionary *spec in [NSDictionary dictionaryWithContentsOfFile:path][@"PreferenceSpecifiers"] ?: @[])
        if ([spec[@"Key"] isEqualToString:key]) return YES;
    return NO;
}

- (void)layoutSubviews { [super layoutSubviews]; self.layer.sublayers.firstObject.frame = self.bounds; }

- (UIStackView *)row:(NSString *)label control:(UIView *)control {
    UILabel *l = [UILabel new];
    l.text = label; l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium]; l.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    [l.widthAnchor constraintEqualToConstant:90].active = YES;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[l, control]];
    s.spacing = 16; s.alignment = UIStackViewAlignmentCenter;
    return s;
}

/* The home screen icon the build put in the app (build_ipa.py: the game's own). */
- (UIImage *)appIcon {
    NSDictionary *icons = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
    NSString *file = [icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] lastObject];
    UIImage *image = file ? [UIImage imageNamed:file] : nil;
    return image ?: [UIImage imageNamed:@"AppIcon"] ?: [UIImage systemImageNamed:@"gamecontroller.fill"];
}

- (BOOL)custom { return [NSUserDefaults.standardUserDefaults boolForKey:@"TOTK_CUSTOM_PICTURE"]; }

/* Show the settings as they are now; a row the player changed on this screen keeps the player's choice. */
- (void)reload {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!_pictureSet) _picture.selectedSegmentIndex = ![d boolForKey:@"TOTK_DOCKED"] ? 0 : _hasScene && [[d stringForKey:@"TOTK_BOTW_SCENE"] isEqualToString:@"1920x1080"] ? 2 : 1;
    if (!_fpsSet) { NSString *f = [d stringForKey:@"TOTK_PHONE_FPS"]; _fps.selectedSegmentIndex = [f isEqualToString:@"30"] ? 0 : [f isEqualToString:@"40"] ? 1 : 2; }
    BOOL custom = [self custom];
    _pictureRow.hidden = custom || !_hasPicture;
    _note.hidden = custom || !_hasPicture;
    _fpsRow.hidden = custom;
    _customInfo.hidden = !custom;
    if (custom) {
        NSString *mode = [d stringForKey:@"TOTK_IOS_PICTURE_MODE"] ?: @"720";
        NSString *picture = [mode isEqualToString:@"mfx"] ? @"MetalFX 2K" : [mode isEqualToString:@"1080"] ? @"1080p" : @"720p";
        NSString *scene = [d stringForKey:@"TOTK_RENDER_RES"] ?: @"960x540", *cap = [d stringForKey:@"TOTK_FPS_CAP"] ?: @"60";
        BOOL up = [d boolForKey:@"TOTK_MFX_UPSCALE"];
        _customInfo.text = [NSString stringWithFormat:T(@"使用“设置”App 里的自定义画质与帧率：\n画面 %@，场景 %@%@，帧率上限 %@\n（在“设置”App 里改；关闭“使用自定义设置”后这里可以选）",
                                                        @"Custom picture and frame rate from the Settings app:\n%@ picture, %@ scene%@, up to %@ fps\n(change them there; with custom settings off, you can pick here)"),
                            picture, scene, up ? T(@"（超分）", @" (upscaled)") : @"", cap];
    }
    if (_row < [self firstRow]) _row = 2;
    [self focus];
}

- (NSInteger)firstRow { return -1; }
- (void)savePicked:(UISegmentedControl *)control {
    [NSUserDefaults.standardUserDefaults setObject:control.selectedSegmentIndex == 0 ? @"personal" : @"complete" forKey:@"TOTK_SAVE_PROFILE"];
}
- (BOOL)visibleRow:(NSInteger)row {
    return row == -1 || row == 2 || (row == 0 && !_pictureRow.hidden) || (row == 1 && !_fpsRow.hidden);
}

- (void)picked:(UISegmentedControl *)control {
    if (control == _picture) _pictureSet = YES; else _fpsSet = YES;
    [self changed];
}

/* Writes only what was changed on this screen, so a value set in the Settings app meanwhile is not put back. */
- (void)changed {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (_pictureSet) {
        [d setBool:_picture.selectedSegmentIndex >= 1 forKey:@"TOTK_DOCKED"];
        if (_hasScene && _picture.selectedSegmentIndex >= 1)   // 720p keeps the docked scene the player chose last
            [d setObject:_picture.selectedSegmentIndex == 2 ? @"1920x1080" : @"1600x900" forKey:@"TOTK_BOTW_SCENE"];
    }
    if (_fpsSet) [d setObject:@[@"30", @"40", @"60"][(NSUInteger)MAX(0, MIN(2, _fps.selectedSegmentIndex))] forKey:@"TOTK_PHONE_FPS"];
}

- (void)start {
    if (_done) return;
    _done = YES;
    [_poll invalidate]; _poll = nil;
    if (_foreground) { [NSNotificationCenter.defaultCenter removeObserver:_foreground]; _foreground = nil; }
    [self changed];
    [self savePicked:_save];
    void (^go)(void) = _onStart; _onStart = nil;
    [UIView animateWithDuration:0.25 animations:^{ self.alpha = 0; } completion:^(BOOL f) { (void)f; [self removeFromSuperview]; }];
    if (go) go();
}

/* The controller's focus: a ring around the row it moves. */
- (void)focus {
    NSArray<UIView *> *rows = @[_save, _picture, _fps, _start];   // _row 0 is never focused without the picture row
    for (NSUInteger i = 0; i < rows.count; i++) {
        rows[i].layer.borderWidth = (NSInteger)i - 1 == _row ? 2 : 0;
        rows[i].layer.borderColor = [UIColor colorWithRed:0.10 green:0.63 blue:1.0 alpha:1].CGColor;
        rows[i].layer.cornerRadius = i == 3 ? 26 : 9;
    }
}

- (void)pollController {
    GCExtendedGamepad *g = GCController.current.extendedGamepad ?: GCController.controllers.firstObject.extendedGamepad;
    if (!g) return;
    float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
    BOOL up = g.dpad.up.isPressed || y > 0.5, down = g.dpad.down.isPressed || y < -0.5;
    BOOL left = g.dpad.left.isPressed || x < -0.5, right = g.dpad.right.isPressed || x > 0.5;
    BOOL confirm = g.buttonA.isPressed || g.buttonMenu.isPressed;   // A or the menu button; B is back, never "Play" (after PR #1174)
    BOOL any = up || down || left || right || confirm;
    if (!any) { _held = NO; return; }
    if (_held) return;
    _held = YES;
    if (up || down) {
        NSInteger next = _row;
        do { next += down ? 1 : -1; } while (next >= -1 && next <= 2 && ![self visibleRow:next]);
        if (next >= -1 && next <= 2) _row = next;
    }
    else if ((left || right) && _row < 2) {
        UISegmentedControl *s = _row == -1 ? _save : _row == 0 ? _picture : _fps;
        s.selectedSegmentIndex = MAX(0, MIN((NSInteger)s.numberOfSegments - 1, s.selectedSegmentIndex + (right ? 1 : -1)));
        if ([s isEnabledForSegmentAtIndex:s.selectedSegmentIndex]) {
            if (s == _save) [self savePicked:s]; else [self picked:s];
        } else s.selectedSegmentIndex = 1;
    } else if (confirm && _row == 2) { [self start]; return; }
    else if (confirm) _row = 2;
    [self focus];
}
@end
