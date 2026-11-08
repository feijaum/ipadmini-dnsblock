#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#include <stdbool.h>

static NSString *const BlocklistHost = @"cdn.jsdelivr.net";
static NSString *const BlocklistURL =
    @"https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt";

@interface BlocklistDownload : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSUInteger limit;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSData *result;
@property(nonatomic, strong) dispatch_semaphore_t finished;
@end

@implementation BlocklistDownload

- (void)URLSession:(__unused NSURLSession *)session
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    SecTrustRef trust = space.serverTrust;
    if (!trust || ![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] ||
        ![space.host isEqualToString:BlocklistHost]) {
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    // iOS 8/9 may not have the roots used by current CDN certificates.
    NSMutableArray *roots = [NSMutableArray array];
    NSString *folder = @"/Applications/DNSBlockCentral.app";
    for (NSString *name in @[@"ISRG-Root-X1.der", @"ISRG-Root-X2.der", @"GTS-Root-R1.der",
                              @"GTS-Root-R3.der", @"GTS-Root-R4.der"]) {
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
        if (data) {
            SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
            if (certificate) [roots addObject:CFBridgingRelease(certificate)];
        }
    }
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)BlocklistHost);
    OSStatus policyStatus = SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    SecTrustResultType result = kSecTrustResultInvalid;
    BOOL valid = policyStatus == errSecSuccess &&
        (!roots.count || (SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)roots) == errSecSuccess &&
                          SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess)) &&
        SecTrustEvaluate(trust, &result) == errSecSuccess &&
        (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
    completion(valid ? NSURLSessionAuthChallengeUseCredential : NSURLSessionAuthChallengeCancelAuthenticationChallenge,
               valid ? [NSURLCredential credentialForTrust:trust] : nil);
}

- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task
    willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(__unused NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion
{
    completion(nil);
}

- (void)URLSession:(__unused NSURLSession *)session dataTask:(__unused NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion
{
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    BOOL accept = [http isKindOfClass:[NSHTTPURLResponse class]] && http.statusCode == 200 &&
        response.expectedContentLength <= (int64_t)self.limit;
    if (accept) self.body = [NSMutableData data];
    completion(accept ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(__unused NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (data.length > self.limit - self.body.length) {
        self.body = nil;
        [task cancel];
        return;
    }
    [self.body appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(__unused NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error
{
    if (!error) self.result = self.body;
    [session finishTasksAndInvalidate];
    dispatch_semaphore_signal(self.finished);
}

@end

bool download_blocklist(const char *path, size_t max_bytes)
{
    @autoreleasepool {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 60;
        BlocklistDownload *download = [[BlocklistDownload alloc] init];
        download.limit = max_bytes;
        download.finished = dispatch_semaphore_create(0);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:download delegateQueue:nil];
        [[session dataTaskWithURL:[NSURL URLWithString:BlocklistURL]] resume];
        if (dispatch_semaphore_wait(download.finished, dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC))) {
            [session invalidateAndCancel];
            return false;
        }
        return download.result.length &&
            [download.result writeToFile:[NSString stringWithUTF8String:path] options:0 error:NULL];
    }
}
