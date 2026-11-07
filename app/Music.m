#import "Music.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <StoreKit/StoreKit.h>
#import <Security/Security.h>

static NSString *const MusicHost = @"api.audius.co";
static NSString *const AppleSearchHost = @"itunes.apple.com";
static const NSUInteger MaxTrackBytes = 32 * 1024 * 1024;

static BOOL AllowedMusicHost(NSString *host)
{
    return [host isEqualToString:AppleSearchHost] || [host hasSuffix:@".audius.co"] ||
        [host hasSuffix:@".r2.cloudflarestorage.com"];
}

static BOOL AllowedMusicURL(NSURL *url)
{
    return [url.scheme isEqualToString:@"https"] && !url.user && !url.password &&
        (!url.port || url.port.integerValue == 443) &&
        AllowedMusicHost(url.host);
}

static NSURL *MusicURL(NSString *path, NSString *query)
{
    NSURLComponents *url = [[NSURLComponents alloc] init];
    url.scheme = @"https";
    url.host = MusicHost;
    url.path = path;
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"app_name" value:@"CentralDaCasa"]];
    if (query) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"query" value:query]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"20"]];
    }
    url.queryItems = items;
    return url.URL;
}

static NSURL *AppleSearchURL(NSString *query)
{
    NSURLComponents *url = [[NSURLComponents alloc] init];
    url.scheme = @"https";
    url.host = AppleSearchHost;
    url.path = @"/search";
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:query],
        [NSURLQueryItem queryItemWithName:@"country" value:@"BR"],
        [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"20"]
    ];
    // Encode literal plus signs rather than treating them as spaces in the catalog query.
    url.percentEncodedQuery = [url.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return url.URL;
}

static BOOL SupportsAppleMusic(void)
{
    NSOperatingSystemVersion version = {9, 3, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version] &&
        NSClassFromString(@"SKCloudServiceController") != Nil &&
        [MPMusicPlayerController instancesRespondToSelector:@selector(setQueueWithStoreIDs:)];
}

@interface MusicTransport : NSObject <NSURLSessionDownloadDelegate>
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
    willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion
{
    completion(AllowedMusicURL(request.URL) ? request : nil);
}

- (void)URLSession:(__unused NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(__unused int64_t)bytes totalBytesWritten:(int64_t)total
totalBytesExpectedToWrite:(int64_t)expected
{
    if (total > (int64_t)MaxTrackBytes || expected > (int64_t)MaxTrackBytes) [task cancel];
}

- (void)URLSession:(__unused NSURLSession *)session downloadTask:(__unused NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(__unused NSURL *)location
{
    // Playback downloads use their own completion handler.
}
@end

@interface MusicSearch : UITableViewController <UISearchBarDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *searchTask;
@property(nonatomic, copy) NSArray *tracks;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) UISegmentedControl *source;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, copy) void (^didSelect)(NSDictionary *);
@property(nonatomic) NSUInteger searchGeneration;
@end

@implementation MusicSearch
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Pesquisar músicas";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    CGFloat width = self.tableView.bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 92)];
    self.source = [[UISegmentedControl alloc] initWithItems:@[@"Apple Music BR", @"Audius"]];
    self.source.frame = CGRectMake(16, 5, width - 32, 30);
    self.source.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.source setEnabled:SupportsAppleMusic() forSegmentAtIndex:0];
    self.source.selectedSegmentIndex = SupportsAppleMusic() ? 0 : 1;
    [self.source addTarget:self action:@selector(sourceChanged) forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.source];
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 36, width, 56)];
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search.placeholder = @"Nome da música ou artista";
    self.search.delegate = self;
    self.search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.search.autocorrectionType = UITextAutocorrectionTypeNo;
    [header addSubview:self.search];
    self.tableView.tableHeaderView = header;
    self.tableView.rowHeight = 60;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.message = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    self.message.textAlignment = NSTextAlignmentCenter;
    self.message.numberOfLines = 0;
    self.message.textColor = [UIColor darkGrayColor];
    self.message.text = @"Digite um nome e toque em Buscar.";
    self.tableView.backgroundView = self.message;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.search becomeFirstResponder];
}

- (void)close
{
    [self.searchTask cancel];
    self.searchGeneration++;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sourceChanged
{
    if (self.search.text.length) [self searchBarSearchButtonClicked:self.search];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)search
{
    NSString *query = [search.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length || query.length > 150) return;
    [search resignFirstResponder];
    [self.searchTask cancel];
    NSUInteger generation = ++self.searchGeneration;
    self.tracks = nil;
    BOOL apple = self.source.selectedSegmentIndex == 0;
    self.message.text = apple ? @"Buscando no catálogo brasileiro…" : @"Buscando no Audius…";
    [self.tableView reloadData];
    NSURL *url = apple ? AppleSearchURL(query) : MusicURL(@"/v1/tracks/search", query);
    __weak MusicSearch *controller = self;
    self.searchTask = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray *tracks = [NSMutableArray array];
        BOOL success = !error && data.length && data.length <= 4 * 1024 * 1024
            && [response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)response statusCode] == 200;
        id payload = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id rows = [payload isKindOfClass:[NSDictionary class]] ? payload[apple ? @"results" : @"data"] : nil;
        if ([rows isKindOfClass:[NSArray class]]) {
            for (id item in rows) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *identifier = item[@"id"];
                NSString *title = item[@"title"];
                id user = item[@"user"];
                NSString *artist = [user isKindOfClass:[NSDictionary class]] ? user[@"name"] : nil;
                if (apple) {
                    NSNumber *trackID = item[@"trackId"];
                    if (![trackID isKindOfClass:[NSNumber class]] || trackID.longLongValue <= 0) continue;
                    identifier = trackID.stringValue;
                    title = item[@"trackName"];
                    artist = item[@"artistName"];
                } else if ([item[@"is_stream_gated"] isEqual:@YES] || [item[@"is_available"] isEqual:@NO]) {
                    continue;
                }
                NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"];
                if (![identifier isKindOfClass:[NSString class]] || !identifier.length || identifier.length > 32
                    || [identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound
                    || ![title isKindOfClass:[NSString class]] || !title.length) continue;
                [tracks addObject:@{@"id":identifier, @"title":title, @"apple":@(apple),
                    @"artist":[artist isKindOfClass:[NSString class]] ? artist : (apple ? @"Apple Music" : @"Audius")}];
                if (tracks.count == 20) break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MusicSearch *target = controller;
            if (!target || target.searchGeneration != generation) return;
            target.searchTask = nil;
            target.tracks = tracks;
            target.message.text = tracks.count ? nil : ([rows isKindOfClass:[NSArray class]] ?
                @"Nenhuma faixa disponível para essa busca." : @"Não foi possível buscar. Confira a conexão e tente de novo.");
            [target.tableView reloadData];
        });
    }];
    [self.searchTask resume];
}

- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(__unused NSInteger)section
{
    return self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"MusicTrack"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MusicTrack"];
    NSDictionary *track = self.tracks[path.row];
    cell.textLabel.text = track[@"title"];
    cell.detailTextLabel.text = track[@"artist"];
    return cell;
}

- (void)tableView:(__unused UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path
{
    if (self.didSelect) self.didSelect(self.tracks[path.row]);
    [self close];
}
@end

@interface HouseMusic () <AVAudioPlayerDelegate>
@property(nonatomic, readwrite, copy) NSString *summary;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *download;
@property(nonatomic, strong) AVAudioPlayer *audio;
@property(nonatomic, strong) MPMusicPlayerController *applePlayer;
@property(nonatomic, strong) id cloudService;
@property(nonatomic) BOOL usingApple;
@property(nonatomic) BOOL waitingForApple;
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
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 120;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:[[MusicTransport alloc] init] delegateQueue:nil];
    }
    return self;
}

- (UIViewController *)searchController
{
    MusicSearch *search = [[MusicSearch alloc] initWithStyle:UITableViewStylePlain];
    search.session = self.session;
    __weak HouseMusic *music = self;
    search.didSelect = ^(NSDictionary *track) { [music playTrack:track]; };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:search];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigation;
}

- (BOOL)canToggle { return self.audio != nil || (self.usingApple && !self.waitingForApple); }
- (BOOL)isPlaying
{
    return self.usingApple ? self.applePlayer.playbackState == MPMusicPlaybackStatePlaying : self.audio.isPlaying;
}

- (void)clearAudio
{
    self.cloudService = nil;
    if (self.usingApple) {
        self.usingApple = NO;
        self.waitingForApple = NO;
        [self.applePlayer stop];
    }
    [self.audio stop];
    self.audio = nil;
    if (self.audioFile) [[NSFileManager defaultManager] removeItemAtURL:self.audioFile error:NULL];
    self.audioFile = nil;
}

- (void)playTrack:(NSDictionary *)track
{
    [self.download cancel];
    self.download = nil;
    [self clearAudio];
    NSUInteger generation = ++self.generation;
    self.trackTitle = [NSString stringWithFormat:@"%@ · %@", track[@"title"], track[@"artist"]];
    self.summary = [NSString stringWithFormat:@"Carregando %@…", track[@"title"]];
    if (self.didUpdate) self.didUpdate();

    if ([track[@"apple"] boolValue]) {
        if (SupportsAppleMusic()) [self playAppleTrack:track[@"id"] generation:generation];
        else [self appleUnavailable:@"Apple Music requer iOS 9.3"];
        return;
    }
    NSURL *url = MusicURL([NSString stringWithFormat:@"/v1/tracks/%@/stream", track[@"id"]], nil);
    self.download = [self.session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSURL *file = nil;
        NSUInteger size = 0;
        if (location) {
            NSNumber *sizeValue = nil;
            [location getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:NULL];
            size = sizeValue.unsignedIntegerValue;
        }
        NSString *mime = response.MIMEType.lowercaseString;
        if (!error && AllowedMusicURL(response.URL) && [response isKindOfClass:[NSHTTPURLResponse class]]
            && [(NSHTTPURLResponse *)response statusCode] == 200 && size > 0 && size <= MaxTrackBytes
            && ([mime hasPrefix:@"audio/"] || [mime isEqualToString:@"application/octet-stream"])) {
            NSString *name = [NSString stringWithFormat:@"central-audius-%@.mp3", [[NSUUID UUID] UUIDString]];
            NSURL *destination = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
            if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:NULL]) file = destination;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) {
                if (file) [[NSFileManager defaultManager] removeItemAtURL:file error:NULL];
                return;
            }
            self.download = nil;
            self.audioFile = file;
            self.audio = file ? [[AVAudioPlayer alloc] initWithContentsOfURL:file error:NULL] : nil;
            self.audio.delegate = self;
            if (self.audio) {
                [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
                [[AVAudioSession sharedInstance] setActive:YES error:NULL];
            }
            if (self.audio && [self.audio play]) self.summary = self.trackTitle;
            else {
                [self clearAudio];
                self.summary = @"Não foi possível tocar · busque outra música";
            }
            if (self.didUpdate) self.didUpdate();
        });
    }];
    [self.download resume];
}

- (void)appleUnavailable:(NSString *)message
{
    [self clearAudio];
    self.summary = message;
    if (self.didUpdate) self.didUpdate();
}

// The cross toolchain cannot link Clang's availability helper on ARMv7.
// The only caller checks the OS, class and selector before using these APIs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
- (void)playAppleTrack:(NSString *)identifier generation:(NSUInteger)generation
{
    [SKCloudServiceController requestAuthorization:^(SKCloudServiceAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            if (status != SKCloudServiceAuthorizationStatusAuthorized) {
                [self appleUnavailable:@"Permita o acesso ao Apple Music nos Ajustes do iPad"];
                return;
            }
            SKCloudServiceController *service = [[SKCloudServiceController alloc] init];
            self.cloudService = service;
            [service requestCapabilitiesWithCompletionHandler:^(SKCloudServiceCapability capabilities, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.generation != generation) return;
                    self.cloudService = nil;
                    if (error || !(capabilities & SKCloudServiceCapabilityMusicCatalogPlayback)) {
                        [self appleUnavailable:@"Entre no app Música com uma assinatura ativa"];
                        return;
                    }
                    if (!self.applePlayer) {
                        self.applePlayer = [MPMusicPlayerController applicationMusicPlayer];
                        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appleStateChanged:)
                            name:MPMusicPlayerControllerPlaybackStateDidChangeNotification object:self.applePlayer];
                        [self.applePlayer beginGeneratingPlaybackNotifications];
                    }
                    self.usingApple = YES;
                    self.waitingForApple = YES;
                    [self.applePlayer setQueueWithStoreIDs:@[identifier]];
                    [self.applePlayer play];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        if (self.generation != generation || !self.waitingForApple) return;
                        if (self.isPlaying) [self appleStateChanged:nil];
                        else [self appleUnavailable:@"Apple Music indisponível neste iPad"];
                    });
                });
            }];
        });
    }];
}

#pragma clang diagnostic pop

- (void)appleStateChanged:(__unused NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.usingApple) return;
        if (self.isPlaying) {
            self.waitingForApple = NO;
            self.summary = self.trackTitle;
        } else if (!self.waitingForApple && self.applePlayer.playbackState == MPMusicPlaybackStateStopped) {
            self.usingApple = NO;
            self.summary = @"Escolha uma faixa";
        }
        if (self.didUpdate) self.didUpdate();
    });
}

- (void)togglePlayback
{
    if (self.usingApple) {
        if (self.isPlaying) [self.applePlayer pause];
        else [self.applePlayer play];
    } else if (self.audio.isPlaying) [self.audio pause];
    else if (self.audio) [self.audio play];
    if (self.didUpdate) self.didUpdate();
}

- (void)pause
{
    if (self.download) {
        self.generation++;
        [self.download cancel];
        self.download = nil;
        self.summary = @"Escolha uma faixa";
    }
    if (self.usingApple && self.isPlaying) [self.applePlayer pause];
    if (self.audio.isPlaying) [self.audio pause];
    if (self.didUpdate) self.didUpdate();
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)success
{
    if (player != self.audio) return;
    [self clearAudio];
    self.summary = success ? @"Escolha uma faixa" : @"Não foi possível tocar · busque outra música";
    if (self.didUpdate) self.didUpdate();
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(__unused NSError *)error
{
    [self audioPlayerDidFinishPlaying:player successfully:NO];
}
@end
