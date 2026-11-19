#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include <vector>
#include <string>
#include <mutex>
#include <algorithm>

typedef unsigned long long uptr;
typedef unsigned int u32;

// ============ il2cpp ============
namespace il2 {
inline void* (*domain_get)();
inline const void** (*domain_get_assemblies)(void*, uptr*);
inline void* (*assembly_get_image)(const void*);
inline size_t (*field_get_offset)(void*);
inline void* (*class_get_method_from_name)(void*, const char*, int);
inline u32 (*array_length)(void*);
inline u32 (*string_length)(void*);
inline void* (*thread_attach)(void*);
inline uptr (*image_get_class_count)(void*);
inline void* (*image_get_class)(void*, uptr);
inline const char* (*class_get_name)(void*);

inline bool Resolve() {
    void* h = RTLD_DEFAULT;
    if (!dlsym(h, "il2cpp_domain_get")) {
        NSString* p = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Frameworks/UnityFramework.framework/UnityFramework"];
        h = dlopen(p.fileSystemRepresentation, RTLD_NOW);
        if (!h) return false;
    }
#define BIND(n) *(void**)&n = dlsym(h, "il2cpp_" #n); if (!n) return false;
    BIND(domain_get) BIND(domain_get_assemblies) BIND(assembly_get_image)
    BIND(field_get_offset) BIND(class_get_method_from_name)
    BIND(array_length) BIND(string_length) BIND(thread_attach)
    BIND(image_get_class_count) BIND(image_get_class) BIND(class_get_name)
#undef BIND
    return true;
}

template <class T> inline T Read(uptr a) { return a ? *(T*)a : T{}; }

inline void* FindClass(const char* name, const char* method, int argc) {
    uptr n = 0;
    auto asms = domain_get_assemblies(domain_get(), &n);
    for (uptr i = 0; i < n; ++i) {
        void* img = assembly_get_image(asms[i]);
        uptr c = image_get_class_count(img);
        for (uptr j = 0; j < c; ++j) {
            void* k = image_get_class(img, j);
            const char* cn = k ? class_get_name(k) : nullptr;
            if (!cn || strcmp(cn, name)) continue;
            if (method && !class_get_method_from_name(k, method, argc)) continue;
            return k;
        }
    }
    return nullptr;
}

template <class R, class... A> inline R Call(void* fn, void* self, A... a) {
    return ((R(*)(void*, A...))fn)(self, a...);
}
inline void* Mptr(void* mi) { return mi ? *(void**)mi : nullptr; }

inline void* ArrAt(void* arr, u32 i, uptr elem) {
    if (!arr) return nullptr;
    if (i >= array_length(arr)) return nullptr;
    return (void*)((uptr)arr + 0x20 + (uptr)i * elem);
}

inline std::string Str(void* s) {
    if (!s) return {};
    u32 len = string_length(s);
    if (len == 0 || len > 32) return {};
    char16_t* c = (char16_t*)((uptr)s + 0x14);
    std::string o; o.reserve(len);
    for (u32 i = 0; i < len; ++i) o += (char)(c[i] < 128 ? c[i] : '?');
    return o;
}
}

// ============ estado ============
struct Vec3 { float x, y, z; };
struct Snap { Vec3 head, feet, pos; float hp, dist; std::string name; };

static const uptr kStashData = 0x28;
static const uptr kLocalPos  = 0x80;

struct Ctx {
    void* getDefault{};
    void* posS{}; void* hpS{}; void* nmS{};
    void* camGet{}; void* camTr{};
    void* w2s{}; void* getE{}; void* setE{};
    bool ok = false;
} g_ctx;

struct Cfg {
    bool esp = true, box = true, health = true, names = true;
    float maxDist = 250.f, fov = 150.f, smooth = 4.f;
    bool aim = false;
} g_cfg;

static std::vector<Snap> g_snaps;
static std::mutex g_mtx;
static std::string g_status = "OSM: iniciando";

// ============ resolve ============
static bool ResolveGame() {
    if (!il2::Resolve()) { g_status = "OSM: sin il2cpp"; return false; }
    void* wc = il2::FindClass("World", "get_Default", 0);
    void* pc = il2::FindClass("Position", "GetStash", 1);
    void* hc = il2::FindClass("Health", "GetStash", 1);
    void* nc = il2::FindClass("NicknameText", "GetStash", 1);
    void* cc = il2::FindClass("Camera", "get_main", 0);
    void* tc = il2::FindClass("Transform", "set_localEulerAngles", 1);
    if (!wc || !pc || !hc || !cc || !tc) { g_status = "OSM: clases no encontradas"; return false; }

    g_ctx.getDefault = il2::Mptr(il2::class_get_method_from_name(wc, "get_Default", 0));
    g_ctx.posS  = il2::Mptr(il2::class_get_method_from_name(pc, "GetStash", 1));
    g_ctx.hpS   = il2::Mptr(il2::class_get_method_from_name(hc, "GetStash", 1));
    g_ctx.nmS   = il2::Mptr(il2::class_get_method_from_name(nc, "GetStash", 1));
    g_ctx.camGet= il2::Mptr(il2::class_get_method_from_name(cc, "get_main", 0));
    g_ctx.camTr = il2::Mptr(il2::class_get_method_from_name(cc, "get_transform", 0));
    g_ctx.w2s   = il2::Mptr(il2::class_get_method_from_name(cc, "WorldToScreenPoint", 1));
    g_ctx.getE  = il2::Mptr(il2::class_get_method_from_name(tc, "get_localEulerAngles", 0));
    g_ctx.setE  = il2::Mptr(il2::class_get_method_from_name(tc, "set_localEulerAngles", 1));

    void* w = g_ctx.getDefault ? il2::Call<void*>(g_ctx.getDefault, nullptr) : nullptr;
    void* s = (w && g_ctx.posS) ? il2::Call<void*>(g_ctx.posS, nullptr, w) : nullptr;
    bool lay = s && il2::Read<void*>((uptr)s + 0x10) == w;

    if (!lay) { g_status = "OSM: layout de stash distinto"; return false; }
    if (!g_ctx.w2s || !g_ctx.setE) { g_status = "OSM: metodos Unity no encontrados"; return false; }
    g_status = "OSM: OK";
    return g_ctx.ok = true;
}

// ============ datos ============
static void Collect() {
    void* w = il2::Call<void*>(g_ctx.getDefault, nullptr);
    void* c = il2::Call<void*>(g_ctx.camGet, nullptr);
    if (!w || !c) return;
    void* ct = il2::Call<void*>(g_ctx.camTr, c);
    if (!ct) return;
    Vec3 me = il2::Read<Vec3>((uptr)ct + kLocalPos);

    void* ps = il2::Call<void*>(g_ctx.posS, nullptr, w);
    void* hs = il2::Call<void*>(g_ctx.hpS, nullptr, w);
    void* ns = g_ctx.nmS ? il2::Call<void*>(g_ctx.nmS, nullptr, w) : nullptr;
    if (!ps || !hs) return;

    void* pa = il2::Read<void*>((uptr)ps + kStashData);
    void* ha = il2::Read<void*>((uptr)hs + kStashData);
    void* na = ns ? il2::Read<void*>((uptr)ns + kStashData) : nullptr;
    if (!pa || !ha) return;

    std::vector<Snap> out;
    u32 n = il2::array_length(pa);
    for (u32 i = 0; i < n; ++i) {
        int* hp = (int*)il2::ArrAt(ha, i, 4);
        if (!hp || *hp <= 0 || *hp > 200) continue;
        Vec3* p = (Vec3*)il2::ArrAt(pa, i, 12);
        if (!p || isnan(p->x) || isnan(p->y)) continue;
        float dx = p->x-me.x, dy = p->y-me.y, dz = p->z-me.z;
        float d = sqrtf(dx*dx+dy*dy+dz*dz);
        if (d < 1.5f || d > g_cfg.maxDist) continue;
        std::string nm;
        if (void* sp = il2::ArrAt(na, i, 16)) nm = il2::Str(il2::Read<void*>(sp));
        if (nm.empty()) continue;
        Snap s{};
        s.pos = s.feet = *p;
        s.head = Vec3{ p->x, p->y + 1.8f, p->z };
        s.hp = (float)*hp; s.dist = d; s.name = nm;
        out.push_back(std::move(s));
    }
    { std::lock_guard<std::mutex> l(g_mtx); g_snaps = std::move(out); }
}

static void DoAim() {
    if (!g_cfg.aim) return;
    void* c = il2::Call<void*>(g_ctx.camGet, nullptr);
    if (!c) return;
    void* ct = il2::Call<void*>(g_ctx.camTr, c);
    if (!ct) return;
    Vec3 me = il2::Read<Vec3>((uptr)ct + kLocalPos);

    Snap* best = nullptr; float bd = g_cfg.fov;
    { std::lock_guard<std::mutex> l(g_mtx);
      for (auto& s : g_snaps) {
        float dx = s.head.x-me.x, dy = s.head.y-me.y, dz = s.head.z-me.z;
        float d = sqrtf(dx*dx+dy*dy+dz*dz); if (d < 0.1f) continue;
        float a = acosf(std::clamp(dy/d, -1.f, 1.f)) * 57.2958f;
        if (a < bd) { bd = a; best = &s; } } }
    if (!best) return;

    Vec3 e = il2::Call<Vec3>(g_ctx.getE, ct);
    Vec3 d{ best->head.x-me.x, best->head.y-me.y, best->head.z-me.z };
    float ty = atan2f(d.x, d.z) * 57.2958f;
    float tp = -atan2f(d.y, sqrtf(d.x*d.x + d.z*d.z)) * 57.2958f;
    float k = std::clamp(g_cfg.smooth, 1.f, 12.f);
    il2::Call<void>(g_ctx.setE, ct, Vec3{ e.x + (tp-e.x)/k, e.y + (ty-e.y)/k, 0.f });
}

// ============ ESP ============
@interface OSESP : UIView
@property (nonatomic) CADisplayLink* link;
@end

@implementation OSESP
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)tick { [self setNeedsDisplay]; }
- (bool)w2s:(Vec3)w out:(CGPoint*)o {
    if (!g_ctx.ok) return false;
    void* c = il2::Call<void*>(g_ctx.camGet, nullptr);
    if (!c) return false;
    Vec3 s = il2::Call<Vec3>(g_ctx.w2s, c, w);
    if (s.z < 0.1f) return false;
    CGSize b = self.bounds.size;
    *o = CGPointMake(s.x, b.height - s.y);
    return true;
}
- (void)drawRect:(CGRect)r {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(ctx, 1.4);

    NSString* st = [NSString stringWithUTF8String:g_status.c_str()];
    [st drawAtPoint:CGPointMake(10, 54)
     withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                       NSForegroundColorAttributeName: UIColor.greenColor }];

    if (!g_cfg.esp || !g_ctx.ok) return;
    std::vector<Snap> cp;
    { std::lock_guard<std::mutex> l(g_mtx); cp = g_snaps; }

    for (auto& s : cp) {
        CGPoint h, f;
        if (![self w2s:s.head out:&h] || ![self w2s:s.feet out:&f]) continue;
        float ht = f.y - h.y; if (ht < 5) continue;
        float w = ht * 0.5f;

        if (g_cfg.box) {
            CGContextSetStrokeColorWithColor(ctx, UIColor.greenColor.CGColor);
            CGContextStrokeRect(ctx, CGRectMake(h.x-w/2, h.y, w, ht));
        }
        if (g_cfg.health) {
            CGContextSetFillColorWithColor(ctx, UIColor.greenColor.CGColor);
            CGContextFillRect(ctx, CGRectMake(h.x-w/2-5, f.y-ht*(s.hp/100.f), 3, ht*(s.hp/100.f)));
        }
        if (g_cfg.names) {
            [[NSString stringWithUTF8String:s.name.c_str()]
                drawAtPoint:CGPointMake(h.x-w/2, h.y-14)
             withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                               NSForegroundColorAttributeName: UIColor.whiteColor }];
        }
        [[NSString stringWithFormat:@"%.0fm", s.dist]
            drawAtPoint:CGPointMake(h.x-8, f.y+1)
         withAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:9],
                           NSForegroundColorAttributeName: UIColor.lightGrayColor }];
    }
}
@end

// ============ menú ============
static UIWindow* g_win;
static UIView* g_panel;
static bool g_open = false;

static void mkSwitch(UIStackView* st, NSString* title, bool* val, SEL act, id tgt) {
    UIStackView* row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    UILabel* l = [[UILabel alloc] init];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
    UISwitch* sw = [[UISwitch alloc] init];
    sw.on = *val; sw.tag = (NSInteger)val;
    [sw addTarget:tgt action:act forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:l]; [row addArrangedSubview:sw];
    [st addArrangedSubview:row];
}

static void mkSlider(UIStackView* st, NSString* title, float* val, float lo, float hi, SEL act, id tgt) {
    UILabel* l = [[UILabel alloc] init];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
    UISlider* sl = [[UISlider alloc] init];
    sl.minimumValue = lo; sl.maximumValue = hi; sl.value = *val; sl.tag = (NSInteger)val;
    [sl addTarget:tgt action:act forControlEvents:UIControlEventValueChanged];
    [st addArrangedSubview:l]; [st addArrangedSubview:sl];
}

@interface OSVC : UIViewController
@property UIButton* btn;
@end

@implementation OSVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    OSESP* esp = [[OSESP alloc] initWithFrame:self.view.bounds];
    esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:esp];

    _btn = [UIButton buttonWithType:UIButtonTypeSystem];
    _btn.frame = CGRectMake(18, 100, 50, 50);
    _btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _btn.layer.cornerRadius = 25;
    _btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_btn setTitle:@"OSM" forState:UIControlStateNormal];
    [_btn setTitleColor:UIColor.greenColor forState:UIControlStateNormal];
    [_btn addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_btn];

    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 290, 430)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    g_panel.layer.cornerRadius = 14;
    g_panel.center = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2);
    g_panel.hidden = YES;

    UIStackView* st = [[UIStackView alloc] initWithFrame:CGRectMake(14, 44, 262, 370)];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 10;
    [g_panel addSubview:st];

    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 200, 22)];
    t.text = @"OneState Menu"; t.textColor = UIColor.greenColor;
    t.font = [UIFont boldSystemFontOfSize:16];
    [g_panel addSubview:t];

    mkSwitch(st, @"ESP", &g_cfg.esp, @selector(swChanged:), self);
    mkSwitch(st, @"Cajas", &g_cfg.box, @selector(swChanged:), self);
    mkSwitch(st, @"Vida", &g_cfg.health, @selector(swChanged:), self);
    mkSwitch(st, @"Nombres", &g_cfg.names, @selector(swChanged:), self);
    mkSwitch(st, @"Aimbot", &g_cfg.aim, @selector(swChanged:), self);
    mkSlider(st, @"Distancia", &g_cfg.maxDist, 20, 800, @selector(slChanged:), self);
    mkSlider(st, @"FOV", &g_cfg.fov, 20, 600, @selector(slChanged:), self);
    mkSlider(st, @"Smooth", &g_cfg.smooth, 1, 12, @selector(slChanged:), self);

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(240, 8, 40, 30);
    [close setTitle:@"X" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:close];

    [self.view addSubview:g_panel];
}
- (void)toggle { g_open = !g_open; g_panel.hidden = !g_open; }
- (void)swChanged:(UISwitch*)s { *(bool*)s.tag = s.on; }
- (void)slChanged:(UISlider*)s { *(float*)s.tag = s.value; }
@end

@interface OSWin : UIWindow @end
@implementation OSWin
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    OSVC* vc = (OSVC*)self.rootViewController;
    if (CGRectContainsPoint(vc.btn.frame, p)) return vc.btn;
    if (g_open && CGRectContainsPoint(g_panel.frame, p)) return [super hitTest:p withEvent:e];
    return nil;
}
@end

// ============ arranque ============
static void StartThread() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        il2::thread_attach(il2::domain_get());
        while (true) {
            @autoreleasepool {
                if (g_ctx.ok) { Collect(); DoAim(); }
            }
            usleep(16000);
        }
    });
}

__attribute__((constructor))
static void osm_init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_win = [[OSWin alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_win.rootViewController = [OSVC new];
        g_win.windowLevel = UIWindowLevelStatusBar + 1;
        g_win.backgroundColor = UIColor.clearColor;
        g_win.hidden = NO;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (int i = 0; i < 60 && !g_ctx.ok; ++i) {
                @autoreleasepool { if (ResolveGame()) { StartThread(); return; } }
                sleep(1);
            }
        });
    });
}
