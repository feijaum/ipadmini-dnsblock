#import "YouTube.h"
#import <arpa/inet.h>

static NSString *const KeyPreference = @"youtubeDataAPIKey";
static NSString *const ServerPreference = @"youtubeAudioServer";
static NSString *const TokenPreference = @"youtubeAudioToken";

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

static NSURLComponents *LocalAudioServer(NSString *address)
{
    if (!address.length) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:address];
    struct in_addr ip;
    if (![url.scheme isEqualToString:@"http"] || !url.host ||
        inet_pton(AF_INET, url.host.UTF8String, &ip) != 1 ||
        url.user || url.password || url.query || url.fragment ||
        (url.path.length && ![url.path isEqualToString:@"/"]) ||
        (url.port && (url.port.integerValue < 1 || url.port.integerValue > 65535))) return nil;
    uint32_t host = ntohl(ip.s_addr);
    BOOL private = (host >> 24) == 10 || (host >> 20) == 0xac1 || (host >> 16) == 0xc0a8;
    return private ? url : nil;
}

NSURLRequest *CentralYouTubeAudioRequest(NSString *route, NSString *identifier)
{
    BOOL playlist = [route isEqualToString:@"playlist"];
    if (!(playlist || [route isEqualToString:@"audio"]) ||
        !ValidIdentifier(identifier, playlist ? 2 : 11, playlist ? 150 : 11)) return nil;
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];
    NSURLComponents *url = LocalAudioServer([settings stringForKey:ServerPreference]);
    NSString *token = [settings stringForKey:TokenPreference];
    if (!url || !ValidIdentifier(token, 32, 128)) return nil;
    url.path = [NSString stringWithFormat:@"/%@/%@", route, identifier];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:105];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return request;
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
        [[UIBarButtonItem alloc] initWithTitle:@"Chave" style:UIBarButtonItemStylePlain target:self action:@selector(configureKey)],
        [[UIBarButtonItem alloc] initWithTitle:@"Servidor" style:UIBarButtonItemStylePlain target:self action:@selector(configureServer)]
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
    self.message.text = self.key.length ? @"Digite um nome e escolha o resultado para ouvir. Configure o conversor em Servidor." :
        @"Toque em Link para abrir um vídeo ou playlist.\nPara buscar pelo nome, configure a chave em Chave.";
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
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];
    if (!LocalAudioServer([settings stringForKey:ServerPreference]) ||
        !ValidIdentifier([settings stringForKey:TokenPreference], 32, 128)) {
        [self configureServer];
        return;
    }
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

- (void)configureServer
{
    NSUserDefaults *settings = [NSUserDefaults standardUserDefaults];
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Servidor de áudio"
        message:@"Informe o endereço HTTP na rede de casa e o token CENTRAL_YOUTUBE_TOKEN do servidor."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"http://192.168.0.10:8787";
        field.text = [settings stringForKey:ServerPreference];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Token do servidor";
        field.text = [settings stringForKey:TokenPreference];
        field.secureTextEntry = YES;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakForm = form;
    [form addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSString *address = [weakForm.textFields.firstObject.text stringByTrimmingCharactersInSet:spaces];
        NSString *token = [weakForm.textFields.lastObject.text stringByTrimmingCharactersInSet:spaces];
        if (!LocalAudioServer(address) || !ValidIdentifier(token, 32, 128)) {
            UIAlertController *invalid = [UIAlertController alertControllerWithTitle:@"Configuração inválida"
                message:@"Use um endereço HTTP com IP privado e o token do servidor (32 a 128 caracteres)."
                preferredStyle:UIAlertControllerStyleAlert];
            [invalid addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:invalid animated:YES completion:nil];
            return;
        }
        [settings setObject:address forKey:ServerPreference];
        [settings setObject:token forKey:TokenPreference];
        NSIndexPath *row = self.tableView.indexPathForSelectedRow;
        if (row) [self.tableView deselectRowAtIndexPath:row animated:YES];
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)configureKey
{
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Chave do YouTube"
        message:@"Cole sua chave da YouTube Data API v3. Para abrir por link, a chave é opcional."
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
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:key forHTTPHeaderField:@"X-Goog-Api-Key"];
    [request setValue:[[NSBundle mainBundle] bundleIdentifier] forHTTPHeaderField:@"X-Ios-Bundle-Identifier"];
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
