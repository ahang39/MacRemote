/* MacRemote: native FreeRDP Shadow host.
 * Authentication: macOS account via upstream PAM over TLS (not NLA/SAM).
 */
#include <freerdp/freerdp.h>
#include <freerdp/server/shadow.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <CoreGraphics/CoreGraphics.h>
#include <freerdp/input.h>
#include <pthread.h>
#include "input/karabiner_compat.h"
#include "input/mac_clipboard.h"
#include "graphics/rdp_graphics.h"

#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;
static void stop_signal(int signum) { (void)signum; stop_requested = 1; }

static void usage(FILE *out)
{
    fputs("MacRemote — FreeRDP macOS server\n"
          "  macremote serve [--port 3389] [--bind IP] [--gfx avc444|h264|balanced|classic]\n"
          "  macremote status [--json]\n"
          "  macremote doctor\n"
          "  macremote version\n"
          "\n"
          "Log in using the account name and password of the Mac user running the server.\n"
          "Default: all interfaces, port 3389, TLS + macOS PAM, full keyboard/mouse.\n"
          "Use --bind 127.0.0.1 for local-only testing; --port PORT to override.\n"
          "Default graphics: Classic. Other --gfx values are experimental.\n", out);
}


/* FreeRDP's native macOS backend builds the original CGEvents and keeps the
 * RDP-to-Apple scan-code mapping. Only the final event is transformed here.
 * The callback runs in MacRemote's own RDP process; no Karabiner process,
 * driver, helper application, or additional service is required. */
extern void mac_shadow_set_input_filter(CGEventRef (*filter)(CGEventRef));
extern int ShadowSubsystemEntry(RDP_SHADOW_ENTRY_POINTS *entryPoints);
extern void shadow_channels_set_clipboard_hooks(UINT (*on_connect)(rdpShadowClient*),
                                                 void (*on_disconnect)(rdpShadowClient*));


static struct {
    pfnShadowKeyboardEvent keyboard;
    pfnShadowUnicodeKeyboardEvent unicode;
    pfnShadowMouseEvent mouse;
    pfnShadowExtendedMouseEvent extended_mouse;
    pfnShadowClientDisconnect disconnect;
} macremote_input_original;

static BOOL macremote_keyboard(rdpShadowSubsystem *s, rdpShadowClient *c,
                               UINT16 flags, UINT8 code)
{
    mr_compat_set_client(c);
    BOOL result = macremote_input_original.keyboard(s, c, flags, code);
    mr_compat_set_client(NULL);
    return result;
}

static BOOL macremote_unicode(rdpShadowSubsystem *s, rdpShadowClient *c,
                              UINT16 flags, UINT16 code)
{
    mr_compat_set_client(c);
    mr_compat_set_unicode_input(true);
    BOOL result = macremote_input_original.unicode(s, c, flags, code);
    mr_compat_set_unicode_input(false);
    mr_compat_set_client(NULL);
    return result;
}

static BOOL macremote_mouse(rdpShadowSubsystem *s, rdpShadowClient *c,
                            UINT16 flags, UINT16 x, UINT16 y)
{
    mr_compat_set_client(c);
    BOOL result = macremote_input_original.mouse(s, c, flags, x, y);
    mr_compat_set_client(NULL);
    return result;
}

static BOOL macremote_extended_mouse(rdpShadowSubsystem *s, rdpShadowClient *c,
                                     UINT16 flags, UINT16 x, UINT16 y)
{
    mr_compat_set_client(c);
    BOOL result = macremote_input_original.extended_mouse(s, c, flags, x, y);
    mr_compat_set_client(NULL);
    return result;
}

static void macremote_disconnect(rdpShadowSubsystem *s, rdpShadowClient *c)
{
    mr_compat_client_disconnected(c);
    if (macremote_input_original.disconnect)
        macremote_input_original.disconnect(s, c);
}

static bool macremote_input_attach(rdpShadowServer *server)
{
    if (!server || !server->subsystem || !server->subsystem->KeyboardEvent ||
        !server->subsystem->UnicodeKeyboardEvent || !server->subsystem->MouseEvent ||
        !server->subsystem->ExtendedMouseEvent)
        return false;
    mr_compat_initialize(NULL);
    macremote_input_original.keyboard = server->subsystem->KeyboardEvent;
    macremote_input_original.unicode = server->subsystem->UnicodeKeyboardEvent;
    macremote_input_original.mouse = server->subsystem->MouseEvent;
    macremote_input_original.extended_mouse = server->subsystem->ExtendedMouseEvent;
    macremote_input_original.disconnect = server->subsystem->ClientDisconnect;

    server->subsystem->KeyboardEvent = macremote_keyboard;
    server->subsystem->UnicodeKeyboardEvent = macremote_unicode;
    server->subsystem->MouseEvent = macremote_mouse;
    server->subsystem->ExtendedMouseEvent = macremote_extended_mouse;
    server->subsystem->ClientDisconnect = macremote_disconnect;
    mac_shadow_set_input_filter(mr_compat_filter_event);
    return true;
}

static bool parse_port(const char *text, uint16_t *port)
{
    char *end = NULL;
    if (!text || !*text || *text == '-') return false;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !end || *end || value < 1 || value > UINT16_MAX)
        return false;
    *port = (uint16_t)value;
    return true;
}

/* An IP literal, not command-line syntax or a comma-separated FreeRDP field. */
static bool valid_bind_address(const char *address)
{
    unsigned char storage[16];
    return address && *address &&
           (inet_pton(AF_INET, address, storage) == 1 ||
            inet_pton(AF_INET6, address, storage) == 1);
}

static const char *account_name(void)
{
    const struct passwd *account = getpwuid(getuid());
    return account && account->pw_name ? account->pw_name : "unknown";
}

static bool make_dir(const char *path, mode_t mode)
{
    struct stat info;
    if (mkdir(path, mode) != 0 && errno != EEXIST)
        return false;
    return stat(path, &info) == 0 && S_ISDIR(info.st_mode);
}

/* MacRemote-owned configuration, isolated from FreeRDP's global paths. */
static char *config_path(void)
{
    const char *home = getenv("HOME");
    char path[PATH_MAX];
    if (!home || home[0] != '/')
        return NULL;
    if (snprintf(path, sizeof(path), "%s/Library", home) >= (int)sizeof(path) ||
        !make_dir(path, 0755))
        return NULL;
    if (snprintf(path, sizeof(path), "%s/Library/Application Support", home) >=
            (int)sizeof(path) || !make_dir(path, 0755))
        return NULL;
    if (snprintf(path, sizeof(path), "%s/Library/Application Support/MacRemote", home) >=
            (int)sizeof(path) || !make_dir(path, 0700))
        return NULL;
    return strdup(path);
}


static void status(bool json)
{
    const bool capture = CGPreflightScreenCaptureAccess();
    if (json)
    {
        printf("{\"version\":\"%s\",\"account\":\"%s\","
               "\"screen_capture_granted\":%s,"
               "\"default_bind\":\"0.0.0.0\",\"default_port\":3389,"
               "\"authentication\":\"macOS PAM over TLS\","
               "\"input\":\"enabled\",\"max_clients\":null}\n",
               freerdp_get_version_string(), account_name(),
               capture ? "true" : "false");
    }
    else
    {
        printf("MacRemote / FreeRDP %s\n", freerdp_get_version_string());
        printf("Mac login account: %s (existing macOS password)\n", account_name());
        printf("Screen recording: %s\n", capture ? "granted" : "permission needed");
        puts("Default: all interfaces :3389; TLS + PAM; keyboard/mouse enabled");
        puts("Client limit: FreeRDP default (no artificial MacRemote limit)");
        puts("Negotiated codec, bitrate and RTT: N/A until telemetry is implemented");
        puts("Keyboard: built-in Karabiner basic-rule compatibility; Quartz passthrough without config");
        puts("Unicode/IME text input bypasses physical-key remapping");
    }
}

static int serve(uint16_t port, const char *bind_address, MRGraphicsMode graphics)
{
    /* Register the statically linked native macOS Shadow backend directly:
     * avoids loading it a second time from the subsystem dylib. */
    shadow_subsystem_set_entry(ShadowSubsystemEntry);
    shadow_channels_set_clipboard_hooks(mr_clipboard_client_connect,
                                         mr_clipboard_client_disconnect);
    rdpShadowServer *server = shadow_server_new();
    if (!server) return 1;

    bool initialized = false;
    int result = 1;
    server->port = port;
    server->authentication = TRUE;
    server->mayView = TRUE;
    server->mayInteract = TRUE;
    server->maxClientsConnected = 0; /* No artificial product cap. */
    server->ConfigPath = config_path();

    if (bind_address)
    {
        size_t length = strlen(bind_address) + sizeof("bind-address,");
        server->ipcSocket = malloc(length);
        if (server->ipcSocket)
            snprintf(server->ipcSocket, length, "bind-address,%s", bind_address);
    }
    /* A null bind address intentionally uses FreeRDP's all-interface listener. */
    if (!server->ConfigPath ||
        (bind_address && !server->ipcSocket) ||
        !mr_gfx_configure(server->settings, graphics))
    {
        fputs("error: FreeRDP configuration failed\n", stderr);
        goto cleanup;
    }
    if (shadow_server_init(server) < 0)
    {
        fputs("error: FreeRDP Shadow initialization failed\n", stderr);
        goto cleanup;
    }
    initialized = true;
    if (!macremote_input_attach(server)) {
        fputs("error: MacRemote keyboard bridge initialization failed\n", stderr);
        goto cleanup;
    }
    if (shadow_server_start(server) < 0)
    {
        fputs("error: FreeRDP listener failed (port in use or missing permissions)\n",
              stderr);
        goto cleanup;
    }

    printf("MacRemote listening on %s:%u | TLS + macOS PAM | keyboard/mouse enabled\n",
           bind_address ? bind_address : "all interfaces", (unsigned)port);
    printf("Graphics: %s | Client limit: upstream default | Codec/bitrate/RTT: N/A\n",
           mr_gfx_label(graphics));
    char input_status[256];
    mr_compat_status(input_status, sizeof(input_status));
    printf("Input: native Quartz + built-in rule compatibility | %s\n", input_status);
    fflush(stdout);

    while (!stop_requested) Sleep(200);
    result = 0;

cleanup:
    if (initialized) (void)shadow_server_uninit(server);
    shadow_channels_set_clipboard_hooks(NULL, NULL);
    mr_clipboard_shutdown();
    mac_shadow_set_input_filter(NULL);
    mr_compat_shutdown();
    shadow_server_free(server);
    return result;
}

/* FreeRDP/WinPR loads OpenSSL 4's legacy provider with dlopen.
 * Resolve it exclusively from this .app bundle rather than Homebrew. */
static void macremote_use_bundled_openssl(void)
{
    char raw[PATH_MAX], resolved[PATH_MAX], modules[PATH_MAX], legacy[PATH_MAX];
    uint32_t n=(uint32_t)sizeof(raw);
    if (_NSGetExecutablePath(raw,&n)!=0 || !realpath(raw,resolved)) return;
    char *slash=strrchr(resolved,'/');
    if (!slash) return;
    *slash='\0';
    int len=snprintf(modules,sizeof(modules),"%s/../Frameworks/ossl-modules",resolved);
    if (len<=0 || (size_t)len>=sizeof(modules)) return;
    len=snprintf(legacy,sizeof(legacy),"%s/legacy.dylib",modules);
    if (len<=0 || (size_t)len>=sizeof(legacy)) return;
    if (access(legacy,R_OK)==0)
        (void)setenv("OPENSSL_MODULES",modules,1);
}

int main(int argc, char **argv)
{
    macremote_use_bundled_openssl();
    uint16_t port = 3389;
    const char *bind_address = NULL;
    MRGraphicsMode graphics = MR_GFX_CLASSIC;
    if (argc == 2 && !strcmp(argv[1], "version"))
    {
        printf("MacRemote / FreeRDP %s\n", freerdp_get_version_string());
        return 0;
    }
    if (argc >= 2 && (!strcmp(argv[1], "status") || !strcmp(argv[1], "doctor")))
    {
        bool json = argc == 3 && !strcmp(argv[1], "status") &&
                    !strcmp(argv[2], "--json");
        if (argc != 2 && !json) return 2;
        status(json);
        return 0;
    }
    if (argc < 2 || strcmp(argv[1], "serve"))
    {
        bool help = argc == 2 &&
                    (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"));
        usage(help ? stdout : stderr);
        return help ? 0 : 2;
    }
    for (int i = 2; i < argc; i++)
    {
        if (!strcmp(argv[i], "--port") && i + 1 < argc)
        {
            if (!parse_port(argv[++i], &port))
            {
                fputs("error: port must be 1..65535\n", stderr);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--bind") && i + 1 < argc)
        {
            bind_address = argv[++i];
            if (!valid_bind_address(bind_address))
            {
                fputs("error: --bind requires an IPv4 or IPv6 address\n", stderr);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--compat-graphics"))
            graphics = MR_GFX_CLASSIC; /* backward-compatible CLI alias */
        else if (!strcmp(argv[i], "--gfx") && i + 1 < argc) {
            const char *profile = argv[++i];
            if (!mr_gfx_parse(profile, &graphics)) {
                fputs("error: --gfx expects avc444, h264, balanced or classic\n", stderr);
                return 2;
            }
        }
        else
        {
            fputs("error: unrecognized serve option\n", stderr);
            return 2;
        }
    }
    if (signal(SIGINT, stop_signal) == SIG_ERR ||
        signal(SIGTERM, stop_signal) == SIG_ERR) return 1;
    return serve(port, bind_address, graphics);
}
