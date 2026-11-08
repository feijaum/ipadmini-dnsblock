#import "Music.h"
#import "YouTube.h"
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const NSUInteger MaxTrackBytes = 32 * 1024 * 1024;

static BOOL AllowedMusicHost(NSString *host)
{
    return [host isEqualToString:@"www.googleapis.com"] || [host isEqualToString:@"i.ytimg.com"] ||
        CentralYouTubePlayerHost(host) || CentralYouTubeMediaHost(host);
}

static BOOL AllowedMusicURL(NSURL *url)
{
    return [url.scheme isEqualToString:@"https"] && !url.user && !url.password &&
        (!url.port || url.port.integerValue == 443) &&
        AllowedMusicHost(url.host);
}

@interface MusicTransport : NSObject <NSURLSessionTaskDelegate>
@end

@implementation MusicTransport
- (void)URLSession:(__unused NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion
{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] || !space.serverTrust ||
        !AllowedMusicHost(space.host)) {
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    NSMutableArray *roots = [NSMutableArray array];
    for (NSString *name in @[@"ISRG-Root-X1", @"ISRG-Root-X2", @"GTS-Root-R1", @"GTS-Root-R3", @"GTS-Root-R4"]) {
        NSURL *resource = [[NSBundle mainBundle] URLForResource:name withExtension:@"der"];
        NSData *data = resource ? [NSData dataWithContentsOfURL:resource] : nil;
        if (!data) continue;
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
        if (certificate) [roots addObject:CFBridgingRelease(certificate)];
    }
    SecTrustRef trust = space.serverTrust;
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)space.host);
    OSStatus policyStatus = SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    SecTrustResultType result = kSecTrustResultInvalid;
    BOOL valid = policyStatus == errSecSuccess
        && SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)roots) == errSecSuccess
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
    NSString *origin = response.URL.host;
    BOOL allowed = AllowedMusicURL(request.URL) &&
        (CentralYouTubeMediaHost(origin) ? CentralYouTubeMediaHost(request.URL.host) :
        ![origin isEqualToString:@"www.googleapis.com"] && !CentralYouTubePlayerHost(origin) &&
        !CentralYouTubeMediaHost(request.URL.host) && !CentralYouTubePlayerHost(request.URL.host));
    completion(allowed ? request : nil);
}

@end

static NSURL *YouTubeTrackDirectory(void)
{
    NSURL *cache = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
        inDomains:NSUserDomainMask] firstObject];
    return [cache URLByAppendingPathComponent:@"com.feijaum.ipadminidnsblock.youtube-audio" isDirectory:YES];
}

@interface YouTubeAudioTransport : MusicTransport <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURL *destination;
@property(nonatomic, strong) NSOutputStream *stream;
@property(nonatomic, strong) NSHTTPURLResponse *response;
@property(nonatomic, strong) NSError *writeError;
@property(nonatomic) NSUInteger bytesWritten;
@property(nonatomic) int64_t expectedBytes;
@property(nonatomic) NSUInteger progressStep;
@property(nonatomic, copy) void (^progress)(NSUInteger percent);
@property(nonatomic, copy) void (^finished)(NSURL *, NSHTTPURLResponse *, NSError *);
@end

@implementation YouTubeAudioTransport

- (void)URLSession:(__unused NSURLSession *)session dataTask:(__unused NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion
{
    self.response = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSString *mime = response.MIMEType.lowercaseString;
    BOOL audio = [mime isEqualToString:@"audio/mp4"] || [mime isEqualToString:@"application/octet-stream"];
    BOOL allowed = AllowedMusicURL(response.URL) && CentralYouTubeMediaHost(response.URL.host);
    NSInteger status = self.response.statusCode;
    BOOL accept = allowed && audio && (status == 200 || status == 206);
    if (accept) {
        int64_t length = response.expectedContentLength;
        if (status == 206) {
            long long end = 0, total = 0;
            char extra;
            NSString *range = self.response.allHeaderFields[@"Content-Range"];
            if (!range) {
                for (NSString *key in self.response.allHeaderFields) {
                    if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
                        range = self.response.allHeaderFields[key];
                        break;
                    }
                }
            }
            // This request asks for the complete file, even if the server uses HTTP 206.
            const char *value = range.UTF8String;
            if (!value || sscanf(value, "bytes 0-%lld/%lld%c", &end, &total, &extra) != 2 ||
                total <= 0 || end != total - 1 || (length > 0 && length != total)) {
                self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:nil];
                accept = NO;
            } else {
                length = total;
            }
        }
        if (accept && (length > (int64_t)MaxTrackBytes || self.expectedBytes > (int64_t)MaxTrackBytes)) {
            self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil];
            accept = NO;
        }
        if (accept && length > 0) {
            if (self.expectedBytes > 0 && self.expectedBytes != length) {
                self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:nil];
                accept = NO;
            } else {
                self.expectedBytes = length;
            }
        }
    }
    if (accept) {
        self.stream = [NSOutputStream outputStreamWithURL:self.destination append:NO];
        [self.stream open];
        if (!self.stream || self.stream.streamStatus == NSStreamStatusError) {
            self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotCreateFile userInfo:nil];
            accept = NO;
        }
    }
    completion(accept ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(__unused NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (!self.stream || self.writeError) return;
    if (data.length > MaxTrackBytes - self.bytesWritten) {
        self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil];
        [task cancel];
        return;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        NSInteger written = [self.stream write:bytes maxLength:remaining];
        if (written <= 0) {
            self.writeError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotWriteToFile userInfo:nil];
            [task cancel];
            return;
        }
        remaining -= (NSUInteger)written;
        bytes += written;
        self.bytesWritten += (NSUInteger)written;
    }
    if (self.expectedBytes > 0) {
        NSUInteger step = (NSUInteger)MIN(20, (20LL * self.bytesWritten) / self.expectedBytes);
        if (step > self.progressStep) {
            self.progressStep = step;
            self.progress(step * 5);
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(__unused NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    [self.stream close];
    if (self.writeError) {
        error = self.writeError;
    } else if (self.response && !self.stream && error.code == NSURLErrorCancelled) {
        // An HTTP error or invalid response was rejected before creating a file.
        error = nil;
    }
    NSURL *file = nil;
    if (!error && self.bytesWritten) {
        unsigned char header[12];
        FILE *input = fopen(self.destination.path.fileSystemRepresentation, "rb");
        BOOL mp4 = input && fread(header, 1, sizeof(header), input) == sizeof(header) &&
            memcmp(header + 4, "ftyp", 4) == 0;
        if (input) fclose(input);
        if (mp4 && (self.expectedBytes <= 0 || self.bytesWritten == (NSUInteger)self.expectedBytes)) {
            file = self.destination;
        } else {
            error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:nil];
        }
    }
    if (!file) [[NSFileManager defaultManager] removeItemAtURL:self.destination error:NULL];
    self.finished(file, self.response, error);
    self.finished = nil;
    self.progress = nil;
    [session finishTasksAndInvalidate];
}
@end

@interface HouseMusic ()
@property(nonatomic, readwrite, copy) NSString *summary;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *youtubeLookup;
@property(nonatomic, copy) NSString *youtubeVisitor;
@property(nonatomic, strong) NSDate *youtubeVisitorExpires;
@property(nonatomic, strong) NSMutableArray *youtubeQueue;
@property(nonatomic, strong) NSURLSessionDataTask *playlistLookup;
@property(nonatomic, strong) NSCache *titles;
@property(nonatomic, strong) NSCache *titleAttempts;
@property(nonatomic, strong) NSCache *titleAPIMisses;
@property(nonatomic, strong) NSCache *images;
@property(nonatomic, strong) NSMutableSet *loadingImages;
@property(nonatomic) BOOL loadingTitles;
@property(nonatomic, readwrite) NSUInteger thumbnailRevision;
@property(nonatomic, readwrite, copy) NSString *currentVideo;
@property(nonatomic, strong) NSURLSessionTask *download;
@property(nonatomic, strong) AVPlayer *mediaPlayer;
@property(nonatomic, strong) AVPlayerItem *mediaItem;
@property(nonatomic) BOOL mediaRequested;
@property(nonatomic, copy) void (^mediaFailure)(NSError *);
@property(nonatomic, copy) NSString *youtubeAudioFailure;
@property(nonatomic, strong) NSURL *audioFile;
@property(nonatomic, copy) NSString *trackTitle;
@property(nonatomic) NSUInteger generation;
@end

@implementation HouseMusic

- (instancetype)init
{
    self = [super init];
    if (self) {
        _summary = @"Escolha uma faixa";
        _youtubeQueue = [NSMutableArray array];
        _titles = [[NSCache alloc] init];
        _titles.countLimit = 150;
        _titleAttempts = [[NSCache alloc] init];
        _titleAttempts.countLimit = 100;
        _titleAPIMisses = [[NSCache alloc] init];
        _titleAPIMisses.countLimit = 100;
        _images = [[NSCache alloc] init];
        _images.countLimit = 64;
        _loadingImages = [NSMutableSet set];
        NSURL *directory = YouTubeTrackDirectory();
        if (directory) [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 120;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:[[MusicTransport alloc] init] delegateQueue:nil];
    }
    return self;
}

- (UIViewController *)youtubeControllerWithSelection:(void (^)(NSURL *, NSString *))selection
{
    return CentralYouTubeSearch(self.session, selection);
}

- (BOOL)canToggle { return self.mediaPlayer != nil; }
- (BOOL)canStop { return self.canToggle || self.download || self.youtubeLookup || self.playlistLookup; }
- (BOOL)isPlaying { return self.mediaPlayer && self.mediaRequested; }
- (NSArray *)queuedTracks { return [self.youtubeQueue copy]; }

- (NSTimeInterval)elapsed
{
    NSTimeInterval time = self.mediaPlayer ? CMTimeGetSeconds(self.mediaPlayer.currentTime) : 0;
    return isfinite(time) && time > 0 ? time : 0;
}

- (NSTimeInterval)duration
{
    NSTimeInterval time = self.mediaItem.status == AVPlayerItemStatusReadyToPlay ?
        CMTimeGetSeconds(self.mediaItem.duration) : 0;
    return isfinite(time) && time > 0 ? time : 0;
}

- (void)seekToSecond:(NSTimeInterval)second
{
    NSTimeInterval duration = self.duration;
    if (duration <= 0 || !isfinite(second)) return;
    [self.mediaPlayer seekToTime:CMTimeMakeWithSeconds(MAX(0, MIN(second, duration)), 600)];
}

- (NSString *)titleForVideo:(NSString *)video
{
    return video.length ? [self.titles objectForKey:video] : nil;
}

- (void)loadTitlesForVideos:(NSArray *)videos
{
    if (self.loadingTitles) return;
    NSMutableOrderedSet *missing = [NSMutableOrderedSet orderedSet];
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    for (NSString *video in videos) {
        NSNumber *last = [self.titleAttempts objectForKey:video];
        if (![self titleForVideo:video] && (!last || now - last.doubleValue >= 90))
            [missing addObject:video];
        if (missing.count == 50) break;
    }
    if (!missing.count) return;

    NSMutableArray *batchIDs = [NSMutableArray array];
    for (NSString *video in missing) {
        NSNumber *miss = [self.titleAPIMisses objectForKey:video];
        if (!miss || now - miss.doubleValue >= 300) [batchIDs addObject:video];
    }
    NSURLRequest *request = CentralYouTubeTitlesRequest(batchIDs);
    BOOL batch = request != nil;
    NSArray *ids = batch ? [batchIDs copy] : @[missing.firstObject];
    if (!batch) request = CentralYouTubeEmbedTitleRequest(ids.firstObject);
    if (!request) return;
    for (NSString *video in ids) [self.titleAttempts setObject:@(now) forKey:video];

    self.loadingTitles = YES;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        BOOL success = !error && http.statusCode == 200;
        NSDictionary *titles = success && batch ? CentralYouTubeTitles(data) : @{};
        NSString *title = success && !batch ? CentralYouTubeEmbedTitle(data) : nil;
        if (title.length) titles = @{ids.firstObject:title};
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loadingTitles = NO;
            for (NSString *video in ids) {
                if (titles[video]) {
                    [self.titles setObject:titles[video] forKey:video];
                } else if (batch) {
                    [self.titleAPIMisses setObject:@(now) forKey:video];
                    [self.titleAttempts removeObjectForKey:video];
                }
            }
            if (titles.count && self.didUpdate) self.didUpdate();
        });
    }] resume];
}

- (UIImage *)thumbnailForVideo:(NSString *)video
{
    if (!video.length) return nil;
    id cached = [self.images objectForKey:video];
    if (cached || [self.loadingImages containsObject:video])
        return [cached isKindOfClass:[UIImage class]] ? cached : nil;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", video]];
    if (!url) return nil;
    [self.loadingImages addObject:video];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        UIImage *image = !error && http.statusCode == 200 && data.length && data.length < 256 * 1024 ?
            [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingImages removeObject:video];
            [self.images setObject:image ?: (id)[NSNull null] forKey:video];
            if (image) {
                self.thumbnailRevision++;
                if (self.didUpdate) self.didUpdate();
            }
        });
    }] resume];
    return nil;
}

- (void)clearAudio
{
    if (self.mediaItem) {
        [self.mediaItem removeObserver:self forKeyPath:@"status"];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.mediaItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.mediaItem];
    }
    [self.mediaPlayer pause];
    self.mediaPlayer = nil;
    self.mediaItem = nil;
    self.mediaRequested = NO;
    self.mediaFailure = nil;
    if (self.audioFile) [[NSFileManager defaultManager] removeItemAtURL:self.audioFile error:NULL];
    self.audioFile = nil;
}

- (void)resetPlayback
{
    ++self.generation;
    [self.youtubeLookup cancel];
    self.youtubeLookup = nil;
    self.youtubeAudioFailure = nil;
    [self.download cancel];
    self.download = nil;
    [self clearAudio];
}

- (void)stopPlayback
{
    [self.playlistLookup cancel];
    self.playlistLookup = nil;
    [self.youtubeQueue removeAllObjects];
    [self skipTrack];
}

- (void)skipTrack
{
    [self resetPlayback];
    self.currentVideo = nil;
    self.trackTitle = nil;
    self.summary = @"Escolha uma faixa";
    [self startNextTrack];
}

- (void)startNextTrack
{
    if (!self.canStop && self.youtubeQueue.count) {
        NSDictionary *track = self.youtubeQueue.firstObject;
        [self.youtubeQueue removeObjectAtIndex:0];
        [self playYouTubeItem:track];
    } else if (self.didUpdate) {
        self.didUpdate();
    }
}

- (void)finishTrackWithSummary:(NSString *)summary
{
    self.currentVideo = nil;
    self.trackTitle = nil;
    self.summary = summary;
    [self startNextTrack];
}

static NSString *YouTubeFailure(NSString *stage, NSHTTPURLResponse *response, NSError *error)
{
    NSString *reason;
    NSInteger status = response.statusCode;
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        NSInteger code = error.code;
        if (code <= NSURLErrorSecureConnectionFailed && code >= NSURLErrorClientCertificateRequired)
            reason = [NSString stringWithFormat:@"TLS %ld", (long)code];
        else if (code == NSURLErrorNoPermissionsToReadFile) reason = @"sem acesso ao arquivo (-1102)";
        else if (code == NSURLErrorCannotCreateFile || code == NSURLErrorCannotWriteToFile)
            reason = @"não gravou o arquivo no iPad";
        else if (code == NSURLErrorDataLengthExceedsMaximum) reason = @"áudio acima do limite de 32 MB";
        else if (code == NSURLErrorCannotDecodeContentData) reason = @"áudio incompleto ou fora do formato M4A";
        else if (code == NSURLErrorCancelled) reason = @"conexão cancelada (-999)";
        else if (code == NSURLErrorTimedOut) reason = @"tempo esgotado (-1001)";
        else reason = [NSString stringWithFormat:@"rede %ld", (long)code];
    } else if (error) {
        reason = [NSString stringWithFormat:@"erro %ld", (long)error.code];
    } else if (status == 403 && [stage isEqualToString:@"download"]) {
        reason = @"YouTube recusou o áudio (403)";
    } else if (status && status != 200 && status != 206) {
        reason = [NSString stringWithFormat:@"HTTP %ld", (long)status];
    } else {
        reason = [stage isEqualToString:@"link"] ? @"AAC indisponível" : @"arquivo de áudio inválido";
    }
    return [NSString stringWithFormat:@"YouTube · %@\n%@", stage, reason];
}

- (void)playYouTube:(NSURL *)url title:(NSString *)title
{
    NSString *video = nil;
    NSString *playlist = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"v"]) video = item.value;
        if ([item.name isEqualToString:@"list"]) playlist = item.value;
    }
    NSDictionary *single = video ? @{@"id":video, @"title":[self titleForVideo:video] ?: title} : nil;
    NSURLRequest *request = CentralYouTubePlaylistRequest(playlist);
    if (!request) {
        if (single) [self.youtubeQueue addObject:single];
        else self.summary = @"Para abrir playlists, configure YouTube → Chave";
        [self startNextTrack];
        return;
    }

    [self.playlistLookup cancel];
    if (!self.canToggle && !self.download && !self.youtubeLookup) self.summary = @"Carregando playlist do YouTube…";
    __block __weak NSURLSessionDataTask *lookup = nil;
    self.playlistLookup = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSArray *tracks = !error && status == 200 ? CentralYouTubePlaylistItems(data) : nil;
        if (tracks.count && video) {
            NSUInteger first = [tracks indexOfObjectPassingTest:^BOOL(NSDictionary *track, __unused NSUInteger index, __unused BOOL *stop) {
                return [track[@"id"] isEqual:video];
            }];
            tracks = first == NSNotFound ? nil : [tracks subarrayWithRange:NSMakeRange(first, tracks.count - first)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!lookup || self.playlistLookup != lookup) return;
            self.playlistLookup = nil;
            if (tracks.count) [self.youtubeQueue addObjectsFromArray:tracks];
            else if (single) [self.youtubeQueue addObject:single];
            else if (!self.canStop) self.summary = @"Playlist indisponível · confira o link e a chave";
            [self startNextTrack];
        });
    }];
    lookup = self.playlistLookup;
    [self.playlistLookup resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)playYouTubeItem:(NSDictionary *)track
{
    self.currentVideo = track[@"id"];
    self.trackTitle = [self titleForVideo:self.currentVideo] ?: track[@"title"];
    self.summary = [NSString stringWithFormat:@"Buscando áudio de %@…", self.trackTitle];
    self.youtubeAudioFailure = nil;
    NSString *video = track[@"id"];
    NSUInteger generation = ++self.generation;
    __weak HouseMusic *music = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        HouseMusic *target = music;
        if (!target || target.generation != generation) return;
        BOOL opening = target.mediaItem && target.mediaItem.status == AVPlayerItemStatusUnknown;
        if (!target.youtubeLookup && !target.download && !opening) return;
        NSString *failure = target.youtubeAudioFailure ?: @"YouTube · tempo esgotado";
        [target resetPlayback];
        [target finishTrackWithSummary:failure];
    });
    if ([self.youtubeVisitorExpires timeIntervalSinceNow] > 0) {
        [self lookupYouTubeAudio:video attempt:0];
        return;
    }

    self.youtubeVisitor = nil;
    self.youtubeLookup = [self.session dataTaskWithRequest:CentralYouTubeVisitorRequest()
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *visitor = !error && http.statusCode == 200 ? CentralYouTubeVisitorData(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.youtubeLookup = nil;
            if (visitor.length) {
                self.youtubeVisitor = visitor;
                self.youtubeVisitorExpires = [NSDate dateWithTimeIntervalSinceNow:24 * 60 * 60];
            }
            [self lookupYouTubeAudio:video attempt:0];
        });
    }];
    [self.youtubeLookup resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)lookupYouTubeAudio:(NSString *)video attempt:(NSUInteger)attempt
{
    NSURLRequest *request = CentralYouTubePlayerRequest(video, self.youtubeVisitor, attempt);
    if (!request) {
        [self finishTrackWithSummary:@"Link do YouTube inválido"];
        return;
    }
    NSUInteger generation = self.generation;
    self.youtubeLookup = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = http.statusCode;
        int64_t length = 0;
        NSURL *audio = !error && status == 200 ? CentralYouTubeAudioURL(data, &length) : nil;
        NSString *title = audio ? CentralYouTubeVideoTitle(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.youtubeLookup = nil;
            if (!audio) {
                if (CentralYouTubePlayerRequest(video, self.youtubeVisitor, attempt + 1)) {
                    [self lookupYouTubeAudio:video attempt:attempt + 1];
                    return;
                }
                [self finishTrackWithSummary:self.youtubeAudioFailure ?: YouTubeFailure(@"link", http, error)];
                return;
            }
            if (title.length) {
                [self.titles setObject:title forKey:video];
                self.trackTitle = title;
            }
            self.summary = @"Baixando áudio do YouTube…";
            NSMutableURLRequest *download = [NSMutableURLRequest requestWithURL:audio
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
            [download setValue:@"bytes=0-" forHTTPHeaderField:@"Range"];
            [download setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
            [self downloadYouTubeAudio:download expectedBytes:length video:video attempt:attempt];
        });
    }];
    [self.youtubeLookup resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)downloadYouTubeAudio:(NSURLRequest *)request expectedBytes:(int64_t)length video:(NSString *)video attempt:(NSUInteger)attempt
{
    NSURL *directory = YouTubeTrackDirectory();
    if (!directory || ![[NSFileManager defaultManager] createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:NULL]) {
        [self finishTrackWithSummary:@"YouTube · armazenamento\nNão abriu o cache do iPad"];
        return;
    }
    NSUInteger generation = self.generation;
    // Use a data task so the app owns the temporary file on legacy iOS.
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    configuration.timeoutIntervalForResource = 35;
    YouTubeAudioTransport *transport = [[YouTubeAudioTransport alloc] init];
    NSString *filename = [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"m4a"];
    transport.destination = [directory URLByAppendingPathComponent:filename];
    transport.expectedBytes = length;
    transport.progress = ^(NSUInteger percent) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation || !self.download) return;
            self.summary = [NSString stringWithFormat:@"Baixando áudio do YouTube… %lu%%", (unsigned long)percent];
            if (self.didUpdate) self.didUpdate();
        });
    };
    transport.finished = ^(NSURL *file, NSHTTPURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) {
                if (file) [[NSFileManager defaultManager] removeItemAtURL:file error:NULL];
                return;
            }
            self.download = nil;
            if (!file) {
                NSString *failure = YouTubeFailure(@"download", response, error);
                BOOL storageError = [error.domain isEqualToString:NSURLErrorDomain] &&
                    (error.code == NSURLErrorCannotCreateFile || error.code == NSURLErrorCannotWriteToFile);
                if (!storageError) {
                    [self retryYouTube:video afterAttempt:attempt failure:failure];
                } else {
                    [self finishTrackWithSummary:failure];
                }
                return;
            }
            self.audioFile = file;
            self.summary = @"Abrindo áudio do YouTube…";
            __weak HouseMusic *music = self;
            [self playMediaURL:file generation:generation failure:^(NSError *playerError) {
                NSString *reason = playerError ? [NSString stringWithFormat:@"Não abriu o M4A (%ld)", (long)playerError.code] :
                    @"Tempo esgotado ao abrir o M4A";
                [music retryYouTube:video afterAttempt:attempt
                    failure:[NSString stringWithFormat:@"YouTube · player\n%@", reason]];
            }];
        });
    };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:transport delegateQueue:nil];
    self.download = [session dataTaskWithRequest:request];
    [self.download resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)retryYouTube:(NSString *)video afterAttempt:(NSUInteger)attempt failure:(NSString *)failure
{
    if (![self.youtubeAudioFailure hasPrefix:@"YouTube · player"]) self.youtubeAudioFailure = failure;
    if (CentralYouTubePlayerRequest(video, self.youtubeVisitor, attempt + 1)) {
        self.summary = @"Tentando outra rota de áudio do YouTube…";
        [self lookupYouTubeAudio:video attempt:attempt + 1];
        return;
    }
    [self finishTrackWithSummary:self.youtubeAudioFailure];
}

- (void)playMediaURL:(NSURL *)url generation:(NSUInteger)generation failure:(void (^)(NSError *))failure
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    self.mediaItem = [AVPlayerItem playerItemWithURL:url];
    self.mediaPlayer = [AVPlayer playerWithPlayerItem:self.mediaItem];
    self.mediaRequested = YES;
    self.mediaFailure = failure;
    AVPlayerItem *item = self.mediaItem;
    [item addObserver:self forKeyPath:@"status"
        options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NULL];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaFailed:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.mediaItem];
    if (self.audioFile) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(localMediaFinished:)
            name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    }
    [self.mediaPlayer play];
    if (self.didUpdate) self.didUpdate();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.generation == generation && self.mediaItem == item && self.mediaRequested &&
            item.status == AVPlayerItemStatusUnknown) [self handleMediaFailure:nil];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context
{
    if (![keyPath isEqualToString:@"status"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self.mediaItem) return;
        if (self.mediaItem.status == AVPlayerItemStatusFailed) [self handleMediaFailure:self.mediaItem.error];
        else if (self.mediaItem.status == AVPlayerItemStatusReadyToPlay) {
            self.summary = self.trackTitle;
            if (self.didUpdate) self.didUpdate();
        }
    });
}

- (void)mediaFailed:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self.mediaItem) return;
        NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] ?: self.mediaItem.error;
        [self handleMediaFailure:error];
    });
}

- (void)handleMediaFailure:(NSError *)error
{
    void (^failure)(NSError *) = self.mediaFailure;
    [self clearAudio];
    if (failure) failure(error);
}

- (void)localMediaFinished:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object == self.mediaItem && self.audioFile) [self skipTrack];
    });
}

- (void)togglePlayback
{
    if (!self.mediaPlayer) return;
    self.mediaRequested = !self.mediaRequested;
    if (self.mediaRequested) [self.mediaPlayer play];
    else [self.mediaPlayer pause];
    if (self.didUpdate) self.didUpdate();
}
@end
