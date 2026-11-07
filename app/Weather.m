#import "Weather.h"
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <math.h>

static NSString *const WeatherHost = @"api.open-meteo.com";
static NSString *const LocalWeatherPreference = @"useLocalWeather";

typedef NS_ENUM(NSInteger, WeatherSky) {
    WeatherSkyIdle, WeatherSkyClear, WeatherSkyPartlyCloudy, WeatherSkyCloudy,
    WeatherSkyFog, WeatherSkyRain, WeatherSkyStorm, WeatherSkySnow
};

static WeatherSky SkyForCode(NSInteger code)
{
    switch (code) {
        case 0: return WeatherSkyClear;
        case 1: case 2: return WeatherSkyPartlyCloudy;
        case 3: return WeatherSkyCloudy;
        case 45: case 48: return WeatherSkyFog;
        case 51: case 53: case 55: case 56: case 57:
        case 61: case 63: case 65: case 66: case 67:
        case 80: case 81: case 82: return WeatherSkyRain;
        case 71: case 73: case 75: case 77: case 85: case 86: return WeatherSkySnow;
        case 95: case 96: case 99: return WeatherSkyStorm;
        default: return WeatherSkyIdle;
    }
}

static UIColor *Shade(NSUInteger rgb, CGFloat alpha)
{
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
                           green:((rgb >> 8) & 255) / 255.0
                            blue:(rgb & 255) / 255.0 alpha:alpha];
}

@interface SkyView : UIView
@property(nonatomic) WeatherSky sky;
@property(nonatomic) BOOL daylight;
@property(nonatomic) BOOL running;
@property(nonatomic) CGSize drawnSize;
- (void)redraw;
@end

@implementation SkyView

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.drawnSize, self.bounds.size)) [self redraw];
}

- (void)addCloudAt:(CGPoint)point scale:(CGFloat)scale opacity:(CGFloat)opacity duration:(NSTimeInterval)duration
{
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(12, 43, 200, 55) cornerRadius:27];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(34, 22, 79, 73)]];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(78, 0, 100, 94)]];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(141, 26, 63, 68)]];
    CAShapeLayer *cloud = [CAShapeLayer layer];
    cloud.path = path.CGPath;
    cloud.bounds = CGRectMake(0, 0, 224, 100);
    cloud.position = point;
    cloud.transform = CATransform3DMakeScale(scale, scale, 1);
    cloud.fillColor = Shade(0xd7e9f7, opacity).CGColor;
    [self.layer addSublayer:cloud];
    if (self.running) {
        CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"position.x"];
        drift.fromValue = @(point.x - 45);
        drift.toValue = @(point.x + 45);
        drift.duration = duration;
        drift.autoreverses = YES;
        drift.repeatCount = HUGE_VALF;
        drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [cloud addAnimation:drift forKey:@"drift"];
    }
}

- (void)addOrbAt:(CGPoint)point size:(CGFloat)size
{
    CALayer *orb = [CALayer layer];
    orb.bounds = CGRectMake(0, 0, size, size);
    orb.position = point;
    orb.cornerRadius = size / 2;
    orb.backgroundColor = Shade(self.daylight ? 0xffd580 : 0xc2dcff, 0.95).CGColor;
    orb.shadowColor = orb.backgroundColor;
    orb.shadowOpacity = 0.75;
    orb.shadowRadius = size / 2;
    orb.shadowOffset = CGSizeZero;
    orb.shadowPath = [UIBezierPath bezierPathWithOvalInRect:orb.bounds].CGPath;
    [self.layer addSublayer:orb];
    if (self.running) {
        CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        glow.fromValue = @0.42;
        glow.toValue = @0.82;
        glow.duration = 4;
        glow.autoreverses = YES;
        glow.repeatCount = HUGE_VALF;
        [orb addAnimation:glow forKey:@"glow"];
    }
}

- (void)addPrecipitationSnow:(BOOL)snow
{
    CGSize size = snow ? CGSizeMake(5, 5) : CGSizeMake(2, 16);
    UIGraphicsBeginImageContextWithOptions(size, NO, 1);
    [Shade(0xd9efff, 0.62) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:size.width / 2] fill];
    UIImage *particle = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    CGFloat width = self.bounds.size.width;
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = self.bounds;
    emitter.emitterPosition = CGPointMake(width * 0.57, -24);
    emitter.emitterSize = CGSizeMake(width * 1.45, 1);
    emitter.emitterShape = kCAEmitterLayerLine;
    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (__bridge id)particle.CGImage;
    cell.birthRate = snow ? 15 : (self.sky == WeatherSkyStorm ? 75 : 48);
    cell.lifetime = snow ? 10 : 4;
    cell.velocity = snow ? 85 : 420;
    cell.velocityRange = snow ? 35 : 105;
    cell.emissionLongitude = M_PI / 2 + 0.12;
    cell.emissionRange = snow ? 0.24 : 0.08;
    emitter.emitterCells = @[cell];
    [self.layer addSublayer:emitter];
}

- (void)addNightStars
{
    CGSize size = self.bounds.size;
    for (NSUInteger index = 0; index < 28; index++) {
        CGFloat diameter = index % 5 == 0 ? 3 : 1.5;
        CALayer *star = [CALayer layer];
        star.bounds = CGRectMake(0, 0, diameter, diameter);
        star.position = CGPointMake(size.width * ((index * 37 + 11) % 101) / 101,
                                    size.height * ((index * 67 + 17) % 103) / 103);
        star.cornerRadius = diameter / 2;
        star.backgroundColor = Shade(0xe3eeff, 1).CGColor;
        star.opacity = 0.48;
        [self.layer addSublayer:star];
        if (self.running) {
            CABasicAnimation *twinkle = [CABasicAnimation animationWithKeyPath:@"opacity"];
            twinkle.fromValue = @0.22;
            twinkle.toValue = @0.78;
            twinkle.duration = 2.8 + (index % 6) * 0.44;
            twinkle.timeOffset = (index % 7) * 0.4;
            twinkle.autoreverses = YES;
            twinkle.repeatCount = HUGE_VALF;
            [star addAnimation:twinkle forKey:@"twinkle"];
        }
    }
}

- (void)addFog
{
    CGSize size = self.bounds.size;
    for (NSUInteger index = 0; index < 3; index++) {
        CAGradientLayer *mist = [CAGradientLayer layer];
        mist.bounds = CGRectMake(0, 0, size.width * 1.5, size.height * 0.26);
        mist.position = CGPointMake(size.width * 0.5, size.height * (0.38 + index * 0.22));
        mist.colors = @[(__bridge id)Shade(0xe1edf7, 0).CGColor, (__bridge id)Shade(0xe1edf7, 0.30).CGColor,
                        (__bridge id)Shade(0xe1edf7, 0).CGColor];
        [self.layer addSublayer:mist];
        if (self.running) {
            CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"position.y"];
            drift.fromValue = @(mist.position.y - 22);
            drift.toValue = @(mist.position.y + 22);
            drift.duration = 12 + index * 3;
            drift.autoreverses = YES;
            drift.repeatCount = HUGE_VALF;
            [mist addAnimation:drift forKey:@"mist"];
        }
    }
}

- (void)addStormGlow
{
    CALayer *glow = [CALayer layer];
    glow.frame = self.bounds;
    glow.backgroundColor = Shade(0xdce9ff, 1).CGColor;
    glow.opacity = 0;
    [self.layer addSublayer:glow];
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    pulse.values = @[@0, @0, @0.17, @0, @0];
    pulse.keyTimes = @[@0, @0.78, @0.81, @0.85, @1];
    pulse.duration = 16;
    pulse.repeatCount = HUGE_VALF;
    [glow addAnimation:pulse forKey:@"stormGlow"];
}

- (void)redraw
{
    self.drawnSize = self.bounds.size;
    for (CALayer *layer in [self.layer.sublayers copy]) [layer removeFromSuperlayer];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;
    BOOL clear = self.sky == WeatherSkyClear || self.sky == WeatherSkyPartlyCloudy;
    BOOL wet = self.sky == WeatherSkyRain || self.sky == WeatherSkyStorm || self.sky == WeatherSkySnow;
    NSUInteger top = clear && self.daylight ? 0x1e5d85 : (wet ? 0x273c52 : 0x33495e);
    NSUInteger bottom = clear && self.daylight ? 0x48819c : 0x131e34;
    if (!self.daylight || self.sky == WeatherSkyIdle) {
        top = wet ? 0x203247 : 0x142540;
        bottom = 0x0e1728;
    }

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = self.bounds;
    gradient.colors = @[(__bridge id)Shade(top, 1).CGColor, (__bridge id)Shade(bottom, 1).CGColor];
    [self.layer addSublayer:gradient];

    if (clear && !self.daylight) [self addNightStars];
    if (clear) [self addOrbAt:CGPointMake(width * 0.88, height * 0.78) size:MIN(98, width * 0.16)];
    if (self.sky == WeatherSkyFog) {
        [self addFog];
    } else if (self.sky >= WeatherSkyPartlyCloudy) {
        CGFloat opacity = self.daylight ? 0.27 : 0.18;
        [self addCloudAt:CGPointMake(width * 0.16, height * 0.26) scale:1.55 opacity:opacity duration:19];
        [self addCloudAt:CGPointMake(width * 0.74, height * 0.39) scale:1.8 opacity:opacity duration:24];
        [self addCloudAt:CGPointMake(width * 0.43, height * 0.68) scale:1.9 opacity:opacity * 0.72 duration:28];
    }
    if (wet && self.running) [self addPrecipitationSnow:self.sky == WeatherSkySnow];
    if (self.sky == WeatherSkyStorm && self.running) [self addStormGlow];
}
@end

// iOS 9 predates the ISRG trust roots. Add them only to the weather session,
// preserving TLS, hostname, validity and certificate-chain validation.
@interface WeatherTransport : NSObject <NSURLSessionTaskDelegate>
@end

@implementation WeatherTransport
- (void)URLSession:(__unused NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] ||
        ![space.host isEqualToString:WeatherHost] || !space.serverTrust) {
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    NSMutableArray *anchors = [NSMutableArray arrayWithCapacity:2];
    for (NSString *name in @[@"ISRG-Root-X1", @"ISRG-Root-X2"]) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"der"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (!data) continue;
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
        if (certificate) [anchors addObject:CFBridgingRelease(certificate)];
    }

    SecTrustRef trust = space.serverTrust;
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)WeatherHost);
    OSStatus policyStatus = SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    SecTrustResultType result = kSecTrustResultInvalid;
    BOOL valid = policyStatus == errSecSuccess
        && SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors) == errSecSuccess
        && SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess
        && SecTrustEvaluate(trust, &result) == errSecSuccess
        && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
    if (valid) completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    else completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task
    willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(__unused NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion
{
    // Never forward the location request to another URL or protocol.
    completion(nil);
}
@end

@interface LocalWeather () <CLLocationManagerDelegate>
@property(nonatomic, strong) SkyView *skyView;
@property(nonatomic, weak) UILabel *label;
@property(nonatomic, strong) CLLocationManager *locationManager;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSDate *updatedAt;
@property(nonatomic, copy) NSString *lastSummary;
@property(nonatomic) BOOL locating;
@property(nonatomic) BOOL active;
@property(nonatomic) NSUInteger requestID;
@end

@implementation LocalWeather

- (instancetype)initWithBackdrop:(UIView *)backdrop label:(UILabel *)label
{
    self = [super init];
    if (self) {
        _label = label;
        _label.text = @"Ative o clima em Ajustes";
        _skyView = [[SkyView alloc] initWithFrame:backdrop.bounds];
        _skyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _skyView.userInteractionEnabled = NO;
        [backdrop insertSubview:_skyView atIndex:0];
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
            delegate:[[WeatherTransport alloc] init] delegateQueue:nil];
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;
    }
    return self;
}

- (void)resume
{
    if (self.active) return;
    self.active = YES;
    self.skyView.running = !UIAccessibilityIsReduceMotionEnabled();
    [self.skyView redraw];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:15 * 60 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    if (self.enabled && [CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
        self.label.text = @"Permita a Localização em Ajustes";
    } else if (!self.updatedAt || -[self.updatedAt timeIntervalSinceNow] >= 15 * 60) {
        [self poll:nil];
    }
}

- (void)pause
{
    self.active = NO;
    [self.timer invalidate];
    self.timer = nil;
    [self.locationManager stopUpdatingLocation];
    self.locating = NO;
    [self.task cancel];
    self.task = nil;
    self.requestID++;
    self.skyView.running = NO;
    [self.skyView redraw];
}

- (BOOL)isEnabled
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:LocalWeatherPreference];
}

- (void)disable
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:LocalWeatherPreference];
    BOOL wasActive = self.active;
    [self pause];
    self.updatedAt = nil;
    self.lastSummary = nil;
    self.skyView.sky = WeatherSkyIdle;
    self.skyView.daylight = NO;
    [self.skyView redraw];
    self.label.text = @"Ative o clima em Ajustes";
    if (wasActive) [self resume];
}

- (void)enable
{
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LocalWeatherPreference];
    if (![CLLocationManager locationServicesEnabled]) {
        self.label.text = @"Ative a Localização no iPad";
        return;
    }
    switch ([CLLocationManager authorizationStatus]) {
        case kCLAuthorizationStatusNotDetermined:
            [self.locationManager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusDenied: case kCLAuthorizationStatusRestricted:
            self.label.text = @"Permita a Localização nos Ajustes do iPad";
            break;
        default:
            [self poll:nil];
            break;
    }
}

- (void)poll:(__unused NSTimer *)timer
{
    CLAuthorizationStatus authorization = [CLLocationManager authorizationStatus];
    if (!self.active || !self.enabled || self.locating || self.task ||
        (authorization != kCLAuthorizationStatusAuthorizedWhenInUse && authorization != kCLAuthorizationStatusAuthorizedAlways)) return;
    self.locating = YES;
    if (!self.lastSummary) self.label.text = @"Buscando o clima local…";
    NSUInteger request = ++self.requestID;
    [self.locationManager startUpdatingLocation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.requestID == request && self.locating) {
            [self.locationManager stopUpdatingLocation];
            self.locating = NO;
            [self showError:@"Localização indisponível"];
        }
    });
}

- (void)locationManager:(__unused CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [self poll:nil];
    } else if (self.enabled && (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted)) {
        BOOL wasActive = self.active;
        [self pause];
        self.updatedAt = nil;
        self.lastSummary = nil;
        self.skyView.sky = WeatherSkyIdle;
        self.skyView.daylight = NO;
        [self.skyView redraw];
        self.label.text = @"Localização desativada";
        if (wasActive) [self resume];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if (!self.locating || error.code == kCLErrorLocationUnknown) return;
    [manager stopUpdatingLocation];
    self.locating = NO;
    [self showError:@"Localização indisponível"];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    CLLocation *location = locations.lastObject;
    if (!self.active || !self.locating || !location || location.horizontalAccuracy < 0 ||
        !CLLocationCoordinate2DIsValid(location.coordinate) || fabs([location.timestamp timeIntervalSinceNow]) > 120) return;
    [manager stopUpdatingLocation];
    self.locating = NO;

    // Send only the nearest tenth of a degree (~11 km between latitude grid points).
    NSString *endpoint = [NSString stringWithFormat:
        @"https://%@/v1/forecast?latitude=%.1f&longitude=%.1f&current=temperature_2m,weather_code,is_day",
        WeatherHost, location.coordinate.latitude, location.coordinate.longitude];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:endpoint]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    NSUInteger requestID = self.requestID;
    self.task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *current = nil;
            if (!error && data.length && [response isKindOfClass:[NSHTTPURLResponse class]] &&
                [(NSHTTPURLResponse *)response statusCode] == 200) {
                id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([payload isKindOfClass:[NSDictionary class]] && [payload[@"current"] isKindOfClass:[NSDictionary class]]) {
                    current = payload[@"current"];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.requestID != requestID) return;
                self.task = nil;
                [self applyCurrent:current];
            });
        }];
    [self.task resume];
}

- (void)applyCurrent:(NSDictionary *)current
{
    NSNumber *code = current[@"weather_code"];
    NSNumber *temperature = current[@"temperature_2m"];
    NSNumber *isDay = current[@"is_day"];
    if (![code isKindOfClass:[NSNumber class]] || ![temperature isKindOfClass:[NSNumber class]] ||
        ![isDay isKindOfClass:[NSNumber class]] || !isfinite(temperature.doubleValue)) {
        [self showError:@"Clima indisponível"];
        return;
    }
    WeatherSky sky = SkyForCode(code.integerValue);
    BOOL daylight = isDay.boolValue;
    NSString *conditions;
    switch (sky) {
        case WeatherSkyClear: conditions = daylight ? @"Ensolarado" : @"Céu limpo"; break;
        case WeatherSkyPartlyCloudy: conditions = @"Parcialmente nublado"; break;
        case WeatherSkyCloudy: conditions = @"Nublado"; break;
        case WeatherSkyFog: conditions = @"Neblina"; break;
        case WeatherSkyRain: conditions = @"Chuva"; break;
        case WeatherSkyStorm: conditions = @"Trovoadas"; break;
        case WeatherSkySnow: conditions = @"Neve"; break;
        default: conditions = @"Clima local"; break;
    }
    self.lastSummary = [NSString stringWithFormat:@"%.0f °C  ·  %@", temperature.doubleValue, conditions];
    self.updatedAt = [NSDate date];
    self.label.text = self.lastSummary;
    if (self.skyView.sky != sky || self.skyView.daylight != daylight) {
        self.skyView.sky = sky;
        self.skyView.daylight = daylight;
        [self.skyView redraw];
    }
}

- (void)showError:(NSString *)message
{
    if (self.updatedAt && -[self.updatedAt timeIntervalSinceNow] < 2 * 60 * 60) {
        self.label.text = [self.lastSummary stringByAppendingString:@"  ·  última leitura"];
    } else {
        self.lastSummary = nil;
        self.updatedAt = nil;
        self.label.text = message;
        self.skyView.sky = WeatherSkyIdle;
        self.skyView.daylight = NO;
        [self.skyView redraw];
    }
}
@end
