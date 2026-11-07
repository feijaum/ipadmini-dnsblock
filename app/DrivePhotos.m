#import "DrivePhotos.h"
#import <ImageIO/ImageIO.h>
#import <Security/Security.h>

static NSString *const DriveHost = @"script.google.com";
static NSString *const ResultHost = @"script.googleusercontent.com";
static NSString *const DriveEndpoint = @"drivePhotosEndpoint";
static NSString *const DriveAccessKey = @"drivePhotosAccessKey";
enum { MaxPhotos = 20, MaxPhotoBytes = 256 * 1024, MaxResponseBytes = 8 * 1024 * 1024 };

@interface DriveTransport : NSObject <NSURLSessionTaskDelegate>
@end

@implementation DriveTransport
- (void)URLSession:(__unused NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] ||
        !space.serverTrust || !([space.host isEqualToString:DriveHost] || [space.host isEqualToString:ResultHost])) {
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    NSMutableArray *anchors = [NSMutableArray array];
    for (NSString *name in @[@"GTS-Root-R1", @"GTS-Root-R3", @"GTS-Root-R4"]) {
        NSURL *resource = [[NSBundle mainBundle] URLForResource:name withExtension:@"der"];
        NSData *data = resource ? [NSData dataWithContentsOfURL:resource] : nil;
        if (!data) continue;
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
        if (certificate) [anchors addObject:CFBridgingRelease(certificate)];
    }

    SecTrustRef trust = space.serverTrust;
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)space.host);
    OSStatus policyStatus = SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    SecTrustResultType result = kSecTrustResultInvalid;
    BOOL valid = policyStatus == errSecSuccess
        && SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors) == errSecSuccess
        && SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess
        && SecTrustEvaluate(trust, &result) == errSecSuccess
        && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
    completion(valid ? NSURLSessionAuthChallengeUseCredential : NSURLSessionAuthChallengeCancelAuthenticationChallenge,
               valid ? [NSURLCredential credentialForTrust:trust] : nil);
}

- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion
{
    NSURL *url = request.URL;
    if (![response.URL.host isEqualToString:DriveHost] || ![url.scheme isEqualToString:@"https"] ||
        ![url.host isEqualToString:ResultHost] || url.user || url.password ||
        (url.port && url.port.integerValue != 443)) {
        completion(nil);
        return;
    }
    // Content Service returns a separate URL for the result. Send a fresh GET without the pairing key.
    completion([NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25]);
}
@end

@interface DrivePhotos ()
@property(nonatomic, readwrite, copy) NSString *status;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSArray *photos;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL active;
@end

@implementation DrivePhotos
- (instancetype)init
{
    self = [super init];
    if (self) {
        _status = self.connected ? @"Conectando ao Drive…" : @"Drive desconectado";
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForResource = 60;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:[[DriveTransport alloc] init] delegateQueue:nil];
    }
    return self;
}

- (NSString *)endpoint { return [[NSUserDefaults standardUserDefaults] stringForKey:DriveEndpoint]; }
- (NSString *)key { return [[NSUserDefaults standardUserDefaults] stringForKey:DriveAccessKey]; }
- (BOOL)connected { return self.endpoint.length && self.key.length; }

- (BOOL)connectToURL:(NSString *)address key:(NSString *)key
{
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    address = [address stringByTrimmingCharactersInSet:space];
    key = [key stringByTrimmingCharactersInSet:space];
    NSURL *url = [NSURL URLWithString:address];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    NSArray *path = url.pathComponents;
    if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:DriveHost] ||
        url.user || url.password || url.port || url.query || url.fragment ||
        path.count != 5 || ![path[1] isEqualToString:@"macros"] || ![path[2] isEqualToString:@"s"] ||
        ![path[4] isEqualToString:@"exec"] || [path[3] rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound ||
        key.length < 24 || key.length > 128 || [key rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;

    [self reset];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:address forKey:DriveEndpoint];
    [defaults setObject:key forKey:DriveAccessKey];
    self.status = @"Conectando ao Drive…";
    if (self.didUpdate) self.didUpdate();
    [self refresh];
    return YES;
}

- (void)reset
{
    self.generation++;
    [self.task cancel];
    self.task = nil;
    self.photos = nil;
    self.revision = nil;
    self.index = 0;
}

- (void)disconnect
{
    [self reset];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:DriveEndpoint];
    [defaults removeObjectForKey:DriveAccessKey];
    self.status = @"Drive desconectado";
    if (self.didUpdate) self.didUpdate();
}

- (void)resume
{
    if (self.active) return;
    self.active = YES;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [self refresh];
}

- (void)pause
{
    self.active = NO;
    [self.timer invalidate];
    self.timer = nil;
    self.generation++;
    [self.task cancel];
    self.task = nil;
}

- (void)poll:(__unused NSTimer *)timer { [self refresh]; }

- (void)refresh
{
    if (!self.active || !self.connected || self.task) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.endpoint]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"key":self.key, @"revision":self.revision ?: @""}
        options:0 error:NULL];
    NSUInteger generation = self.generation;
    self.task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *payload = nil;
            NSMutableArray *photos = [NSMutableArray array];
            if (!error && data.length && data.length <= MaxResponseBytes &&
                [response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)response statusCode] == 200) {
                id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([decoded isKindOfClass:[NSDictionary class]]) payload = decoded;
                id images = payload[@"photos"];
                if ([images isKindOfClass:[NSArray class]] && [images count] <= MaxPhotos) {
                    for (id image in images) {
                        if (![image isKindOfClass:[NSString class]] || [image length] > 4 * ((MaxPhotoBytes + 2) / 3)) continue;
                        NSData *bytes = [[NSData alloc] initWithBase64EncodedString:image options:0];
                        if (bytes.length && bytes.length <= MaxPhotoBytes) [photos addObject:bytes];
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation != generation) return;
                self.task = nil;
                [self applyPayload:payload photos:photos];
            });
        }];
    [self.task resume];
}

- (void)applyPayload:(NSDictionary *)payload photos:(NSArray *)photos
{
    if (![payload[@"ok"] isEqual:@YES]) {
        NSString *error = [payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : nil;
        self.status = error ?: @"Drive indisponível. Confira a implantação e a conexão.";
    } else if (![payload[@"unchanged"] isEqual:@YES]) {
        self.photos = photos;
        self.index = 0;
        self.revision = [payload[@"revision"] isKindOfClass:[NSString class]] ? payload[@"revision"] : nil;
        BOOL incomplete = [payload[@"incomplete"] isEqual:@YES];
        self.status = incomplete ? @"Drive conectado · algumas fotos ainda sem prévia" :
            [NSString stringWithFormat:@"Drive conectado · %lu fotos", (unsigned long)photos.count];
    } else {
        self.status = [NSString stringWithFormat:@"Drive conectado · %lu fotos", (unsigned long)self.photos.count];
    }
    if (self.didUpdate) self.didUpdate();
}

- (UIImage *)nextImage
{
    for (NSUInteger attempts = 0; attempts < self.photos.count; attempts++) {
        NSData *data = self.photos[self.index];
        self.index = (self.index + 1) % self.photos.count;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) continue;
        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@1024};
        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (!thumbnail) continue;
        UIImage *image = [UIImage imageWithCGImage:thumbnail];
        CGImageRelease(thumbnail);
        return image;
    }
    return nil;
}
@end
