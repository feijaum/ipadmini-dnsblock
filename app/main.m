#import <UIKit/UIKit.h>
#import "Weather.h"
#import "DrivePhotos.h"
#import "Music.h"
#import "YouTube.h"
#import <EventKit/EventKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <sys/socket.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>

static NSDictionary *RequestStatus(const char *command)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;

    struct timeval timeout = { .tv_sec = 3 };
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in address = {
        .sin_len = sizeof(address),
        .sin_family = AF_INET,
        .sin_port = htons(8753),
        .sin_addr = { .s_addr = htonl(INADDR_LOOPBACK) }
    };
    NSMutableData *reply = [NSMutableData data];
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        size_t left = strlen(command);
        while (left) {
            ssize_t sent = send(fd, command, left, 0);
            if (sent < 0 && errno == EINTR) continue;
            if (sent <= 0) break;
            command += sent;
            left -= (size_t)sent;
        }
        char buffer[256];
        while (!left && reply.length < sizeof(buffer)) {
            ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
            if (received < 0 && errno == EINTR) continue;
            if (received <= 0) break;
            [reply appendBytes:buffer length:(NSUInteger)received];
            if (memchr(buffer, '\n', (size_t)received)) break;
        }
    }
    close(fd);
    if (!reply.length || reply.length > 256) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static NSString *const CalendarPreference = @"familyCalendar";
static NSString *const MusicLinksPreference = @"houseMusicLinks";

static NSString *MusicLinkService(NSURL *url)
{
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || url.user || url.password ||
        (url.port && url.port.integerValue != 443) || url.path.length < 2) return nil;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"open.spotify.com"] || [host isEqualToString:@"spotify.link"]) return @"Spotify";
    if ([host isEqualToString:@"youtu.be"] || [host isEqualToString:@"youtube.com"] ||
        [host isEqualToString:@"www.youtube.com"] || [host isEqualToString:@"music.youtube.com"] ||
        [host isEqualToString:@"m.youtube.com"]) return @"YouTube";
    if ([host isEqualToString:@"music.apple.com"]) return @"Apple Music";
    return nil;
}

static NSString *const PhotoFillPreference = @"photoFillMode";

static NSString *const PhotosPreference = @"familyPhotos";

static UIColor *Color(NSUInteger hex)
{
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0
                           green:((hex >> 8) & 255) / 255.0
                            blue:(hex & 255) / 255.0 alpha:1];
}

static UILabel *Label(UIView *parent, CGFloat size, NSString *font, NSUInteger color)
{
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont fontWithName:font size:size] ?: [UIFont systemFontOfSize:size];
    label.textColor = Color(color);
    [parent addSubview:label];
    return label;
}

static UIView *Card(UIView *parent, NSUInteger color)
{
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = Color(color);
    card.layer.cornerRadius = 19;
    card.clipsToBounds = YES;
    [parent addSubview:card];
    return card;
}

static UIButton *Button(UIView *parent, NSString *title, id target, SEL action)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = Color(0x263246);
    button.layer.cornerRadius = 12;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:Color(0xe9f1ff) forState:UIControlStateNormal];
    [button setTitleColor:Color(0x8695ad) forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:button];
    return button;
}

@interface HomePanel : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UITableViewDelegate, UITableViewDataSource>
@property(nonatomic, strong) UIView *clockCard;
@property(nonatomic, strong) UIView *agendaCard;
@property(nonatomic, strong) UIView *photoCard;
@property(nonatomic, strong) UILabel *brand;
@property(nonatomic, strong) UILabel *battery;
@property(nonatomic, strong) UILabel *clock;
@property(nonatomic, strong) UILabel *date;
@property(nonatomic, strong) UILabel *weatherLabel;
@property(nonatomic, strong) LocalWeather *weather;
@property(nonatomic, strong) UILabel *agendaHeading;
@property(nonatomic, strong) UILabel *agenda;
@property(nonatomic, strong) UILabel *legendHeading;
@property(nonatomic, strong) UIScrollView *legendScroll;
@property(nonatomic, copy) NSArray *calendarCells;
@property(nonatomic, strong) UILabel *photoHeading;
@property(nonatomic, strong) UILabel *photoHint;
@property(nonatomic, strong) UIImageView *photo;
@property(nonatomic, strong) UIButton *photoFitButton;
@property(nonatomic, strong) DrivePhotos *drivePhotos;
@property(nonatomic, strong) UIButton *filterButton;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic, strong) HouseMusic *music;
@property(nonatomic) BOOL readingWebQueue;
@property(nonatomic, strong) NSURL *pendingWebTrack;
@property(nonatomic, strong) UIView *musicCard;
@property(nonatomic, strong) UIScrollView *musicBody;
@property(nonatomic, strong) UILabel *musicHeading;
@property(nonatomic, strong) UILabel *musicSummary;
@property(nonatomic, strong) UIButton *musicAddButton;
@property(nonatomic, strong) UITableView *musicLinks;
@property(nonatomic, strong) UILabel *musicEmpty;
@property(nonatomic, strong) NSMutableArray *savedMusic;
@property(nonatomic, strong) UIButton *musicSearchButton;
@property(nonatomic, strong) UIButton *youtubeButton;
@property(nonatomic, strong) UIButton *musicStopButton;
@property(nonatomic, strong) UIButton *musicToggleButton;
@property(nonatomic, strong) NSDateFormatter *clockFormat;
@property(nonatomic, strong) NSDateFormatter *dateFormat;
@property(nonatomic, strong) NSDateFormatter *eventFormat;
@property(nonatomic, strong) EKEventStore *eventStore;
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, copy) NSString *serviceMessage;
@property(nonatomic) BOOL busy;
@property(nonatomic) NSUInteger photoIndex;
@property(nonatomic) BOOL showingDrivePhoto;
@property(nonatomic) NSTimeInterval lastPhotoChange;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation HomePanel

- (BOOL)prefersStatusBarHidden { return YES; }

- (NSDateFormatter *)formatter:(NSString *)format
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"pt_BR"];
    formatter.dateFormat = format;
    return formatter;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = Color(0x101722);
    self.brand = Label(self.view, 14, @"HelveticaNeue-Medium", 0xaac1de);
    self.brand.text = @"CENTRAL DA CASA";
    self.brand.adjustsFontSizeToFitWidth = YES;
    self.battery = Label(self.view, 13, @"HelveticaNeue-Medium", 0xe9f1ff);
    self.battery.textAlignment = NSTextAlignmentCenter;
    self.battery.backgroundColor = Color(0x24354a);
    self.battery.layer.cornerRadius = 9;
    self.battery.clipsToBounds = YES;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self updateBattery:nil];
    self.filterButton = Button(self.view, @"Bloqueio  ·  Consultando…", self, @selector(toggleFilter));
    self.filterButton.enabled = NO;
    self.settingsButton = Button(self.view, @"⚙  Ajustes", self, @selector(showSettings));
    self.settingsButton.accessibilityLabel = @"Configurações";
    self.music = [[HouseMusic alloc] init];
    self.musicCard = Card(self.view, 0x1a2637);
    self.musicBody = [[UIScrollView alloc] init];
    [self.musicCard addSubview:self.musicBody];
    self.musicHeading = Label(self.musicBody, 13, @"HelveticaNeue-Medium", 0x9adfce);
    self.musicHeading.text = @"MÚSICA";
    self.musicSearchButton = Button(self.musicBody, @"♫  Pesquisar música", self, @selector(searchMusic));
    self.youtubeButton = Button(self.musicBody, @"YouTube", self, @selector(openYouTubeSearch));
    self.musicStopButton = Button(self.musicBody, @"Parar", self, @selector(stopMusic));
    self.musicToggleButton = Button(self.musicBody, @"Tocar", self, @selector(toggleMusic));
    self.musicSummary = Label(self.musicBody, 14, @"HelveticaNeue-Medium", 0xe9f1ff);
    self.musicSummary.numberOfLines = 2;
    self.musicAddButton = Button(self.musicBody, @"+  Salvar link", self, @selector(addMusicLink));
    self.savedMusic = [[[NSUserDefaults standardUserDefaults] arrayForKey:MusicLinksPreference] mutableCopy] ?: [NSMutableArray array];
    self.musicLinks = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.musicLinks.backgroundColor = [UIColor clearColor];
    self.musicLinks.separatorColor = Color(0x34465d);
    self.musicLinks.rowHeight = 47;
    self.musicLinks.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.musicLinks.delegate = self;
    self.musicLinks.dataSource = self;
    [self.musicBody addSubview:self.musicLinks];
    self.musicEmpty = [[UILabel alloc] init];
    self.musicEmpty.text = @"Salve um álbum ou playlist aqui.";
    self.musicEmpty.textAlignment = NSTextAlignmentCenter;
    self.musicEmpty.numberOfLines = 0;
    self.musicEmpty.font = [UIFont systemFontOfSize:12];
    self.musicEmpty.textColor = Color(0xaac1de);
    self.musicLinks.backgroundView = self.musicEmpty;
    self.musicEmpty.hidden = self.savedMusic.count > 0;
    __weak HomePanel *musicPanel = self;
    self.music.didUpdate = ^{
        [musicPanel updateMusicButtons];
        [musicPanel checkWebQueue];
    };
    [self updateMusicButtons];

    self.clockCard = Card(self.view, 0x131f33);
    self.clockCard.backgroundColor = [self.clockCard.backgroundColor colorWithAlphaComponent:0.44];
    self.clock = Label(self.clockCard, 154, @"HelveticaNeue-Light", 0xf2f7ff);
    self.clock.textAlignment = NSTextAlignmentCenter;
    self.clock.adjustsFontSizeToFitWidth = YES;
    self.clock.minimumScaleFactor = 0.35;
    self.date = Label(self.clockCard, 22, @"HelveticaNeue", 0xb5cce7);
    self.date.textAlignment = NSTextAlignmentCenter;
    self.date.adjustsFontSizeToFitWidth = YES;
    self.weatherLabel = Label(self.clockCard, 16, @"HelveticaNeue-Medium", 0xe7f3ff);
    self.weatherLabel.textAlignment = NSTextAlignmentCenter;
    self.weatherLabel.adjustsFontSizeToFitWidth = YES;
    self.weather = [[LocalWeather alloc] initWithBackdrop:self.view label:self.weatherLabel];

    self.agendaCard = Card(self.view, 0x1a2637);
    self.agendaHeading = Label(self.agendaCard, 13, @"HelveticaNeue-Medium", 0x9adfce);
    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:49];
    NSArray *weekdays = @[@"D", @"S", @"T", @"Q", @"Q", @"S", @"S"];
    for (NSUInteger index = 0; index < 49; index++) {
        UILabel *cell = Label(self.agendaCard, 15, @"HelveticaNeue-Medium", 0xe9f1ff);
        cell.textAlignment = NSTextAlignmentCenter;
        cell.layer.cornerRadius = 5;
        cell.clipsToBounds = YES;
        if (index < 7) {
            cell.text = weekdays[index];
            cell.textColor = Color(0x9fb3ce);
        }
        [cells addObject:cell];
    }
    self.calendarCells = cells;
    self.legendHeading = Label(self.agendaCard, 12, @"HelveticaNeue-Medium", 0x9adfce);
    self.legendHeading.text = @"DATAS COMEMORATIVAS";
    self.legendHeading.adjustsFontSizeToFitWidth = YES;
    self.legendScroll = [[UIScrollView alloc] init];
    [self.agendaCard addSubview:self.legendScroll];
    self.agenda = Label(self.legendScroll, 14, @"HelveticaNeue", 0xe9f1ff);
    self.agenda.numberOfLines = 0;

    self.photoCard = Card(self.view, 0x223247);
    self.photo = [[UIImageView alloc] init];
    self.photo.backgroundColor = Color(0x152131);
    self.photo.clipsToBounds = YES;
    [self.photoCard addSubview:self.photo];
    UIView *photoCaption = [[UIView alloc] init];
    photoCaption.backgroundColor = [Color(0x101722) colorWithAlphaComponent:0.8];
    [self.photoCard addSubview:photoCaption];
    self.photoHeading = Label(photoCaption, 13, @"HelveticaNeue-Medium", 0xf2f7ff);
    self.photoHeading.text = @"FOTOS DA FAMÍLIA";
    self.photoFitButton = Button(photoCaption, @"", self, @selector(togglePhotoFit));
    [self applyPhotoFit];
    self.photoHint = Label(self.photoCard, 15, @"HelveticaNeue", 0xb5cce7);
    self.photoHint.text = @"Adicione fotos em Ajustes";
    self.photoHint.textAlignment = NSTextAlignmentCenter;
    self.photoHint.numberOfLines = 2;
    self.photoHint.adjustsFontSizeToFitWidth = YES;
    self.drivePhotos = [[DrivePhotos alloc] init];
    __weak HomePanel *panel = self;
    self.drivePhotos.didUpdate = ^{
        if (!panel.showingDrivePhoto || !panel.drivePhotos.hasAlbum) [panel nextPhoto];
    };

    self.clockFormat = [self formatter:@"HH:mm"];
    self.dateFormat = [self formatter:@"EEEE, d 'de' MMMM"];
    self.eventFormat = [self formatter:@"dd/MM 'às' HH:mm"];
    self.eventStore = [[EKEventStore alloc] init];
    self.photoIndex = NSNotFound;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(updateBattery:) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateBattery:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(resume) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(pause) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(calendarChanged:) name:EKEventStoreChangedNotification object:self.eventStore];
    [self updateClock];
    [self updateAgenda];
    [self nextPhoto];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    BOOL landscape = width > height;
    CGFloat padding = width < 500 ? 14 : 32;
    CGFloat gap = width < 500 ? 10 : 18;
    CGFloat inner = width - 2 * padding;
    BOOL compact = width < 500;
    CGFloat buttonY = compact ? padding + 28 : padding;
    CGFloat batteryWidth = 86;
    CGFloat batteryX = width - padding - batteryWidth - (compact ? 0 : 282);
    self.battery.frame = CGRectMake(batteryX, padding + (compact ? 0 : 9), batteryWidth, compact ? 22 : 26);
    self.brand.frame = CGRectMake(padding, padding, MAX(1, batteryX - padding - 8), compact ? 22 : 44);
    self.settingsButton.frame = CGRectMake(width - padding - 96, buttonY, 96, 44);
    self.filterButton.frame = CGRectMake(width - padding - 274, buttonY, 168, 44);

    CGFloat top = buttonY + 44 + gap;
    CGFloat available = height - top - padding;
    BOOL sideBySide = landscape || width >= 600;
    CGFloat topHeight = floor(available * (sideBySide ? 0.59 : 0.58));
    if (width >= 720) {
        CGFloat musicWidth = MIN(282, floor((inner - gap) * 0.35));
        CGFloat photoWidth = inner - musicWidth - gap;
        self.photoCard.frame = CGRectMake(padding, top, photoWidth, topHeight);
        self.musicCard.frame = CGRectMake(padding + photoWidth + gap, top, musicWidth, topHeight);
    } else {
        CGFloat musicHeight = floor(topHeight * 0.53);
        self.photoCard.frame = CGRectMake(padding, top, inner, topHeight - musicHeight - gap);
        self.musicCard.frame = CGRectMake(padding, CGRectGetMaxY(self.photoCard.frame) + gap, inner, musicHeight);
    }
    [self layoutMusicCard];
    CGFloat bottomY = top + topHeight + gap;
    CGFloat remainder = available - topHeight - gap;
    if (sideBySide) {
        CGFloat calendarWidth = floor((inner - gap) * 0.47);
        self.agendaCard.frame = CGRectMake(padding, bottomY, calendarWidth, remainder);
        self.clockCard.frame = CGRectMake(padding + calendarWidth + gap, bottomY, inner - calendarWidth - gap, remainder);
    } else {
        CGFloat calendarHeight = floor((remainder - gap) * 0.61);
        self.agendaCard.frame = CGRectMake(padding, bottomY, inner, calendarHeight);
        self.clockCard.frame = CGRectMake(padding, bottomY + calendarHeight + gap, inner, remainder - calendarHeight - gap);
    }
    CGFloat clockWidth = self.clockCard.bounds.size.width;
    CGFloat clockHeight = self.clockCard.bounds.size.height;
    CGFloat clockFaceHeight = clockHeight * 0.57;
    self.clock.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:MIN(110, clockFaceHeight * 0.88)];
    self.clock.frame = CGRectMake(12, clockHeight * 0.07, clockWidth - 24, clockFaceHeight);
    self.date.frame = CGRectMake(12, clockHeight * 0.66, clockWidth - 24, clockHeight * 0.16);
    self.weatherLabel.frame = CGRectMake(12, clockHeight * 0.82, clockWidth - 24, clockHeight * 0.14);
    CGFloat agendaWidth = self.agendaCard.bounds.size.width;
    CGFloat agendaHeight = self.agendaCard.bounds.size.height;
    self.agendaHeading.frame = CGRectMake(16, 10, agendaWidth - 32, 20);
    CGFloat gridWidth = floor((agendaWidth - 38) * 0.56);
    CGFloat cellWidth = gridWidth / 7;
    CGFloat cellHeight = MIN(32, MAX(1, (agendaHeight - 46) / 7));
    [self.calendarCells enumerateObjectsUsingBlock:^(UILabel *cell, NSUInteger index, __unused BOOL *stop) {
        cell.frame = CGRectMake(14 + (index % 7) * cellWidth, 33 + (index / 7) * cellHeight,
                                MAX(1, cellWidth - 2), MAX(1, cellHeight - 2));
        cell.font = [UIFont fontWithName:@"HelveticaNeue-Medium" size:MAX(8, MIN(15, cellHeight * 0.75))];
    }];
    CGFloat legendX = gridWidth + 24;
    CGFloat legendWidth = MAX(1, agendaWidth - legendX - 12);
    self.legendHeading.frame = CGRectMake(legendX, 35, legendWidth, 18);
    self.legendScroll.frame = CGRectMake(legendX, 56, legendWidth, MAX(1, agendaHeight - 65));
    CGFloat textHeight = [self.agenda sizeThatFits:CGSizeMake(legendWidth, CGFLOAT_MAX)].height;
    self.agenda.frame = CGRectMake(0, 0, legendWidth, textHeight);
    self.legendScroll.contentSize = CGSizeMake(legendWidth, textHeight);
    CGFloat photoWidth = self.photoCard.bounds.size.width;
    CGFloat panelHeight = self.photoCard.bounds.size.height;
    CGFloat captionHeight = 48;
    self.photo.frame = CGRectMake(0, captionHeight, photoWidth, MAX(0, panelHeight - captionHeight));
    self.photoHeading.superview.frame = CGRectMake(0, 0, photoWidth, captionHeight);
    self.photoHeading.frame = CGRectMake(16, 0, photoWidth - 126, captionHeight);
    self.photoFitButton.frame = CGRectMake(photoWidth - 110, 4, 102, 40);
    self.photoHint.frame = CGRectInset(self.photo.frame, 16, 0);

}

- (void)layoutMusicCard
{
    CGFloat width = self.musicCard.bounds.size.width;
    CGFloat height = self.musicCard.bounds.size.height;
    BOOL controls = self.music.canStop;
    CGFloat contentHeight = MAX(height, controls ? 276 : 228);
    self.musicBody.frame = self.musicCard.bounds;
    self.musicBody.contentSize = CGSizeMake(width, contentHeight);
    self.musicBody.scrollEnabled = contentHeight > height;
    CGFloat inset = 12;
    self.musicHeading.frame = CGRectMake(inset, 8, width - 2 * inset, 20);
    CGFloat buttonWidth = floor((width - 2 * inset - 6) / 2);
    self.musicSearchButton.frame = CGRectMake(inset, 34, buttonWidth, 42);
    self.youtubeButton.frame = CGRectMake(inset + buttonWidth + 6, 34, buttonWidth, 42);
    self.musicSummary.frame = CGRectMake(inset, 81, width - 2 * inset, 42);
    self.musicToggleButton.frame = CGRectMake(inset, 129, buttonWidth, 42);
    self.musicStopButton.frame = self.music.canToggle
        ? CGRectMake(inset + buttonWidth + 6, 129, buttonWidth, 42)
        : CGRectMake(inset, 129, width - 2 * inset, 42);
    CGFloat offset = controls ? 48 : 0;
    self.musicAddButton.frame = CGRectMake(inset, 129 + offset, width - 2 * inset, 42);
    self.musicLinks.frame = CGRectMake(inset, 174 + offset, width - 2 * inset, contentHeight - 178 - offset);
}

- (void)openYouTubeSearch
{
    __weak HomePanel *panel = self;
    UIViewController *search = [self.music youtubeControllerWithSelection:^(NSURL *url, NSString *title) {
        [panel.music playYouTube:url title:title];
    }];
    [self presentViewController:search animated:YES completion:nil];
}

- (void)searchMusic
{
    [self presentViewController:[self.music searchController] animated:YES completion:nil];
}

- (void)toggleMusic { [self.music togglePlayback]; }
- (void)stopMusic { [self.music stopPlayback]; }

- (void)updateMusicButtons
{
    self.musicSummary.text = self.music.summary;
    [self.musicToggleButton setTitle:(self.music.playing ? @"Pausar" : @"Tocar") forState:UIControlStateNormal];
    self.musicToggleButton.hidden = !self.music.canToggle;
    self.musicStopButton.hidden = !self.music.canStop;
    [self.view setNeedsLayout];
}

- (void)addMusicLink
{
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Salvar álbum ou playlist"
        message:@"Cole um link de um vídeo ou playlist do YouTube, do Spotify ou do Apple Music."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Nome do atalho"; }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Link de compartilhamento";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakForm = form;
    [form addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSArray *fields = weakForm.textFields;
        if (fields.count != 2) return;
        NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSString *name = [[fields[0] text] stringByTrimmingCharactersInSet:spaces];
        NSString *address = [[fields[1] text] stringByTrimmingCharactersInSet:spaces];
        NSString *service = MusicLinkService([NSURL URLWithString:address]);
        if (!service || address.length > 2000) {
            [self message:@"Link de música" body:@"Cole um link HTTPS de compartilhamento de um dos serviços indicados."];
            return;
        }
        [self.savedMusic insertObject:@{@"name":name.length ? name : service, @"url":address, @"service":service} atIndex:0];
        [self saveMusicLinks];
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)saveMusicLinks
{
    [[NSUserDefaults standardUserDefaults] setObject:self.savedMusic forKey:MusicLinksPreference];
    self.musicEmpty.hidden = self.savedMusic.count > 0;
    [self.musicLinks reloadData];
}

- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(__unused NSInteger)section
{
    return self.savedMusic.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"SavedMusic"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SavedMusic"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = Color(0xe9f1ff);
        cell.textLabel.font = [UIFont boldSystemFontOfSize:13];
        cell.detailTextLabel.textColor = Color(0xaac1de);
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *link = self.savedMusic[path.row];
    cell.textLabel.text = link[@"name"];
    cell.detailTextLabel.text = link[@"service"];
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path
{
    [table deselectRowAtIndexPath:path animated:YES];
    NSURL *url = [NSURL URLWithString:self.savedMusic[path.row][@"url"]];
    NSURL *youtube = CentralYouTubeWatchURL(url);
    if (youtube) [self.music playYouTube:youtube title:self.savedMusic[path.row][@"name"] ?: @"YouTube"];
    else if (MusicLinkService(url)) [[UIApplication sharedApplication] openURL:url];
}

- (void)tableView:(__unused UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)path
{
    if (style != UITableViewCellEditingStyleDelete) return;
    [self.savedMusic removeObjectAtIndex:path.row];
    [self saveMusicLinks];
}

- (void)updateBattery:(__unused NSNotification *)notification
{
    UIDevice *device = [UIDevice currentDevice];
    float level = device.batteryLevel;
    BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
    self.battery.text = level < 0 ? @"Bat. —" :
        [NSString stringWithFormat:@"%@ %.0f%%", charging ? @"⚡" : @"Bat.", level * 100];
    self.battery.textColor = Color(charging ? 0x9adfce : (level >= 0 && level <= 0.2 ? 0xffc18c : 0xe9f1ff));
    self.battery.accessibilityLabel = level < 0 ? @"Nível da bateria indisponível" :
        [NSString stringWithFormat:@"Bateria %.0f por cento%@", level * 100, charging ? @", conectada à energia" : @""];
}

- (void)updateClock
{
    NSDate *now = [NSDate date];
    self.clock.text = [self.clockFormat stringFromDate:now];
    self.date.text = [self.dateFormat stringFromDate:now];
}

- (void)resume
{
    [self.weather resume];
    [self.drivePhotos resume];
    [self updateMusicButtons];
    [self updateBattery:nil];
    [self updateClock];
    [self refreshStatus];
    [self checkWebQueue];
    [self updateAgenda];
    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    }
}

- (void)pause
{
    [self.weather pause];
    [self.drivePhotos pause];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)tick:(NSTimer *)timer
{
    [self updateClock];
    [self checkWebQueue];
    NSInteger seconds = (NSInteger)[NSDate date].timeIntervalSince1970;
    if ([NSProcessInfo processInfo].systemUptime - self.lastPhotoChange >= 5) [self nextPhoto];
    if (seconds % 60 == 0) {
        [self refreshStatus];
        [self updateAgenda];
    }
}

- (void)checkWebQueue
{
    if (self.music.canStop || self.readingWebQueue) return;
    if (self.pendingWebTrack) {
        NSURL *track = self.pendingWebTrack;
        self.pendingWebTrack = nil;
        [self.music playYouTube:track title:@"Pedido pelo Wi-Fi"];
        return;
    }

    self.readingWebQueue = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        id video = RequestStatus("next\n")[@"video"];
        NSURL *track = nil;
        if ([video isKindOfClass:[NSString class]] && [video length] == 11) {
            NSURL *link = [NSURL URLWithString:[@"https://youtu.be/" stringByAppendingString:video]];
            track = CentralYouTubeWatchURL(link);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.readingWebQueue = NO;
            if (track) {
                self.pendingWebTrack = track;
                [self checkWebQueue];
            }
        });
    });
}

- (void)refreshStatus { [self runCommand:"status\n" changing:NO]; }

- (void)toggleFilter
{
    if (self.status) {
        [self runCommand:[self.status[@"enabled"] boolValue] ? "disable\n" : "enable\n" changing:YES];
    }
}

- (void)runCommand:(const char *)command changing:(BOOL)changing
{
    if (self.busy) return;
    self.busy = YES;
    if (changing) {
        self.filterButton.enabled = NO;
        [self.filterButton setTitle:@"Bloqueio  ·  Aplicando…" forState:UIControlStateNormal];
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *reply = RequestStatus(command);
        NSString *error = [reply[@"error"] isKindOfClass:[NSString class]] ? reply[@"error"] : nil;
        NSDictionary *status = changing && (error || !reply) ? RequestStatus("status\n") : reply;
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL valid = [status[@"enabled"] isKindOfClass:[NSNumber class]]
                && [status[@"ip"] isKindOfClass:[NSString class]]
                && [status[@"queries"] isKindOfClass:[NSNumber class]]
                && [status[@"blocked"] isKindOfClass:[NSNumber class]];
            self.status = valid ? status : nil;
            self.busy = NO;
            self.serviceMessage = error ?: (valid ? @"Conectado" : @"Serviço indisponível");
            BOOL enabled = [self.status[@"enabled"] boolValue];
            NSString *title = valid ? (enabled ? @"Bloqueio  ·  Ligado" : @"Bloqueio  ·  Desligado") : @"DNS indisponível";
            [self.filterButton setTitle:title forState:UIControlStateNormal];
            self.filterButton.backgroundColor = Color(enabled ? 0x216453 : 0x263246);
            self.filterButton.enabled = valid;
            self.filterButton.accessibilityHint = @"Liga ou desliga o bloqueio de anúncios";
            if (changing && (error || !reply)) {
                [self message:@"DNSBlock" body:error ?: @"Não foi possível confirmar a alteração. Confira o estado do filtro."];
            }
        });
    });
}

- (void)message:(NSString *)title body:(NSString *)body
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
}

- (void)calendarChanged:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateAgenda]; });
}

- (void)updateAgenda
{
    NSString *identifier = [[NSUserDefaults standardUserDefaults] stringForKey:CalendarPreference];
    EKCalendar *selected = identifier ? [self.eventStore calendarWithIdentifier:identifier] : nil;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDate *now = [NSDate date];
    NSDate *monthStart = nil;
    NSTimeInterval monthLength = 0;
    if (![calendar rangeOfUnit:NSCalendarUnitMonth startDate:&monthStart interval:&monthLength forDate:now]) return;
    NSDate *monthEnd = [monthStart dateByAddingTimeInterval:monthLength];
    self.agendaHeading.text = [[[self formatter:@"MMMM 'de' yyyy"] stringFromDate:now] uppercaseString];

    NSArray *events = @[];
    if (selected) {
        NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:monthStart endDate:monthEnd calendars:@[selected]];
        events = [[self.eventStore eventsMatchingPredicate:predicate]
            sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"startDate" ascending:YES]]];
    }
    NSRange days = [calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:monthStart];
    NSInteger offset = [calendar component:NSCalendarUnitWeekday fromDate:monthStart] - 1;
    NSInteger today = [calendar component:NSCalendarUnitDay fromDate:now];

    for (NSInteger index = 0; index < 42; index++) {
        UILabel *cell = self.calendarCells[index + 7];
        NSInteger day = index - offset + 1;
        cell.text = nil;
        cell.backgroundColor = [UIColor clearColor];
        cell.accessibilityLabel = nil;
        if (day < 1 || day > (NSInteger)days.length) continue;
        NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:day - 1 toDate:monthStart options:0];
        NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:start options:0];
        BOOL hasEvent = NO;
        BOOL commemorative = NO;
        for (EKEvent *event in events) {
            if ([event.startDate compare:end] != NSOrderedAscending) break;
            if ([event.endDate compare:start] != NSOrderedDescending &&
                [event.startDate compare:start] == NSOrderedAscending) continue;
            hasEvent = YES;
            commemorative |= event.allDay;
        }
        cell.text = [NSString stringWithFormat:@"%ld", (long)day];
        cell.textColor = Color(day == today ? 0xffffff : (commemorative ? 0x9adfce : 0xe9f1ff));
        cell.backgroundColor = day == today ? Color(0x236c60) :
            (hasEvent ? Color(commemorative ? 0x1e4a45 : 0x2c4260) : [UIColor clearColor]);
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@%@%@", cell.text,
            day == today ? @", hoje" : @"", commemorative ? @", data comemorativa" : (hasEvent ? @", evento" : @"")];
    }

    NSMutableArray *special = [NSMutableArray array];
    NSMutableArray *other = [NSMutableArray array];
    NSDateFormatter *dayFormat = [self formatter:@"dd/MM"];
    for (EKEvent *event in events) {
        NSDate *date = [event.startDate compare:monthStart] == NSOrderedAscending ? monthStart : event.startDate;
        NSString *title = [[event.title componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
        NSString *day = [(event.allDay ? dayFormat : self.eventFormat) stringFromDate:date];
        [(event.allDay ? special : other) addObject:[NSString stringWithFormat:@"%@  ·  %@", day, title.length ? title : @"Compromisso"]];
    }
    NSString *legend = selected ? (special.count ? [special componentsJoinedByString:@"\n\n"] : @"Sem datas no mês.") :
        @"Escolha um calendário em Ajustes.";
    if (other.count) legend = [legend stringByAppendingFormat:@"\n\nOUTROS EVENTOS\n%@", [other componentsJoinedByString:@"\n\n"]];
    if (![self.agenda.text isEqual:legend]) {
        self.agenda.text = legend;
        self.legendScroll.contentOffset = CGPointZero;
        [self.view setNeedsLayout];
    }
}

- (void)chooseCalendar
{
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status == EKAuthorizationStatusNotDetermined) {
        [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [self chooseCalendar];
                else [self message:@"Calendário" body:error.localizedDescription ?: @"Permita o acesso aos calendários nos Ajustes do iPad."];
            });
        }];
        return;
    }
    if (status != EKAuthorizationStatusAuthorized) {
        [self message:@"Calendário" body:@"Permita o acesso em Ajustes do iPad → Privacidade → Calendários."];
        return;
    }
    NSArray *calendars = [self.eventStore calendarsForEntityType:EKEntityTypeEvent];
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Calendário da família"
        message:calendars.count ? @"Escolha o calendário a exibir no painel." : @"Adicione um calendário nos Ajustes do iPad."
        preferredStyle:UIAlertControllerStyleAlert];
    for (EKCalendar *calendar in calendars) {
        NSString *title = [NSString stringWithFormat:@"%@ · %@", calendar.title, calendar.source.title];
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:calendar.calendarIdentifier forKey:CalendarPreference];
            [self updateAgenda];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Ocultar agenda" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:CalendarPreference];
        [self updateAgenda];
    }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSString *)photoPath:(NSString *)name
{
    NSString *library = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *folder = [library stringByAppendingPathComponent:@"com.feijaum.ipadminidnsblock.central"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    return [folder stringByAppendingPathComponent:name];
}

- (void)applyPhotoFit
{
    BOOL fill = [[NSUserDefaults standardUserDefaults] boolForKey:PhotoFillPreference];
    self.photo.contentMode = fill ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    [self.photoFitButton setTitle:(fill ? @"Preencher" : @"Ajustar") forState:UIControlStateNormal];
    self.photoFitButton.accessibilityLabel = fill ? @"Preencher, cortar as bordas" : @"Ajustar, exibir a foto inteira";
    self.photoFitButton.accessibilityHint = @"Toque para alternar o enquadramento";
}

- (void)togglePhotoFit
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:PhotoFillPreference] forKey:PhotoFillPreference];
    [self applyPhotoFit];
}

- (void)showPhoto:(UIImage *)image
{
    if (image != self.photo.image) {
        [UIView transitionWithView:self.photo duration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.55
            options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState
            animations:^{ self.photo.image = image; } completion:nil];
    }
    self.photoHint.text = self.drivePhotos.connected ? self.drivePhotos.status : @"Adicione fotos em Ajustes";
    self.photoHint.hidden = image != nil;
}

- (void)nextPhoto
{
    self.lastPhotoChange = [NSProcessInfo processInfo].systemUptime;
    UIImage *image = [self.drivePhotos nextImage];
    if (!image && self.showingDrivePhoto && self.drivePhotos.hasAlbum) return;
    self.showingDrivePhoto = image != nil;
    NSArray *photos = [[NSUserDefaults standardUserDefaults] arrayForKey:PhotosPreference];
    if (!image && photos.count) {
        self.photoIndex = self.photoIndex >= photos.count - 1 ? 0 : self.photoIndex + 1;
        image = [UIImage imageWithContentsOfFile:[self photoPath:photos[self.photoIndex]]];
    }
    [self showPhoto:image];
}

- (void)addPhoto
{
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [self message:@"Fotos" body:@"A fototeca está indisponível neste aparelho."];
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        picker.modalPresentationStyle = UIModalPresentationPopover;
        picker.popoverPresentationController.sourceView = self.settingsButton;
        picker.popoverPresentationController.sourceRect = self.settingsButton.bounds;
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    UIImage *source = info[UIImagePickerControllerOriginalImage];
    CGFloat largestSide = MAX(source.size.width, source.size.height);
    NSData *image = nil;
    if (largestSide > 0) {
        CGFloat scale = MIN(1.0, 1024.0 / largestSide);
        CGSize size = CGSizeMake(MAX(1, round(source.size.width * scale)), MAX(1, round(source.size.height * scale)));
        UIGraphicsBeginImageContextWithOptions(size, YES, 1);
        [source drawInRect:(CGRect){CGPointZero, size}];
        image = UIImageJPEGRepresentation(UIGraphicsGetImageFromCurrentImageContext(), 0.85);
        UIGraphicsEndImageContext();
    }
    NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"jpg"];
    BOOL saved = [image writeToFile:[self photoPath:name] atomically:YES];
    if (saved) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableArray *photos = [[defaults arrayForKey:PhotosPreference] mutableCopy] ?: [NSMutableArray array];
        [photos addObject:name];
        [defaults setObject:photos forKey:PhotosPreference];
        self.photoIndex = photos.count == 1 ? NSNotFound : photos.count - 2;
        [self nextPhoto];
    }
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!saved) [self message:@"Fotos" body:@"Não foi possível salvar a imagem no painel."];
    }];
}

- (void)clearPhotos
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Limpar carrossel?"
        message:@"As fotos da sua fototeca serão mantidas." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Limpar" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        for (NSString *name in [defaults arrayForKey:PhotosPreference]) {
            [[NSFileManager defaultManager] removeItemAtPath:[self photoPath:name] error:NULL];
        }
        [defaults removeObjectForKey:PhotosPreference];
        [self nextPhoto];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmLocalWeather
{
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Clima da sua região"
        message:@"A Central usa a localização apenas enquanto está aberta. Se você ativar, envia uma posição aproximada à Open-Meteo para consultar o clima, sem usar sua conta Google."
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Ativar clima" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self.weather enable];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)connectDrivePhotos
{
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Fotos do Google Drive"
        message:@"Cole o endereço /exec da sua implantação e a chave privada da pasta."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://script.google.com/…/exec";
        field.text = self.drivePhotos.endpoint;
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Chave privada";
        field.secureTextEntry = YES;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakForm = form;
    [form addAction:[UIAlertAction actionWithTitle:@"Conectar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSArray *fields = weakForm.textFields;
        if (fields.count == 2 && ![self.drivePhotos connectToURL:[fields[0] text] key:[fields[1] text]]) {
            [self message:@"Fotos do Google Drive" body:@"Use a URL HTTPS da implantação terminada em /exec e uma chave de 24 a 128 caracteres. A chave aceita letras, números, hífen e sublinhado."];
        }
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)showSettings
{
    NSString *detail = self.status ? [NSString stringWithFormat:
        @"DNS: %@\nIP: %@\nConsultas: %@  ·  Bloqueadas: %@\n\nAo desligar o filtro, o iPad continua respondendo como DNS.",
        self.serviceMessage, self.status[@"ip"], self.status[@"queries"], self.status[@"blocked"]]
        : @"Serviço DNS indisponível. Confira o Wi-Fi e se o jailbreak está ativo.";
    NSNumber *automaticDomains = self.status[@"automatic_domains"];
    if ([automaticDomains isKindOfClass:[NSNumber class]]) {
        NSString *list = automaticDomains.unsignedIntegerValue
            ? [NSString stringWithFormat:@"%@ domínios", automaticDomains] : @"aguardando a primeira atualização";
        detail = [detail stringByAppendingFormat:@"\nLista automática: %@", list];
    }
    NSNumber *webQueue = self.status[@"web_queue"];
    if ([webQueue isKindOfClass:[NSNumber class]]) {
        detail = [detail stringByAppendingString:webQueue.boolValue
            ? [NSString stringWithFormat:@"\nFila da Casa: http://%@", self.status[@"ip"]]
            : @"\nFila da Casa: página indisponível"];
    }
    detail = [detail stringByAppendingFormat:@"\n\n%@\nDados meteorológicos: Open-Meteo.", self.drivePhotos.status];
    UIAlertController *settings = [UIAlertController alertControllerWithTitle:@"Configurações" message:detail
        preferredStyle:UIAlertControllerStyleActionSheet];
    [settings addAction:[UIAlertAction actionWithTitle:@"Atualizar estado do DNS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self refreshStatus];
    }]];
    if ([self.status[@"compatibility"] isKindOfClass:[NSNumber class]]) {
        BOOL compatible = [self.status[@"compatibility"] boolValue];
        NSString *title = compatible ? @"Desativar compatibilidade DNS" : @"Ativar compatibilidade DNS";
        [settings addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self runCommand:compatible ? "standard\n" : "compat\n" changing:YES];
        }]];
    }
    if (self.weather.enabled) {
        [settings addAction:[UIAlertAction actionWithTitle:@"Atualizar clima local" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.weather enable];
        }]];
        [settings addAction:[UIAlertAction actionWithTitle:@"Desativar clima local" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.weather disable];
        }]];
    } else {
        [settings addAction:[UIAlertAction actionWithTitle:@"Ativar clima local" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self confirmLocalWeather];
        }]];
    }
    [settings addAction:[UIAlertAction actionWithTitle:@"Escolher calendário da família" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self chooseCalendar];
    }]];
    if (self.drivePhotos.connected) {
        [settings addAction:[UIAlertAction actionWithTitle:@"Atualizar fotos do Drive" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.drivePhotos refresh];
        }]];
        [settings addAction:[UIAlertAction actionWithTitle:@"Desconectar Google Drive" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.drivePhotos disconnect];
        }]];
    } else {
        [settings addAction:[UIAlertAction actionWithTitle:@"Conectar fotos do Drive" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self connectDrivePhotos];
        }]];
    }
    [settings addAction:[UIAlertAction actionWithTitle:@"Adicionar foto da fototeca" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self addPhoto];
    }]];
    if ([[NSUserDefaults standardUserDefaults] arrayForKey:PhotosPreference].count) {
        [settings addAction:[UIAlertAction actionWithTitle:@"Limpar carrossel" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self clearPhotos];
        }]];
    }
    [settings addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
    settings.popoverPresentationController.sourceView = self.settingsButton;
    settings.popoverPresentationController.sourceRect = self.settingsButton.bounds;
    [self presentViewController:settings animated:YES completion:nil];
}
@end

@interface DNSBlockApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation DNSBlockApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[HomePanel alloc] init];
    self.window.tintColor = Color(0x216453);
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DNSBlockApp class]));
    }
}
