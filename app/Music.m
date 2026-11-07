#import "Music.h"
#import "YouTube.h"
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>

static NSString *const MusicHost = @"api.audius.co";
static const NSUInteger MaxTrackBytes = 32 * 1024 * 1024;

static BOOL AllowedMusicHost(NSString *host)
{
    return [host hasSuffix:@".audius.co"] ||
        [host hasSuffix:@".r2.cloudflarestorage.com"] ||
        [host isEqualToString:@"www.googleapis.com"] || [host isEqualToString:@"i.ytimg.com"];
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

static NSArray *BrazilianStations(void)
{
    return @[
        @{@"title":@"SoundPop Rap", @"artist":@"Rap nacional e internacional", @"radio":@"https://azura.ez1fm.com/listen/rap/radio.mp3"},
        @{@"title":@"Hunter FM Pagode", @"artist":@"Pagode · ao vivo", @"radio":@"https://live.hunter.fm/pagode_low"},
        @{@"title":@"Geração Samba e Pagode", @"artist":@"Samba e pagode · ao vivo", @"radio":@"https://stream.geracaoradios.com.br/listen/samba/radio"},
        @{@"title":@"Hunter FM MPB", @"artist":@"MPB · ao vivo", @"radio":@"https://live.hunter.fm/mpb_low"},
        @{@"title":@"Hunter FM Sertanejo", @"artist":@"Sertanejo · ao vivo", @"radio":@"https://live.hunter.fm/sertanejo_low"},
        @{@"title":@"Hunter FM Tropical", @"artist":@"Música tropical · ao vivo", @"radio":@"https://live.hunter.fm/tropical_low"}
    ];
}

@interface MusicTransport : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic) BOOL localOnly;
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
    BOOL fromSearchAPI = [response.URL.host isEqualToString:@"www.googleapis.com"];
    completion(!self.localOnly && !fromSearchAPI && AllowedMusicURL(request.URL) ? request : nil);
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
    self.source = [[UISegmentedControl alloc] initWithItems:@[@"Rádios BR", @"Audius"]];
    self.source.frame = CGRectMake(16, 5, width - 32, 30);
    self.source.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.source.selectedSegmentIndex = 0;
    [self.source addTarget:self action:@selector(sourceChanged) forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.source];
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 36, width, 56)];
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search.placeholder = @"Nome da rádio ou estilo";
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
    self.tableView.backgroundView = self.message;
    [self showStations:@""];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.source.selectedSegmentIndex == 1) [self.search becomeFirstResponder];
}

- (void)close
{
    [self.searchTask cancel];
    self.searchGeneration++;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sourceChanged
{
    [self.searchTask cancel];
    self.searchGeneration++;
    self.search.text = @"";
    if (self.source.selectedSegmentIndex == 0) {
        [self.search resignFirstResponder];
        self.search.placeholder = @"Nome da rádio ou estilo";
        [self showStations:@""];
    } else {
        self.search.placeholder = @"Nome da música ou artista";
        self.tracks = nil;
        self.message.text = @"Digite um nome e toque em Buscar.";
        [self.tableView reloadData];
        [self.search becomeFirstResponder];
    }
}

- (void)showStations:(NSString *)query
{
    NSMutableArray *stations = [NSMutableArray array];
    for (NSDictionary *station in BrazilianStations()) {
        NSString *description = [NSString stringWithFormat:@"%@ %@", station[@"title"], station[@"artist"]];
        if (!query.length || [description rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            [stations addObject:station];
        }
    }
    self.tracks = stations;
    self.message.text = stations.count ? nil : @"Nenhuma rádio encontrada.";
    [self.tableView reloadData];
}

- (void)searchBar:(__unused UISearchBar *)search textDidChange:(NSString *)text
{
    if (self.source.selectedSegmentIndex == 0) [self showStations:text];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)search
{
    NSString *query = [search.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.source.selectedSegmentIndex == 0) {
        [self showStations:query];
        [search resignFirstResponder];
        return;
    }
    if (!query.length || query.length > 150) return;
    [search resignFirstResponder];
    [self.searchTask cancel];
    NSUInteger generation = ++self.searchGeneration;
    self.tracks = nil;
    self.message.text = @"Buscando no Audius…";
    [self.tableView reloadData];
    NSURL *url = MusicURL(@"/v1/tracks/search", query);
    __weak MusicSearch *controller = self;
    self.searchTask = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray *tracks = [NSMutableArray array];
        BOOL success = !error && data.length && data.length <= 4 * 1024 * 1024
            && [response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)response statusCode] == 200;
        id payload = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id rows = [payload isKindOfClass:[NSDictionary class]] ? payload[@"data"] : nil;
        if ([rows isKindOfClass:[NSArray class]]) {
            for (id item in rows) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *identifier = item[@"id"];
                NSString *title = item[@"title"];
                id user = item[@"user"];
                NSString *artist = [user isKindOfClass:[NSDictionary class]] ? user[@"name"] : nil;
                if ([item[@"is_stream_gated"] isEqual:@YES] || [item[@"is_available"] isEqual:@NO]) continue;
                NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"];
                if (![identifier isKindOfClass:[NSString class]] || !identifier.length || identifier.length > 32
                    || [identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound
                    || ![title isKindOfClass:[NSString class]] || !title.length) continue;
                [tracks addObject:@{@"id":identifier, @"title":title,
                    @"artist":[artist isKindOfClass:[NSString class]] ? artist : @"Audius"}];
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
@property(nonatomic, strong) NSURLSession *youtubeSession;
@property(nonatomic, strong) NSURLSessionDataTask *playlistLookup;
@property(nonatomic, copy) NSArray *youtubeQueue;
@property(nonatomic) NSUInteger youtubeIndex;
@property(nonatomic, strong) NSURLSessionDownloadTask *download;
@property(nonatomic, strong) AVAudioPlayer *audio;
@property(nonatomic, strong) AVPlayer *radio;
@property(nonatomic, strong) AVPlayerItem *radioItem;
@property(nonatomic) BOOL radioRequested;
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
        configuration.timeoutIntervalForRequest = 105;
        MusicTransport *local = [[MusicTransport alloc] init];
        local.localOnly = YES;
        _youtubeSession = [NSURLSession sessionWithConfiguration:configuration delegate:local delegateQueue:nil];
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

- (UIViewController *)youtubeControllerWithSelection:(void (^)(NSURL *, NSString *))selection
{
    return CentralYouTubeSearch(self.session, selection);
}

- (BOOL)canToggle { return self.audio != nil || self.radio != nil; }
- (BOOL)canStop { return self.canToggle || self.download != nil || self.playlistLookup != nil; }
- (BOOL)isPlaying { return self.radio ? self.radioRequested : self.audio.isPlaying; }

- (void)clearAudio
{
    if (self.radioItem) {
        [self.radioItem removeObserver:self forKeyPath:@"status"];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.radioItem];
    }
    [self.radio pause];
    self.radio = nil;
    self.radioItem = nil;
    self.radioRequested = NO;
    [self.audio stop];
    self.audio = nil;
    if (self.audioFile) [[NSFileManager defaultManager] removeItemAtURL:self.audioFile error:NULL];
    self.audioFile = nil;
}

- (void)resetPlayback
{
    ++self.generation;
    [self.playlistLookup cancel];
    self.playlistLookup = nil;
    self.youtubeQueue = nil;
    self.youtubeIndex = 0;
    [self.download cancel];
    self.download = nil;
    [self clearAudio];
}

- (void)stopPlayback
{
    [self resetPlayback];
    self.trackTitle = nil;
    self.summary = @"Escolha uma faixa";
    if (self.didUpdate) self.didUpdate();
}

- (void)playTrack:(NSDictionary *)track
{
    [self resetPlayback];
    NSUInteger generation = self.generation;
    self.trackTitle = [NSString stringWithFormat:@"%@ · %@", track[@"title"], track[@"artist"]];
    self.summary = [NSString stringWithFormat:@"Carregando %@…", track[@"title"]];
    if (track[@"radio"]) {
        [self playRadio:[NSURL URLWithString:track[@"radio"]] generation:generation];
        return;
    }
    NSURL *url = MusicURL([NSString stringWithFormat:@"/v1/tracks/%@/stream", track[@"id"]], nil);
    [self downloadAudio:[NSURLRequest requestWithURL:url] fromYouTube:NO];
}

- (NSString *)youtubeFailure:(NSURLResponse *)response error:(NSError *)error
{
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status == 401) return @"Token do servidor incorreto · abra YouTube → Servidor";
    if (status == 503) return @"Conversor ocupado · tente novamente em instantes";
    if (status == 504 || error.code == NSURLErrorTimedOut) return @"Conversão demorou demais · tente outra faixa";
    if (error) return @"Servidor de áudio inacessível · confira o IP e o Wi-Fi";
    return @"Áudio indisponível no conversor · tente outra faixa";
}

- (void)playYouTube:(NSURL *)url title:(NSString *)title
{
    [self resetPlayback];
    NSString *video = nil;
    NSString *playlist = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"v"]) video = item.value;
        if ([item.name isEqualToString:@"list"]) playlist = item.value;
    }
    if (!playlist) {
        [self playYouTubeItem:@{@"id":video ?: @"", @"title":title}];
        return;
    }

    NSURLRequest *request = CentralYouTubeAudioRequest(@"playlist", playlist);
    if (!request) {
        self.summary = @"Configure o conversor em YouTube → Servidor";
        if (self.didUpdate) self.didUpdate();
        return;
    }
    self.summary = @"Carregando playlist do YouTube…";
    NSUInteger generation = self.generation;
    self.playlistLookup = [self.youtubeSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        id items = !error && status == 200 && data.length && data.length < 65536
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSMutableArray *tracks = [NSMutableArray array];
        if ([items isKindOfClass:[NSArray class]]) {
            for (id item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                if (![item[@"id"] isKindOfClass:[NSString class]] || ![item[@"title"] isKindOfClass:[NSString class]]) continue;
                [tracks addObject:item];
                if (tracks.count == 50) break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation != generation) return;
            self.playlistLookup = nil;
            if (tracks.count) {
                NSUInteger first = 0;
                if (video) {
                    first = [tracks indexOfObjectPassingTest:^BOOL(NSDictionary *track, __unused NSUInteger index, __unused BOOL *stop) {
                        return [track[@"id"] isEqual:video];
                    }];
                }
                if (first == NSNotFound) {
                    [self playYouTubeItem:@{@"id":video, @"title":title}];
                } else {
                    self.youtubeQueue = tracks;
                    self.youtubeIndex = first;
                    [self playYouTubeItem:tracks[first]];
                }
            } else if (video && status == 502) {
                [self playYouTubeItem:@{@"id":video, @"title":title}];
            } else {
                self.summary = [self youtubeFailure:response error:error];
                if (self.didUpdate) self.didUpdate();
            }
        });
    }];
    [self.playlistLookup resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)playYouTubeItem:(NSDictionary *)track
{
    NSURLRequest *request = CentralYouTubeAudioRequest(@"audio", track[@"id"]);
    if (!request) {
        self.summary = @"Configure o conversor em YouTube → Servidor";
        if (self.didUpdate) self.didUpdate();
        return;
    }
    self.trackTitle = [NSString stringWithFormat:@"%@ · YouTube", track[@"title"]];
    self.summary = [NSString stringWithFormat:@"Preparando áudio de %@…", track[@"title"]];
    [self downloadAudio:request fromYouTube:YES];
}

- (void)downloadAudio:(NSURLRequest *)request fromYouTube:(BOOL)youtube
{
    NSUInteger generation = self.generation;
    NSURLSession *session = youtube ? self.youtubeSession : self.session;
    self.download = [session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSURL *file = nil;
        NSUInteger size = 0;
        if (location) {
            NSNumber *sizeValue = nil;
            [location getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:NULL];
            size = sizeValue.unsignedIntegerValue;
        }
        NSString *mime = response.MIMEType.lowercaseString;
        BOOL allowed = youtube ? [response.URL isEqual:request.URL] : AllowedMusicURL(response.URL);
        if (!error && allowed && [response isKindOfClass:[NSHTTPURLResponse class]]
            && [(NSHTTPURLResponse *)response statusCode] == 200 && size > 0 && size <= MaxTrackBytes
            && ([mime hasPrefix:@"audio/"] || [mime isEqualToString:@"application/octet-stream"])) {
            NSString *name = [NSString stringWithFormat:@"central-music-%@.mp3", [[NSUUID UUID] UUIDString]];
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
                self.summary = youtube ? [self youtubeFailure:response error:error] :
                    @"Não foi possível tocar · busque outra música";
            }
            if (self.didUpdate) self.didUpdate();
        });
    }];
    [self.download resume];
    if (self.didUpdate) self.didUpdate();
}

- (void)playRadio:(NSURL *)url generation:(NSUInteger)generation
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    self.radioItem = [AVPlayerItem playerItemWithURL:url];
    self.radio = [AVPlayer playerWithPlayerItem:self.radioItem];
    self.radioRequested = YES;
    [self.radioItem addObserver:self forKeyPath:@"status"
        options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NULL];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(radioFailed:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.radioItem];
    [self.radio play];
    if (self.didUpdate) self.didUpdate();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.generation == generation && self.radioRequested &&
            self.radioItem.status == AVPlayerItemStatusUnknown) [self radioFailed:nil];
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
        if (object != self.radioItem) return;
        if (self.radioItem.status == AVPlayerItemStatusFailed) [self radioFailed:nil];
        else if (self.radioItem.status == AVPlayerItemStatusReadyToPlay) {
            self.summary = self.trackTitle;
            if (self.didUpdate) self.didUpdate();
        }
    });
}

- (void)radioFailed:(NSNotification *)notification
{
    if (!self.radioItem || (notification && notification.object != self.radioItem)) return;
    [self clearAudio];
    self.summary = @"Rádio indisponível · tente outra estação";
    if (self.didUpdate) self.didUpdate();
}

- (void)togglePlayback
{
    if (self.radio) {
        self.radioRequested = !self.radioRequested;
        if (self.radioRequested) [self.radio play];
        else [self.radio pause];
    } else if (self.audio.isPlaying) [self.audio pause];
    else if (self.audio) [self.audio play];
    if (self.didUpdate) self.didUpdate();
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)success
{
    if (player != self.audio) return;
    [self clearAudio];
    if (success && self.youtubeQueue && self.youtubeIndex + 1 < self.youtubeQueue.count) {
        self.youtubeIndex++;
        [self playYouTubeItem:self.youtubeQueue[self.youtubeIndex]];
        return;
    }
    self.youtubeQueue = nil;
    self.summary = success ? @"Escolha uma faixa" : @"Não foi possível tocar · busque outra música";
    if (self.didUpdate) self.didUpdate();
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(__unused NSError *)error
{
    [self audioPlayerDidFinishPlaying:player successfully:NO];
}
@end
