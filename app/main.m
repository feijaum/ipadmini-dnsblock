#import <UIKit/UIKit.h>
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

@interface ControlPanel : UITableViewController
@property(nonatomic, strong) UISwitch *filterSwitch;
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) BOOL busy;
@end

@implementation ControlPanel

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"DNSBlock";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                     target:self action:@selector(refresh)];
    self.filterSwitch = [[UISwitch alloc] init];
    self.filterSwitch.accessibilityLabel = @"Bloqueio de anúncios";
    [self.filterSwitch addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    self.message = @"Conectando ao serviço…";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh { [self runCommand:"status\n" refreshAfterError:NO]; }

- (void)toggle:(UISwitch *)sender
{
    [self runCommand:(sender.on ? "enable\n" : "disable\n") refreshAfterError:YES];
}

- (void)runCommand:(const char *)command refreshAfterError:(BOOL)refreshAfterError
{
    if (self.busy) return;
    self.busy = YES;
    self.filterSwitch.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *result = RequestStatus(command);
        NSString *error = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"] : nil;
        NSDictionary *status = error && refreshAfterError ? RequestStatus("status\n") : result;

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL valid = [status[@"enabled"] isKindOfClass:[NSNumber class]]
                && [status[@"ip"] isKindOfClass:[NSString class]]
                && [status[@"queries"] isKindOfClass:[NSNumber class]]
                && [status[@"blocked"] isKindOfClass:[NSNumber class]];
            self.status = valid ? status : nil;
            self.message = error ?: (valid ? @"Conectado" : @"Serviço indisponível");
            [self.filterSwitch setOn:[self.status[@"enabled"] boolValue] animated:YES];
            self.filterSwitch.enabled = valid;
            self.busy = NO;
            self.navigationItem.rightBarButtonItem.enabled = YES;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 5; }

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section
{
    return @"DNS da rede doméstica";
}

- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section
{
    if (!self.status) return @"Conecte ao Wi-Fi e confira se o pacote do serviço foi instalado e se o jailbreak está ativo.";
    return @"Use o IP acima como DNS manual em outro aparelho da mesma rede. Os contadores começam novamente quando o serviço reinicia.";
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"Status"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Status"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.detailTextLabel.text = nil;
    switch (path.row) {
        case 0: cell.textLabel.text = @"Serviço"; cell.detailTextLabel.text = self.message; break;
        case 1: cell.textLabel.text = @"Bloqueio"; cell.accessoryView = self.filterSwitch; break;
        case 2: cell.textLabel.text = @"IP para usar como DNS"; cell.detailTextLabel.text = self.status[@"ip"] ?: @"—"; break;
        case 3: cell.textLabel.text = @"Consultas recebidas"; cell.detailTextLabel.text = [self.status[@"queries"] stringValue] ?: @"—"; break;
        case 4: cell.textLabel.text = @"Consultas bloqueadas"; cell.detailTextLabel.text = [self.status[@"blocked"] stringValue] ?: @"—"; break;
    }
    return cell;
}
@end

@interface DNSBlockApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation DNSBlockApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ControlPanel *panel = [[ControlPanel alloc] initWithStyle:UITableViewStyleGrouped];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:panel];
    self.window.tintColor = [UIColor colorWithRed:0.08 green:0.42 blue:0.38 alpha:1];
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
