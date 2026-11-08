#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _DEFAULT_SOURCE
#endif

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum { DNS_HEADER = 12, MAX_DNS = 65535, NAME_SIZE = 254, IO_MS = 1800 };
enum { NXDOMAIN = 3, SERVFAIL = 2, REFUSED = 5 };

struct question {
    char name[NAME_SIZE];
    size_t end;
    uint16_t type;
    uint16_t klass;
    bool filterable;
};

struct blocklist {
    char **domains;
    size_t count;
};

enum { MAX_DOMAINS = 200000, MAX_BLOCKLIST_BYTES = 8 * 1024 * 1024 };

static struct {
    struct sockaddr_in upstream;
    struct in_addr lan;
    struct in_addr mask;
    struct blocklist local, automatic;
    const char *state_path;
    bool enabled;
    bool compatibility;
    unsigned long long queries;
    unsigned long long blocked;
    pthread_mutex_t lock;
} server = { .lock = PTHREAD_MUTEX_INITIALIZER, .enabled = true };

static void fatal(const char *message)
{
    perror(message);
    exit(EXIT_FAILURE);
}

static uint16_t number(const uint8_t *bytes)
{
    return (uint16_t)((bytes[0] << 8) | bytes[1]);
}

/* A standard one-question message encodes its first QNAME without pointers. */
static bool question_at(const uint8_t *packet, size_t size, struct question *out)
{
    if (size < DNS_HEADER || number(packet + 4) != 1)
        return false;
    size_t pos = DNS_HEADER;
    size_t len = 0;
    out->filterable = true;
    while (pos < size) {
        unsigned label = packet[pos++];
        if (label == 0) {
            if (pos + 4 > size)
                return false;
            out->name[len] = '\0';
            out->end = pos + 4;
            out->type = number(packet + pos);
            out->klass = number(packet + pos + 2);
            return true;
        }
        if (label > 63 || pos + label > size || len + label + (len != 0) >= NAME_SIZE)
            return false;
        if (len)
            out->name[len++] = '.';
        for (unsigned i = 0; i < label; i++) {
            unsigned ch = packet[pos++];
            if (!isalnum(ch) && ch != '-' && ch != '_')
                out->filterable = false;
            out->name[len++] = (char)(out->filterable ? tolower(ch) : '?');
        }
    }
    return false;
}

static int compare_names(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void free_blocklist(struct blocklist *list)
{
    for (size_t i = 0; i < list->count; i++)
        free(list->domains[i]);
    free(list->domains);
    *list = (struct blocklist){0};
}

static bool load_blocklist(const char *path, struct blocklist *list, bool downloaded)
{
    FILE *file = fopen(path, "r");
    if (!file)
        return false;
    struct stat info;
    char line[512];
    size_t capacity = 0, expected = 0;
    bool loaded = false;
    if (downloaded && (fstat(fileno(file), &info) || !S_ISREG(info.st_mode) ||
                       info.st_size > MAX_BLOCKLIST_BYTES))
        goto done;

    while (fgets(line, sizeof(line), file)) {
        const char *newline = strchr(line, '\n');
        if (!newline && (downloaded || !feof(file))) {
            if (downloaded)
                goto done;
            int ch;
            while ((ch = fgetc(file)) != '\n' && ch != EOF) {}
            continue;
        }
        /* The publisher includes its entry count so partial downloads can be rejected. */
        const char prefix[] = "# Number of entries: ";
        if (downloaded && !strncmp(line, prefix, sizeof(prefix) - 1)) {
            char *end;
            unsigned long count = strtoul(line + sizeof(prefix) - 1, &end, 10);
            if (expected || count < 1000 || count > MAX_DOMAINS ||
                (end != newline && !(end + 1 == newline && *end == '\r')))
                goto done;
            expected = (size_t)count;
        }

        size_t len = strcspn(line, "#\r\n");
        while (len && isspace((unsigned char)line[len - 1]))
            len--;
        size_t start = strspn(line, " \t");
        if (len <= start || len - start >= NAME_SIZE)
            continue;
        if (line[len - 1] == '.')
            len--;
        if (len <= start)
            continue;
        line[len] = '\0';
        bool valid = true;
        size_t label = 0;
        for (size_t i = start; i < len; i++) {
            unsigned ch = (unsigned char)line[i];
            if (ch == '.') {
                if (label == 0 || label > 63)
                    valid = false;
                label = 0;
                continue;
            }
            if (!isalnum(ch) && ch != '-' && ch != '_')
                valid = false;
            line[i] = (char)tolower(ch);
            label++;
        }
        if (!valid || label == 0 || label > 63 || (downloaded && !strchr(line + start, '.'))) {
            if (downloaded)
                goto done;
            continue;
        }
        if (list->count == MAX_DOMAINS)
            goto done;
        if (list->count == capacity) {
            capacity = capacity ? capacity * 2 : 128;
            char **domains = realloc(list->domains, capacity * sizeof(*domains));
            if (!domains)
                goto done;
            list->domains = domains;
        }
        list->domains[list->count] = strdup(line + start);
        if (!list->domains[list->count])
            goto done;
        list->count++;
    }
    loaded = !ferror(file) && (!downloaded || (expected && list->count == expected));
done:
    fclose(file);
    if (!loaded)
        free_blocklist(list);
    else if (list->count)
        qsort(list->domains, list->count, sizeof(*list->domains), compare_names);
    return loaded;
}

static bool matches_blocklist(const struct blocklist *list, const char *name)
{
    while (list->count) {
        if (bsearch(&name, list->domains, list->count, sizeof(*list->domains), compare_names))
            return true;
        const char *dot = strchr(name, '.');
        if (!dot)
            break;
        name = dot + 1;
    }
    return false;
}

#ifdef DNSBLOCK_IOS
bool download_blocklist(const char *path, size_t max_bytes);

static bool update_blocklist(const char *path)
{
    char pending[strlen(path) + sizeof(".new")];
    snprintf(pending, sizeof(pending), "%s.new", path);
    unlink(pending);
    int fd = open(pending, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0)
        return false;
    close(fd);

    struct blocklist next = {0};
    if (!download_blocklist(pending, MAX_BLOCKLIST_BYTES) ||
        !load_blocklist(pending, &next, true) || rename(pending, path)) {
        free_blocklist(&next);
        unlink(pending);
        return false;
    }

    pthread_mutex_lock(&server.lock);
    struct blocklist previous = server.automatic;
    server.automatic = next;
    pthread_mutex_unlock(&server.lock);
    free_blocklist(&previous);
    return true;
}

static void *refresh_blocklist(void *argument)
{
    const char *path = argument;
    enum { REFRESH_SECONDS = 24 * 60 * 60, RETRY_SECONDS = 60 * 60 };
    struct stat info;
    double age = server.automatic.count && !stat(path, &info)
        ? difftime(time(NULL), info.st_mtime) : REFRESH_SECONDS;
    if (age >= 0 && age < REFRESH_SECONDS)
        sleep(REFRESH_SECONDS - (unsigned)age);
    while (true) {
        bool updated = update_blocklist(path);
        if (!updated)
            fprintf(stderr, "Falha ao atualizar a lista automática de DNS.\n");
        sleep(updated ? REFRESH_SECONDS : RETRY_SECONDS);
    }
    return NULL;
}
#endif

static int64_t now_ms(void)
{
    /* gettimeofday is available on iOS 8. poll bounds each socket operation. */
    struct timeval time;
    gettimeofday(&time, NULL);
    return (int64_t)time.tv_sec * 1000 + time.tv_usec / 1000;
}

static bool ready(int fd, short events, int64_t deadline)
{
    struct pollfd socket = { .fd = fd, .events = events };
    while (true) {
        int64_t left = deadline - now_ms();
        if (left <= 0)
            return false;
        int result = poll(&socket, 1, left > IO_MS ? IO_MS : (int)left);
        if (result < 0 && errno == EINTR)
            continue;
        return result > 0 && (socket.revents & events) != 0;
    }
}

static bool transfer(int fd, void *data, size_t size, bool writing, int64_t deadline)
{
    uint8_t *bytes = data;
    while (size && ready(fd, writing ? POLLOUT : POLLIN, deadline)) {
        ssize_t count = writing ? send(fd, bytes, size, 0) : recv(fd, bytes, size, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
            continue;
        if (count <= 0)
            return false;
        bytes += count;
        size -= (size_t)count;
    }
    return size == 0;
}

static bool nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags != -1 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
}

static size_t read_frame(int fd, uint8_t *packet, int64_t deadline)
{
    uint8_t prefix[2];
    if (!transfer(fd, prefix, sizeof(prefix), false, deadline))
        return 0;
    size_t length = number(prefix);
    return length && transfer(fd, packet, length, false, deadline) ? length : 0;
}

static bool write_frame(int fd, uint8_t *packet, size_t length, int64_t deadline)
{
    uint8_t prefix[2] = { (uint8_t)(length >> 8), (uint8_t)length };
    return transfer(fd, prefix, sizeof(prefix), true, deadline)
        && transfer(fd, packet, length, true, deadline);
}

static size_t forward(uint8_t *query, size_t size, uint8_t *answer, bool tcp)
{
    int fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0);
    if (fd < 0)
        return 0;
    size_t length = 0;
    int64_t deadline = now_ms() + IO_MS;
    if (!nonblocking(fd))
        goto done;
    if (connect(fd, (struct sockaddr *)&server.upstream, sizeof(server.upstream)) < 0) {
        int error = 0;
        socklen_t error_size = sizeof(error);
        if (errno != EINPROGRESS || !ready(fd, POLLOUT, deadline)
            || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) || error)
            goto done;
    }
    if (tcp) {
        if (write_frame(fd, query, size, deadline))
            length = read_frame(fd, answer, deadline);
    } else if (send(fd, query, size, 0) == (ssize_t)size && ready(fd, POLLIN, deadline)) {
        ssize_t received = recv(fd, answer, MAX_DNS, 0);
        if (received > 0)
            length = (size_t)received;
    }

done:
    close(fd);
    return length;
}

static size_t error_response(const uint8_t *query, const struct question *question,
                             uint8_t *answer, unsigned code)
{
    size_t length = question ? question->end : DNS_HEADER;
    memcpy(answer, query, length);
    answer[2] = (uint8_t)((query[2] & 0x79) | 0x80);
    answer[3] = (uint8_t)((query[3] & 0x10) | 0x80 | code);
    memset(answer + 4, 0, 8);
    answer[5] = question ? 1 : 0;
    return length;
}

static size_t blocked_response(uint8_t *query, const struct question *question,
                               uint8_t *answer, bool compatibility)
{
    size_t length = error_response(query, question, answer, compatibility ? 0 : NXDOMAIN);
    if (!compatibility || (question->type != 1 && question->type != 28))
        return length;

    /* NOERROR with a zero address, without contacting the upstream resolver.
       Other record types return NOERROR with no answer. */
    const uint8_t address_length = question->type == 1 ? 4 : 16;
    const uint8_t record[] = {
        0xc0, DNS_HEADER,                     /* Name points at the question. */
        0, (uint8_t)question->type, 0, 1,      /* A or AAAA, class IN. */
        0, 0, 0, 0,                           /* TTL 0 for quick mode changes. */
        0, address_length
    };
    answer[7] = 1;
    memcpy(answer + length, record, sizeof(record));
    memset(answer + length + sizeof(record), 0, address_length);
    return length + sizeof(record) + address_length;
}

static size_t resolve(uint8_t *query, size_t size, uint8_t *answer, bool tcp)
{
    struct question question;
    if (size < DNS_HEADER || (query[2] & 0x80))
        return 0;
    if (!question_at(query, size, &question))
        return error_response(query, NULL, answer, 1);
    if ((query[2] & 0x78) || question.klass != 1)
        return error_response(query, &question, answer, REFUSED);

    pthread_mutex_lock(&server.lock);
    server.queries++;
    bool block = server.enabled && question.filterable &&
        (matches_blocklist(&server.local, question.name) ||
         matches_blocklist(&server.automatic, question.name));
    bool compatibility = server.compatibility;
    if (block)
        server.blocked++;
    pthread_mutex_unlock(&server.lock);
    if (block)
        return blocked_response(query, &question, answer, compatibility);

    size_t length = forward(query, size, answer, tcp);
    struct question echoed;
    if (length >= DNS_HEADER && (answer[2] & 0x80) && number(query) == number(answer)
        && (answer[2] & 0x78) == (query[2] & 0x78)
        && question_at(answer, length, &echoed) && question.end == echoed.end
        && question.type == echoed.type && question.klass == echoed.klass
        && ((question.filterable && echoed.filterable && !strcmp(question.name, echoed.name))
            || !memcmp(query + DNS_HEADER, answer + DNS_HEADER, question.end - DNS_HEADER)))
        return length;
    return error_response(query, &question, answer, SERVFAIL);
}

static bool same_lan(struct in_addr address)
{
    return (address.s_addr & server.mask.s_addr) == (server.lan.s_addr & server.mask.s_addr);
}

static void *udp_loop(void *argument)
{
    int fd = *(int *)argument;
    uint8_t query[MAX_DNS], answer[MAX_DNS];
    while (true) {
        struct sockaddr_in peer;
        socklen_t size = sizeof(peer);
        ssize_t count = recvfrom(fd, query, sizeof(query), 0, (struct sockaddr *)&peer, &size);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            fatal("recvfrom");
        }
        if (!same_lan(peer.sin_addr))
            continue;
        size_t length = resolve(query, (size_t)count, answer, false);
        if (length)
            (void)sendto(fd, answer, length, 0, (struct sockaddr *)&peer, size);
    }
    return NULL;
}

static int accept_peer(int fd, bool lan)
{
    while (true) {
        struct sockaddr_in peer;
        socklen_t length = sizeof(peer);
        int client = accept(fd, (struct sockaddr *)&peer, &length);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            fatal("accept");
        }
        if ((!lan || same_lan(peer.sin_addr)) && nonblocking(client))
            return client;
        close(client);
    }
}

static void *tcp_loop(void *argument)
{
    int fd = *(int *)argument;
    uint8_t query[MAX_DNS], answer[MAX_DNS];
    while (true) {
        int client = accept_peer(fd, true);
        /* Bound the time a single connection can occupy the TCP worker. */
        int64_t deadline = now_ms() + 5000;
        while (true) {
            size_t count = read_frame(client, query, deadline);
            if (!count)
                break;
            size_t length = resolve(query, count, answer, true);
            if (!length || !write_frame(client, answer, length, deadline))
                break;
        }
        close(client);
    }
    return NULL;
}

static bool store_state(bool enabled, bool compatibility)
{
    char temporary[1024];
    int length = snprintf(temporary, sizeof(temporary), "%s.XXXXXX", server.state_path);
    if (length < 0 || (size_t)length >= sizeof(temporary))
        return false;
    int file = mkstemp(temporary);
    if (file < 0)
        return false;
    const char state[] = { enabled ? '1' : '0', '\n', compatibility ? '1' : '0', '\n' };
    bool saved = write(file, state, sizeof(state)) == sizeof(state) && fsync(file) == 0;
    if (close(file) || !saved || rename(temporary, server.state_path)) {
        unlink(temporary);
        return false;
    }
    return true;
}

static void *control_loop(void *argument)
{
    int fd = *(int *)argument;
    while (true) {
        int client = accept_peer(fd, false);
        char command[16] = { 0 };
        size_t len = 0;
        int64_t deadline = now_ms() + IO_MS;
        while (len < sizeof(command) - 1 && transfer(client, command + len, 1, false, deadline))
            if (command[len++] == '\n')
                break;

        bool enable = len == 7 && !memcmp(command, "enable\n", len);
        bool disable = len == 8 && !memcmp(command, "disable\n", len);
        bool compatible = len == 7 && !memcmp(command, "compat\n", len);
        bool standard = len == 9 && !memcmp(command, "standard\n", len);
        bool changing = enable || disable || compatible || standard;
        char response[256] = "{\"error\":\"comando inválido\"}\n";
        if (changing || (len == 7 && !memcmp(command, "status\n", len))) {
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &server.lan, ip, sizeof(ip));
            /* Only this worker modifies the on-disk preference. */
            bool enabled = enable || (!disable && server.enabled);
            bool compatibility = compatible || (!standard && server.compatibility);
            bool saved = !changing || store_state(enabled, compatibility);
            pthread_mutex_lock(&server.lock);
            if (saved && changing) {
                server.enabled = enabled;
                server.compatibility = compatibility;
            }
            if (saved)
                snprintf(response, sizeof(response),
                         "{\"enabled\":%s,\"compatibility\":%s,\"queries\":%llu,\"blocked\":%llu,\"automatic_domains\":%zu,\"ip\":\"%s\"}\n",
                         server.enabled ? "true" : "false", server.compatibility ? "true" : "false",
                         server.queries, server.blocked, server.automatic.count, ip);
            else
                snprintf(response, sizeof(response), "{\"error\":\"falha ao salvar a preferência\"}\n");
            pthread_mutex_unlock(&server.lock);
        }
        (void)transfer(client, response, strlen(response), true, deadline);
        close(client);
    }
    return NULL;
}

static bool interface_address(const char *interface, struct in_addr *ip, struct in_addr *mask)
{
    struct ifaddrs *interfaces;
    if (getifaddrs(&interfaces))
        return false;
    bool found = false;
    for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (strcmp(interface, entry->ifa_name) || !entry->ifa_addr || !entry->ifa_netmask
            || entry->ifa_addr->sa_family != AF_INET || !(entry->ifa_flags & IFF_UP))
            continue;
        *ip = ((struct sockaddr_in *)entry->ifa_addr)->sin_addr;
        *mask = ((struct sockaddr_in *)entry->ifa_netmask)->sin_addr;
        found = mask->s_addr != 0 && ip->s_addr != 0;
        if (found)
            break;
    }
    freeifaddrs(interfaces);
    return found;
}

static unsigned port(const char *value)
{
    char *end;
    long parsed = strtol(value, &end, 10);
    if (!*value || *end || parsed < 1 || parsed > 65535) {
        fprintf(stderr, "Porta inválida: %s\n", value);
        exit(EXIT_FAILURE);
    }
    return (unsigned)parsed;
}

static int listen_on(struct in_addr ip, unsigned port_number, int type)
{
    int fd = socket(AF_INET, type, 0);
    if (fd < 0)
        fatal("socket");
    int yes = 1;
    if (type == SOCK_STREAM && setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)))
        fatal("setsockopt");
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_addr = ip,
                                .sin_port = htons((uint16_t)port_number) };
#ifdef __APPLE__
    addr.sin_len = sizeof(addr);
#endif
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)))
        fatal("bind");
    if (type == SOCK_STREAM && listen(fd, 16))
        fatal("listen");
    return fd;
}

static void drop_privileges(const char *name)
{
    if (!name)
        return;
    struct passwd *user = getpwnam(name);
    if (!user || !user->pw_uid || !user->pw_gid) {
        fprintf(stderr, "Usuário de serviço inválido: %s\n", name);
        exit(EXIT_FAILURE);
    }
    gid_t group = user->pw_gid;
    uid_t uid = user->pw_uid;
    if (setgroups(1, &group) || setgid(group) || setuid(uid))
        fatal("drop privileges");
}

int main(int argc, char **argv)
{
    if (argc != 9 && argc != 10) {
        fprintf(stderr, "Uso: %s interface porta-dns porta-controle dns-remoto porta-remota "
                        "lista estado usuário [ip-local-para-teste]\n", argv[0]);
        return EXIT_FAILURE;
    }
    signal(SIGPIPE, SIG_IGN);
    const char *interface = argv[1];
    if (argc == 10) {
        if (inet_pton(AF_INET, argv[9], &server.lan) != 1 || !server.lan.s_addr)
            return EXIT_FAILURE;
        server.mask.s_addr = INADDR_BROADCAST;
    } else if (!interface_address(interface, &server.lan, &server.mask)) {
        fprintf(stderr, "Aguardando IPv4 em %s.\n", interface);
        return EXIT_FAILURE;
    }
    char upstream_file[64];
    const char *upstream = argv[4];
    if (upstream[0] == '@') {
        FILE *file = fopen(upstream + 1, "r");
        if (!file)
            fatal(upstream + 1);
        if (!fgets(upstream_file, sizeof(upstream_file), file)) {
            fprintf(stderr, "A configuração do DNS remoto está vazia.\n");
            return EXIT_FAILURE;
        }
        fclose(file);
        upstream_file[strcspn(upstream_file, "\r\n")] = '\0';
        upstream = upstream_file;
    }
#ifdef __APPLE__
    server.upstream.sin_len = sizeof(server.upstream);
#endif
    server.upstream.sin_family = AF_INET;
    server.upstream.sin_port = htons((uint16_t)port(argv[5]));
    if (inet_pton(AF_INET, upstream, &server.upstream.sin_addr) != 1
        || !server.upstream.sin_addr.s_addr) {
        fprintf(stderr, "Informe um endereço IPv4 válido para o DNS remoto.\n");
        return EXIT_FAILURE;
    }
    unsigned dns_port = port(argv[2]);
    if (server.upstream.sin_addr.s_addr == server.lan.s_addr && port(argv[5]) == dns_port) {
        fprintf(stderr, "O DNS remoto aponta para o próprio serviço.\n");
        return EXIT_FAILURE;
    }
    struct in_addr loopback = { .s_addr = htonl(INADDR_LOOPBACK) };
    int udp = listen_on(server.lan, dns_port, SOCK_DGRAM);
    int tcp = listen_on(server.lan, dns_port, SOCK_STREAM);
    int control = listen_on(loopback, port(argv[3]), SOCK_STREAM);
    drop_privileges(strcmp(argv[8], "-") == 0 ? NULL : argv[8]);
    if (!load_blocklist(argv[6], &server.local, false)) {
        fprintf(stderr, "Falha ao carregar a lista local: %s\n", argv[6]);
        return EXIT_FAILURE;
    }
    server.state_path = argv[7];
    char automatic_path[strlen(server.state_path) + sizeof(".blocklist")];
    snprintf(automatic_path, sizeof(automatic_path), "%s.blocklist", server.state_path);
    (void)load_blocklist(automatic_path, &server.automatic, true);
    FILE *state = fopen(server.state_path, "r");
    if (state) {
        server.enabled = fgetc(state) != '0';
        server.compatibility = fgetc(state) == '\n' && fgetc(state) == '1';
        fclose(state);
    }

    pthread_t workers[3];
    if (pthread_create(&workers[0], NULL, udp_loop, &udp)
        || pthread_create(&workers[1], NULL, tcp_loop, &tcp)
        || pthread_create(&workers[2], NULL, control_loop, &control)) {
        fprintf(stderr, "Falha ao criar as threads do serviço.\n");
        return EXIT_FAILURE;
    }
    if (argc == 10) {
        pthread_join(workers[0], NULL);
        return EXIT_FAILURE;
    }
#ifdef DNSBLOCK_IOS
    pthread_t updater;
    if (pthread_create(&updater, NULL, refresh_blocklist, automatic_path))
        fprintf(stderr, "Falha ao iniciar a atualização automática de DNS.\n");
#endif
    while (true) {
        sleep(5);
        struct in_addr ip, mask;
        if (!interface_address(interface, &ip, &mask)
            || ip.s_addr != server.lan.s_addr || mask.s_addr != server.mask.s_addr)
            return EXIT_SUCCESS; /* launchd reloads the listener on the new address. */
    }
}
