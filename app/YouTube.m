#import "YouTube.h"

static NSString *const KeyPreference = @"youtubeDataAPIKey";

static BOOL ValidIdentifier(NSString *value, NSUInteger min, NSUInteger max)
{
    if (![value isKindOfClass:[NSString class]] || value.length < min || value.length > max) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSURL *WatchURL(NSString *video, NSString *playlist)
{
    BOOL hasVideo = ValidIdentifier(video, 11, 11);
    BOOL hasPlaylist = ValidIdentifier(playlist, 2, 150);
    if (!hasVideo && !hasPlaylist) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://www.youtube.com"];
    url.path = hasVideo ? @"/watch" : @"/playlist";
    NSMutableArray *parameters = [NSMutableArray array];
    if (hasVideo) [parameters addObject:[NSURLQueryItem queryItemWithName:@"v" value:video]];
    if (hasPlaylist) [parameters addObject:[NSURLQueryItem queryItemWithName:@"list" value:playlist]];
    url.queryItems = parameters;
    return url.URL;
}

NSURL *CentralYouTubeWatchURL(NSURL *link)
{
    if (![link.scheme.lowercaseString isEqualToString:@"https"] || link.user || link.password ||
        (link.port && link.port.integerValue != 443)) return nil;
    NSString *host = link.host.lowercaseString;
    if (![@[@"youtu.be", @"youtube.com", @"www.youtube.com", @"m.youtube.com", @"music.youtube.com"] containsObject:host]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:link resolvingAgainstBaseURL:NO];
    NSString *video = nil;
    NSString *playlist = nil;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name isEqualToString:@"v"]) video = item.value;
        if ([item.name isEqualToString:@"list"]) playlist = item.value;
    }
    NSArray *path = link.pathComponents;
    if ([host isEqualToString:@"youtu.be"] && path.count == 2) video = path[1];
    if (path.count == 3 && [@[@"embed", @"shorts", @"live"] containsObject:path[1]]) video = path[2];
    return WatchURL(video, playlist);
}

BOOL CentralYouTubeMediaHost(NSString *host)
{
    return [host hasSuffix:@".googlevideo.com"] || [host isEqualToString:@"googlevideo.com"];
}

BOOL CentralYouTubePlayerHost(NSString *host)
{
    return [host isEqualToString:@"youtubei.googleapis.com"] || [host isEqualToString:@"www.youtube.com"];
}

// Prefer the same audio client that Musike uses on iOS, then try two alternatives.
static NSArray *PlaybackClients(void)
{
    return @[
        @[@"VISIONOS", @"1.02", @"101"],
        @[@"ANDROID_VR", @"1.60.19", @"28"],
        @[@"IOS", @"21.08.3", @"5"]
    ];
}

static NSURLRequest *PlaybackRequest(NSString *operation, NSArray *profile, NSString *video, NSString *visitor)
{
    NSString *agent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
    NSMutableDictionary *client = [@{
        @"clientName":profile[0], @"clientVersion":profile[1], @"hl":@"pt", @"gl":@"BR",
        @"platform":@"DESKTOP", @"userAgent":[agent stringByAppendingString:@",gzip(gfe)"]
    } mutableCopy];
    if (visitor.length) client[@"visitorData"] = visitor;
    NSMutableDictionary *body = [@{@"context":@{@"client":client}} mutableCopy];
    if (video) {
        body[@"videoId"] = video;
        body[@"playbackContext"] = @{@"contentPlaybackContext":@{@"html5Preference":@"HTML5_PREF_WANTS"}};
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://www.youtube.com/youtubei/v1/%@?prettyPrint=false&alt=json", operation]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:profile[2] forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:profile[1] forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:@"2" forHTTPHeaderField:@"X-Goog-Api-Format-Version"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:agent forHTTPHeaderField:@"User-Agent"];
    return request;
}

NSURLRequest *CentralYouTubeVisitorRequest(void)
{
    return PlaybackRequest(@"visitor_id", PlaybackClients()[0], nil, nil);
}

NSURLRequest *CentralYouTubePlayerRequest(NSString *video, NSString *visitor, NSUInteger attempt)
{
    NSArray *clients = PlaybackClients();
    if (attempt >= clients.count || !ValidIdentifier(video, 11, 11)) return nil;
    return PlaybackRequest(@"player", clients[attempt], video, visitor);
}

static NSDictionary *ResponseDictionary(NSData *data)
{
    if (!data.length || data.length > 1024 * 1024) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

NSString *CentralYouTubeVisitorData(NSData *data)
{
    id context = ResponseDictionary(data)[@"responseContext"];
    id visitor = [context isKindOfClass:[NSDictionary class]] ? context[@"visitorData"] : nil;
    return [visitor isKindOfClass:[NSString class]] && [visitor length] <= 1024 ? visitor : nil;
}

NSString *CentralYouTubeVideoTitle(NSData *data)
{
    id details = ResponseDictionary(data)[@"videoDetails"];
    id title = [details isKindOfClass:[NSDictionary class]] ? details[@"title"] : nil;
    return [title isKindOfClass:[NSString class]] && [title length] <= 200 ? title : nil;
}

NSURL *CentralYouTubeAudioURL(NSData *data, int64_t *contentLength)
{
    *contentLength = 0;
    id streaming = ResponseDictionary(data)[@"streamingData"];
    if (![streaming isKindOfClass:[NSDictionary class]]) return nil;
    id formats = streaming[@"adaptiveFormats"];
    if (![formats isKindOfClass:[NSArray class]]) return nil;
    NSURL *candidate = nil;
    NSInteger bestRank = 0;
    for (id format in formats) {
        if (![format isKindOfClass:[NSDictionary class]]) continue;
        NSString *mime = format[@"mimeType"];
        if (![mime isKindOfClass:[NSString class]] || ![mime hasPrefix:@"audio/mp4"] ||
            [mime rangeOfString:@"mp4a."].location == NSNotFound) continue;
        NSString *address = format[@"url"];
        NSURL *url = [address isKindOfClass:[NSString class]] ? [NSURL URLWithString:address] : nil;
        if (![url.scheme isEqualToString:@"https"] || !CentralYouTubeMediaHost(url.host) ||
            url.user || url.password || (url.port && url.port.integerValue != 443)) continue;
        id track = format[@"audioTrack"];
        BOOL preferred = ![track isKindOfClass:[NSDictionary class]] || [track[@"audioIsDefault"] isEqual:@YES];
        NSInteger rank = (preferred ? 2 : 0) + ([mime rangeOfString:@"mp4a.40.2"].location != NSNotFound ? 2 : 1);
        if (rank > bestRank) {
            bestRank = rank;
            candidate = url;
            id length = format[@"contentLength"];
            *contentLength = [length isKindOfClass:[NSString class]] || [length isKindOfClass:[NSNumber class]] ?
                MAX(0, [length longLongValue]) : 0;
        }
    }
    return candidate;
}

static NSURLRequest *DataAPIRequest(NSURLComponents *endpoint, NSString *key)
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:key forHTTPHeaderField:@"X-Goog-Api-Key"];
    [request setValue:[[NSBundle mainBundle] bundleIdentifier] forHTTPHeaderField:@"X-Ios-Bundle-Identifier"];
    return request;
}

NSURLRequest *CentralYouTubeEmbedTitleRequest(NSString *video)
{
    NSURL *watch = WatchURL(video, nil);
    if (!watch) return nil;
    NSURLComponents *endpoint = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    endpoint.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:watch.absoluteString],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"]
    ];
    return [NSURLRequest requestWithURL:endpoint.URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
}

NSString *CentralYouTubeEmbedTitle(NSData *data)
{
    id title = ResponseDictionary(data)[@"title"];
    return [title isKindOfClass:[NSString class]] && [title length] <= 200 ? title : nil;
}

NSURLRequest *CentralYouTubeTitlesRequest(NSArray *videos)
{
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:KeyPreference];
    if (!key.length || !videos.count || videos.count > 50) return nil;
    for (id video in videos) if (!ValidIdentifier(video, 11, 11)) return nil;
    NSURLComponents *endpoint = [NSURLComponents componentsWithString:@"https://www.googleapis.com/youtube/v3/videos"];
    endpoint.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"part" value:@"snippet"],
        [NSURLQueryItem queryItemWithName:@"id" value:[videos componentsJoinedByString:@","]],
        [NSURLQueryItem queryItemWithName:@"fields" value:@"items(id,snippet/title)"]
    ];
    return DataAPIRequest(endpoint, key);
}

NSDictionary *CentralYouTubeTitles(NSData *data)
{
    id items = ResponseDictionary(data)[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return @{};
    NSMutableDictionary *titles = [NSMutableDictionary dictionary];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id video = item[@"id"];
        id snippet = item[@"snippet"];
        id title = [snippet isKindOfClass:[NSDictionary class]] ? snippet[@"title"] : nil;
        if (ValidIdentifier(video, 11, 11) && [title isKindOfClass:[NSString class]] && [title length])
            titles[video] = title;
    }
    return titles;
}

NSURLRequest *CentralYouTubePlaylistRequest(NSString *playlist)
{
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:KeyPreference];
    if (!key.length || !ValidIdentifier(playlist, 2, 150)) return nil;
    NSURLComponents *endpoint = [NSURLComponents componentsWithString:@"https://www.googleapis.com/youtube/v3/playlistItems"];
    endpoint.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"part" value:@"snippet,contentDetails"],
        [NSURLQueryItem queryItemWithName:@"playlistId" value:playlist],
        [NSURLQueryItem queryItemWithName:@"maxResults" value:@"50"],
        [NSURLQueryItem queryItemWithName:@"fields" value:@"items(snippet/title,contentDetails/videoId)"]
    ];
    return DataAPIRequest(endpoint, key);
}

NSArray *CentralYouTubePlaylistItems(NSData *data)
{
    id items = ResponseDictionary(data)[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id details = item[@"contentDetails"];
        id snippet = item[@"snippet"];
        id video = [details isKindOfClass:[NSDictionary class]] ? details[@"videoId"] : nil;
        id title = [snippet isKindOfClass:[NSDictionary class]] ? snippet[@"title"] : nil;
        if (!ValidIdentifier(video, 11, 11) || ![title isKindOfClass:[NSString class]]) continue;
        [tracks addObject:@{@"id":video, @"title":title}];
        if (tracks.count == 50) break;
    }
    return tracks;
}

@interface YouTubeSearch : UITableViewController <UISearchBarDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) UISegmentedControl *kind;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, copy) NSArray *results;
@property(nonatomic, strong) NSCache *images;
@property(nonatomic, copy) void (^selection)(NSURL *, NSString *);
@property(nonatomic) NSUInteger generation;
@end

@implementation YouTubeSearch

- (NSString *)key { return [[NSUserDefaults standardUserDefaults] stringForKey:KeyPreference]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"YouTube";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Fechar"
        style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Link" style:UIBarButtonItemStylePlain target:self action:@selector(enterLink)],
        [[UIBarButtonItem alloc] initWithTitle:@"Chave" style:UIBarButtonItemStylePlain target:self action:@selector(configureKey)]
    ];
    CGFloat width = self.tableView.bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 92)];
    self.kind = [[UISegmentedControl alloc] initWithItems:@[@"Vídeos", @"Playlists"]];
    self.kind.selectedSegmentIndex = 0;
    self.kind.frame = CGRectMake(12, 5, width - 24, 30);
    self.kind.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.kind addTarget:self action:@selector(kindChanged) forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.kind];
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 36, width, 56)];
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search.placeholder = @"Nome da música, artista ou playlist";
    self.search.delegate = self;
    [header addSubview:self.search];
    self.tableView.tableHeaderView = header;
    self.tableView.rowHeight = 64;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.images = [[NSCache alloc] init];
    self.images.countLimit = 24;
    self.message = [[UILabel alloc] init];
    self.message.textAlignment = NSTextAlignmentCenter;
    self.message.textColor = [UIColor darkGrayColor];
    self.message.font = [UIFont systemFontOfSize:14];
    self.message.numberOfLines = 0;
    self.tableView.backgroundView = self.message;
    [self showPrompt];
}

- (void)showPrompt
{
    self.message.text = self.key.length ? @"Digite um nome e escolha o resultado para ouvir." :
        @"Toque em Link para ouvir uma faixa.\nPara pesquisar ou abrir playlists, configure a chave.";
}

- (void)close
{
    self.generation++;
    [self.task cancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)selectURL:(NSURL *)url title:(NSString *)title
{
    if (!url) return;
    self.generation++;
    [self.task cancel];
    void (^selection)(NSURL *, NSString *) = self.selection;
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:^{
        if (selection) selection(url, title);
    }];
}

- (void)enterLink
{
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Abrir no YouTube"
        message:@"Cole o link de um vídeo ou playlist." preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://www.youtube.com/…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakForm = form;
    [form addAction:[UIAlertAction actionWithTitle:@"Abrir" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = [weakForm.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *url = text.length ? CentralYouTubeWatchURL([NSURL URLWithString:text]) : nil;
        if (url) [self selectURL:url title:@"YouTube"];
        else {
            self.results = nil;
            self.message.text = @"Link inválido. Use um vídeo ou playlist do YouTube.";
            [self.tableView reloadData];
        }
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)configureKey
{
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Chave do YouTube"
        message:@"Cole sua chave da YouTube Data API v3. A chave serve para buscar pelo nome e abrir playlists."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Chave da API";
        field.secureTextEntry = YES;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakForm = form;
    [form addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *key = [weakForm.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!ValidIdentifier(key, 16, 128)) {
            self.results = nil;
            self.message.text = @"Chave inválida. Confira o valor no Google Cloud.";
            [self.tableView reloadData];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:key forKey:KeyPreference];
        [self showPrompt];
        if (self.search.text.length) [self searchBarSearchButtonClicked:self.search];
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)kindChanged
{
    if (self.key.length && self.search.text.length) [self searchBarSearchButtonClicked:self.search];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)search
{
    NSString *key = self.key;
    if (!key.length) {
        [search resignFirstResponder];
        [self configureKey];
        return;
    }
    NSString *query = [search.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length || query.length > 150) return;
    [search resignFirstResponder];
    [self.task cancel];
    NSUInteger generation = ++self.generation;
    self.results = nil;
    self.message.text = @"Buscando no YouTube…";
    [self.tableView reloadData];
    BOOL playlists = self.kind.selectedSegmentIndex == 1;
    NSURLComponents *endpoint = [NSURLComponents componentsWithString:@"https://www.googleapis.com/youtube/v3/search"];
    NSMutableArray *parameters = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"part" value:@"snippet"],
        [NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"type" value:playlists ? @"playlist" : @"video"],
        [NSURLQueryItem queryItemWithName:@"regionCode" value:@"BR"],
        [NSURLQueryItem queryItemWithName:@"relevanceLanguage" value:@"pt"],
        [NSURLQueryItem queryItemWithName:@"maxResults" value:@"20"]
    ]];
    endpoint.queryItems = parameters;
    endpoint.percentEncodedQuery = [endpoint.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    NSURLRequest *request = DataAPIRequest(endpoint, key);
    __weak YouTubeSearch *controller = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL received = !error && data.length && data.length < 1024 * 1024;
        id json = received ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *items = [json isKindOfClass:[NSDictionary class]] ? json[@"items"] : nil;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSMutableArray *results = [NSMutableArray array];
        if (status == 200 && [items isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *ids = item[@"id"];
                NSDictionary *snippet = item[@"snippet"];
                if (![ids isKindOfClass:[NSDictionary class]] || ![snippet isKindOfClass:[NSDictionary class]]) continue;
                NSURL *url = WatchURL(ids[@"videoId"], ids[@"playlistId"]);
                NSString *title = snippet[@"title"];
                if (!url || ![title isKindOfClass:[NSString class]]) continue;
                NSString *channel = snippet[@"channelTitle"];
                NSDictionary *thumbnails = snippet[@"thumbnails"];
                NSDictionary *preview = [thumbnails isKindOfClass:[NSDictionary class]] ? thumbnails[@"default"] : nil;
                NSString *image = [preview isKindOfClass:[NSDictionary class]] ? preview[@"url"] : nil;
                [results addObject:@{@"title":title, @"channel":[channel isKindOfClass:[NSString class]] ? channel : @"YouTube",
                    @"url":url, @"image":[image isKindOfClass:[NSString class]] ? image : @""}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YouTubeSearch *target = controller;
            if (!target || target.generation != generation) return;
            target.task = nil;
            target.results = results;
            if (results.count) target.message.text = nil;
            else if (status == 200) target.message.text = @"Nenhum resultado disponível.";
            else if (status == 400 || status == 403 || status == 429) target.message.text = @"Confira a chave, a ativação da API e a cota no Google Cloud.";
            else target.message.text = @"A busca falhou. Confira a internet e tente de novo.";
            [target.tableView reloadData];
        });
    }];
    [self.task resume];
}

- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(__unused NSInteger)section
{
    return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"YouTubeResult"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"YouTubeResult"];
    NSDictionary *result = self.results[path.row];
    NSString *address = result[@"image"];
    cell.textLabel.text = result[@"title"];
    cell.detailTextLabel.text = result[@"channel"];
    cell.imageView.image = [self.images objectForKey:address];
    NSURL *imageURL = address.length ? [NSURL URLWithString:address] : nil;
    if (!cell.imageView.image && [imageURL.scheme isEqualToString:@"https"] && [imageURL.host isEqualToString:@"i.ytimg.com"]) {
        __weak YouTubeSearch *controller = self;
        [[self.session dataTaskWithURL:imageURL completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
            UIImage *image = !error && data.length && data.length < 256 * 1024 ? [UIImage imageWithData:data] : nil;
            if (!image) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                YouTubeSearch *target = controller;
                [target.images setObject:image forKey:address];
                if (path.row < (NSInteger)target.results.count && [target.results[path.row][@"image"] isEqual:address]) {
                    UITableViewCell *visible = [target.tableView cellForRowAtIndexPath:path];
                    visible.imageView.image = image;
                    [visible setNeedsLayout];
                }
            });
        }] resume];
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path
{
    [table deselectRowAtIndexPath:path animated:YES];
    NSDictionary *result = self.results[path.row];
    [self selectURL:result[@"url"] title:result[@"title"]];
}

@end

UIViewController *CentralYouTubeSearch(NSURLSession *session, void (^selection)(NSURL *, NSString *))
{
    YouTubeSearch *search = [[YouTubeSearch alloc] initWithStyle:UITableViewStylePlain];
    search.session = session;
    search.selection = selection;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:search];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigation;
}
