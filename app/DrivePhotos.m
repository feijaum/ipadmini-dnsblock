#import "DrivePhotos.h"
#import <ImageIO/ImageIO.h>
#import <Security/Security.h>

static NSString *const DriveHost = @"script.google.com";
static NSString *const ResultHost = @"script.googleusercontent.com";
static NSString *const DriveEndpoint = @"drivePhotosEndpoint";
static NSString *const DriveAccessKey = @"drivePhotosAccessKey";
enum { MaxPhotoBytes = 256 * 1024, MaxResponseBytes = 8 * 1024 * 1024 };

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
@property(nonatomic, strong) NSURLSessionDataTask *listTask;
@property(nonatomic, strong) NSURLSessionDataTask *imageTask;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSArray *photoIDs;
@property(nonatomic, strong) NSMutableArray *queue;
@property(nonatomic, strong) NSCache *cache;
@property(nonatomic, strong) UIImage *readyImage;
@property(nonatomic, copy) NSString *pendingID;
@property(nonatomic, copy) NSString *lastShownID;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL active;
@end

@implementation DrivePhotos
- (instancetype)init
{
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.totalCostLimit = 12 * 1024 * 1024;
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

- (void)cancelRequests
{
    self.generation++;
    [self.listTask cancel];
    [self.imageTask cancel];
    self.listTask = nil;
    self.imageTask = nil;
}

- (void)reset
{
    [self cancelRequests];
    self.photoIDs = nil;
    self.queue = nil;
    self.readyImage = nil;
    self.pendingID = nil;
    self.lastShownID = nil;
    self.revision = nil;
    [self.cache removeAllObjects];
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
    [self prepareNext];
}

- (void)pause
{
    self.active = NO;
    [self.timer invalidate];
    self.timer = nil;
    [self cancelRequests];
}

- (void)poll:(__unused NSTimer *)timer { [self refresh]; }

- (NSURLSessionDataTask *)request:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.endpoint]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSMutableDictionary *body = [arguments mutableCopy];
    body[@"key"] = self.key;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    NSUInteger generation = self.generation;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *payload = nil;
            if (!error && data.length && data.length <= MaxResponseBytes &&
                [response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)response statusCode] == 200) {
                id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([decoded isKindOfClass:[NSDictionary class]]) payload = decoded;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation == generation) completion(payload);
            });
        }];
    [task resume];
    return task;
}

- (void)refresh
{
    if (!self.active || !self.connected || self.listTask) return;
    self.listTask = [self request:@{@"action":@"list", @"revision":self.revision ?: @""}
        completion:^(NSDictionary *payload) {
            self.listTask = nil;
            NSArray *ids = payload[@"ids"];
            if ([payload[@"ok"] isEqual:@YES] && [payload[@"unchanged"] isEqual:@YES]) return;
            if (![payload[@"ok"] isEqual:@YES] || ![ids isKindOfClass:[NSArray class]]) {
                NSString *error = [payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : nil;
                self.status = error ?: @"Drive indisponível. Confira a implantação.";
                if (self.didUpdate) self.didUpdate();
                return;
            }

            NSMutableOrderedSet *validIDs = [NSMutableOrderedSet orderedSet];
            for (id photoID in ids) {
                if ([photoID isKindOfClass:[NSString class]] && [photoID length] && [photoID length] <= 128) {
                    [validIDs addObject:photoID];
                }
            }
            [self reset];
            self.photoIDs = validIDs.array;
            self.revision = [payload[@"revision"] isKindOfClass:[NSString class]] ? payload[@"revision"] : nil;
            self.status = [NSString stringWithFormat:@"Drive conectado · %lu fotos", (unsigned long)self.photoIDs.count];
            if (self.didUpdate) self.didUpdate();
            [self prepareNext];
        }];
}

- (void)shuffle
{
    self.queue = [self.photoIDs mutableCopy];
    for (NSUInteger count = self.queue.count; count > 1; count--) {
        [self.queue exchangeObjectAtIndex:count - 1 withObjectAtIndex:arc4random_uniform((uint32_t)count)];
    }
    if (self.queue.count > 1 && [self.queue.lastObject isEqual:self.lastShownID]) {
        [self.queue exchangeObjectAtIndex:0 withObjectAtIndex:self.queue.count - 1];
    }
}

- (void)prepareNext
{
    if (!self.active || self.imageTask || self.readyImage || !self.photoIDs.count) return;
    if (!self.pendingID) {
        if (!self.queue.count) [self shuffle];
        self.pendingID = self.queue.lastObject;
        [self.queue removeLastObject];
    }
    NSString *photoID = self.pendingID;
    self.readyImage = [self.cache objectForKey:photoID];
    if (self.readyImage) return;

    self.imageTask = [self request:@{@"action":@"photo", @"id":photoID} completion:^(NSDictionary *payload) {
        self.imageTask = nil;
        NSString *encoded = payload[@"image"];
        if ([encoded isKindOfClass:[NSString class]] && encoded.length <= 4 * ((MaxPhotoBytes + 2) / 3)) {
            NSData *bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
            self.readyImage = [self decodePhoto:bytes];
        }
        if (self.readyImage) {
            CGSize size = self.readyImage.size;
            [self.cache setObject:self.readyImage forKey:photoID cost:(NSUInteger)(4 * size.width * size.height)];
        } else {
            self.pendingID = nil;
        }
        if (self.didUpdate) self.didUpdate();
    }];
}

- (UIImage *)decodePhoto:(NSData *)data
{
    if (!data.length || data.length > MaxPhotoBytes) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@1024};
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnail) return nil;
    UIImage *image = [UIImage imageWithCGImage:thumbnail];
    CGImageRelease(thumbnail);
    return image;
}

- (BOOL)hasAlbum { return self.photoIDs.count > 0; }

- (UIImage *)nextImage
{
    UIImage *image = self.readyImage;
    if (image) {
        self.lastShownID = self.pendingID;
        self.readyImage = nil;
        self.pendingID = nil;
    }
    [self prepareNext];
    return image;
}
@end
