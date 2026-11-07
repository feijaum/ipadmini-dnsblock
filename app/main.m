#import <UIKit/UIKit.h>
#import "Weather.h"
#import "DrivePhotos.h"
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

@interface HomePanel : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property(nonatomic, strong) UIView *clockCard;
@property(nonatomic, strong) UIView *agendaCard;
@property(nonatomic, strong) UIView *photoCard;
@property(nonatomic, strong) UILabel *brand;
@property(nonatomic, strong) UILabel *clock;
@property(nonatomic, strong) UILabel *date;
@property(nonatomic, strong) UILabel *weatherLabel;
@property(nonatomic, strong) LocalWeather *weather;
@property(nonatomic, strong) UILabel *agendaHeading;
@property(nonatomic, strong) UILabel *agenda;
@property(nonatomic, strong) UILabel *photoHeading;
@property(nonatomic, strong) UILabel *photoHint;
@property(nonatomic, strong) UIImageView *photo;
@property(nonatomic, strong) DrivePhotos *drivePhotos;
@property(nonatomic, strong) UIButton *filterButton;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic, strong) NSDateFormatter *clockFormat;
@property(nonatomic, strong) NSDateFormatter *dateFormat;
@property(nonatomic, strong) NSDateFormatter *eventFormat;
@property(nonatomic, strong) EKEventStore *eventStore;
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, copy) NSString *serviceMessage;
@property(nonatomic) BOOL busy;
@property(nonatomic) NSUInteger photoIndex;
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
    self.filterButton = Button(self.view, @"Bloqueio  ·  Consultando…", self, @selector(toggleFilter));
    self.filterButton.enabled = NO;
    self.settingsButton = Button(self.view, @"⚙  Ajustes", self, @selector(showSettings));
    self.settingsButton.accessibilityLabel = @"Configurações";

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
    self.agendaHeading.text = @"PRÓXIMOS COMPROMISSOS";
    self.agenda = Label(self.agendaCard, 16, @"HelveticaNeue", 0xe9f1ff);
    self.agenda.numberOfLines = 0;

    self.photoCard = Card(self.view, 0x223247);
    self.photo = [[UIImageView alloc] init];
    self.photo.contentMode = UIViewContentModeScaleAspectFill;
    self.photo.clipsToBounds = YES;
    [self.photoCard addSubview:self.photo];
    UIView *photoCaption = [[UIView alloc] init];
    photoCaption.backgroundColor = [Color(0x101722) colorWithAlphaComponent:0.8];
    [self.photoCard addSubview:photoCaption];
    self.photoHeading = Label(photoCaption, 13, @"HelveticaNeue-Medium", 0xf2f7ff);
    self.photoHeading.text = @"FOTOS DA FAMÍLIA";
    self.photoHint = Label(self.photoCard, 15, @"HelveticaNeue", 0xb5cce7);
    self.photoHint.text = @"Adicione fotos em Ajustes";
    self.photoHint.textAlignment = NSTextAlignmentCenter;
    self.photoHint.numberOfLines = 2;
    self.photoHint.adjustsFontSizeToFitWidth = YES;
    self.drivePhotos = [[DrivePhotos alloc] init];
    __weak HomePanel *panel = self;
    self.drivePhotos.didUpdate = ^{ [panel nextPhoto]; };

    self.clockFormat = [self formatter:@"HH:mm"];
    self.dateFormat = [self formatter:@"EEEE, d 'de' MMMM"];
    self.eventFormat = [self formatter:@"dd/MM 'às' HH:mm"];
    self.eventStore = [[EKEventStore alloc] init];
    self.photoIndex = NSNotFound;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
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
    self.brand.frame = CGRectMake(padding, padding, compact ? inner : inner - 320, compact ? 22 : 44);
    self.settingsButton.frame = CGRectMake(width - padding - 96, buttonY, 96, 44);
    self.filterButton.frame = CGRectMake(width - padding - 274, buttonY, 168, 44);

    CGFloat top = buttonY + 44 + gap;
    CGFloat available = height - top - padding;
    CGFloat clockHeight = floor(available * (landscape ? 0.55 : 0.43));
    self.clockCard.frame = CGRectMake(padding, top, inner, clockHeight);
    CGFloat remainder = available - clockHeight - gap;
    if (landscape) {
        CGFloat column = floor((inner - gap) / 2);
        self.agendaCard.frame = CGRectMake(padding, top + clockHeight + gap, column, remainder);
        self.photoCard.frame = CGRectMake(padding + column + gap, top + clockHeight + gap, inner - column - gap, remainder);
    } else {
        CGFloat agendaHeight = floor((remainder - gap) * 0.46);
        self.agendaCard.frame = CGRectMake(padding, top + clockHeight + gap, inner, agendaHeight);
        self.photoCard.frame = CGRectMake(padding, CGRectGetMaxY(self.agendaCard.frame) + gap, inner, remainder - agendaHeight - gap);
    }
    CGFloat clockFaceHeight = clockHeight * 0.62;
    self.clock.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:MIN(154, clockFaceHeight * 0.84)];
    self.clock.frame = CGRectMake(12, clockHeight * 0.04, inner - 24, clockFaceHeight);
    self.date.frame = CGRectMake(12, clockHeight * 0.66, inner - 24, clockHeight * 0.16);
    self.weatherLabel.frame = CGRectMake(12, clockHeight * 0.82, inner - 24, clockHeight * 0.14);
    CGFloat agendaWidth = self.agendaCard.bounds.size.width;
    CGFloat agendaHeight = self.agendaCard.bounds.size.height;
    self.agendaHeading.frame = CGRectMake(16, 10, agendaWidth - 32, 20);
    self.agenda.frame = CGRectMake(16, 31, agendaWidth - 32, MAX(0, agendaHeight - 38));
    self.photo.frame = self.photoCard.bounds;
    CGFloat photoWidth = self.photoCard.bounds.size.width;
    CGFloat photoHeight = self.photoCard.bounds.size.height;
    self.photoHeading.superview.frame = CGRectMake(0, 0, photoWidth, 36);
    self.photoHeading.frame = CGRectMake(16, 0, photoWidth - 32, 36);
    self.photoHint.frame = CGRectMake(8, 36, photoWidth - 16, MAX(0, photoHeight - 36));
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
    [self updateClock];
    [self refreshStatus];
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
    NSInteger seconds = (NSInteger)[NSDate date].timeIntervalSince1970;
    if (seconds % 12 == 0) [self nextPhoto];
    if (seconds % 60 == 0) {
        [self refreshStatus];
        [self updateAgenda];
    }
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
    EKCalendar *calendar = identifier ? [self.eventStore calendarWithIdentifier:identifier] : nil;
    if (!calendar) {
        self.agenda.text = @"Escolha um calendário em Ajustes.";
        return;
    }
    NSDate *now = [NSDate date];
    NSDate *end = [now dateByAddingTimeInterval:30 * 24 * 60 * 60];
    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:now endDate:end calendars:@[calendar]];
    NSArray *events = [[self.eventStore eventsMatchingPredicate:predicate]
        sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"startDate" ascending:YES]]];
    NSMutableArray *lines = [NSMutableArray array];
    for (EKEvent *event in events) {
        if (lines.count == 3) break;
        NSString *day = [self.eventFormat stringFromDate:event.startDate];
        if (event.allDay) day = [day componentsSeparatedByString:@" "].firstObject;
        NSString *title = [[event.title componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
        [lines addObject:[NSString stringWithFormat:@"%@  ·  %@", day, title ?: @"Compromisso"]];
    }
    self.agenda.text = lines.count ? [lines componentsJoinedByString:@"\n\n"] : @"Sem compromissos nos próximos 30 dias.";
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

- (void)nextPhoto
{
    NSArray *photos = [[NSUserDefaults standardUserDefaults] arrayForKey:PhotosPreference];
    self.photo.image = [self.drivePhotos nextImage];
    self.photoHint.text = self.drivePhotos.connected ? self.drivePhotos.status : @"Adicione fotos em Ajustes";
    if (!self.photo.image && photos.count) {
        self.photoIndex = self.photoIndex >= photos.count - 1 ? 0 : self.photoIndex + 1;
        self.photo.image = [UIImage imageWithContentsOfFile:[self photoPath:photos[self.photoIndex]]];
    }
    self.photoHint.hidden = self.photo.image != nil;
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
