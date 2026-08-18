/*
 * AirPlay screen-mirroring receiver for Record iPhone.
 *
 * Built on the UxPlay protocol library (GPLv3), without GStreamer.
 * Advertises this Mac as "Record iPhone" in Control Center → Screen Mirroring.
 * Decrypted H.264 (and events) are written to stdout for the Swift app.
 *
 * stdout framing (big-endian):
 *   uint8  type   'E' event JSON, 'V' video
 *   uint32 length
 *   payload
 *     event: UTF-8 JSON object
 *     video: uint64 pts_ns, uint32 nal_count, uint8 is_h265, then raw Annex-B
 * stderr: human logs
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "dnssd.h"
#include "logger.h"
#include "raop.h"

static raop_t *g_raop = NULL;
static dnssd_t *g_dnssd = NULL;
static volatile sig_atomic_t g_stop = 0;
static pthread_mutex_t g_out_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_video_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_video_fd = -1;
static char g_sock_path[1024] = {0};
static FILE *g_log = NULL;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void emit_bytes(uint8_t type, const void *payload, uint32_t len) {
    uint32_t be = htonl(len);
    pthread_mutex_lock(&g_out_lock);
    fwrite(&type, 1, 1, stdout);
    fwrite(&be, 4, 1, stdout);
    if (len && payload) fwrite(payload, 1, len, stdout);
    fflush(stdout);
    pthread_mutex_unlock(&g_out_lock);
}

static void json_escape(const char *src, char *dst, size_t dst_len) {
    size_t o = 0;
    if (!src) src = "";
    for (size_t i = 0; src[i] && o + 2 < dst_len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') {
            if (o + 3 >= dst_len) break;
            dst[o++] = '\\';
            dst[o++] = (char)c;
        } else if (c < 0x20) {
            if (o + 7 >= dst_len) break;
            o += (size_t)snprintf(dst + o, dst_len - o, "\\u%04x", c);
        } else {
            dst[o++] = (char)c;
        }
    }
    dst[o] = 0;
}

static void emit_event_fmt(const char *fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    emit_bytes((uint8_t)'E', buf, (uint32_t)strlen(buf));
}

static void file_log(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static void log_cb(void *cls, int level, const char *msg) {
    (void)cls;
    fprintf(stderr, "[airplay %d] %s\n", level, msg ? msg : "");
    file_log("[airplay %d] %s", level, msg ? msg : "");
    /* Do not write logs to stdout. That 64KB pipe fills, this callback
       runs on the AirPlay thread, and the phone drops the session. */
}

static void close_video_fd(void) {
    pthread_mutex_lock(&g_video_lock);
    if (g_video_fd >= 0) {
        close(g_video_fd);
        g_video_fd = -1;
    }
    pthread_mutex_unlock(&g_video_lock);
}

static void *video_connect_thread(void *arg) {
    (void)arg;
    while (!g_stop) {
        pthread_mutex_lock(&g_video_lock);
        int have = g_video_fd;
        pthread_mutex_unlock(&g_video_lock);
        if (have >= 0 || !g_sock_path[0]) {
            usleep(200000);
            continue;
        }
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            usleep(200000);
            continue;
        }
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, g_sock_path, sizeof(addr.sun_path) - 1);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            close(fd);
            usleep(100000);
            continue;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int snd = 2 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd));
        int nosigpipe = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe)) != 0) {
            close(fd);
            usleep(100000);
            continue;
        }
        pthread_mutex_lock(&g_video_lock);
        if (g_video_fd >= 0) close(g_video_fd);
        g_video_fd = fd;
        pthread_mutex_unlock(&g_video_lock);
        file_log("video socket connected to %s", g_sock_path);
        fprintf(stderr, "video socket connected\n");
    }
    return NULL;
}

/* Write the whole iovec. Returns 0 on success, 1 to drop a still-unsent
   frame (EAGAIN with nothing written), -1 for a fatal write that must
   close the socket so the receiver stays aligned. */
static int writev_all(int fd, struct iovec *iov, int iovcnt, size_t total) {
    size_t sent = 0;
    while (sent < total) {
        ssize_t w = writev(fd, iov, iovcnt);
        if (w > 0) {
            size_t skip = (size_t)w;
            sent += skip;
            while (skip && iovcnt > 0) {
                if (skip >= iov[0].iov_len) {
                    skip -= iov[0].iov_len;
                    iov++;
                    iovcnt--;
                } else {
                    iov[0].iov_base = (char *)iov[0].iov_base + skip;
                    iov[0].iov_len -= skip;
                    skip = 0;
                }
            }
            continue;
        }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (sent == 0) return 1;
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            if (poll(&pfd, 1, 50) > 0) continue;
        }
        return -1;
    }
    return 0;
}

static void emit_video(const void *payload, uint32_t len) {
    uint8_t header[5];
    header[0] = (uint8_t)'V';
    uint32_t be = htonl(len);
    memcpy(header + 1, &be, 4);

    pthread_mutex_lock(&g_video_lock);
    int fd = g_video_fd;
    if (fd < 0) {
        pthread_mutex_unlock(&g_video_lock);
        return;
    }
    struct iovec iov[2] = {
        { .iov_base = header, .iov_len = 5 },
        { .iov_base = (void *)payload, .iov_len = len },
    };
    int wr = writev_all(fd, iov, 2, 5 + (size_t)len);
    if (wr == 1) {
        file_log("video socket backpressure — dropped frame");
    } else if (wr < 0) {
        close(fd);
        g_video_fd = -1;
        file_log("video socket write failed errno=%d — dropped frame", errno);
    }
    pthread_mutex_unlock(&g_video_lock);
}

static void conn_init_cb(void *cls) {
    (void)cls;
    emit_event_fmt("{\"type\":\"connecting\"}");
}

static void conn_destroy_cb(void *cls) {
    (void)cls;
    emit_event_fmt("{\"type\":\"disconnect\"}");
}

static void conn_feedback_cb(void *cls) { (void)cls; }

static void conn_reset_cb(void *cls, int reason) {
    (void)cls;
    emit_event_fmt("{\"type\":\"reset\",\"reason\":%d}", reason);
}

static void video_reset_cb(void *cls, reset_type_t reset_type) {
    (void)cls;
    emit_event_fmt("{\"type\":\"video_reset\",\"reset\":%d}", (int)reset_type);
}

static void video_process_cb(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void)cls;
    (void)ntp;
    if (!data || !data->data || data->data_len <= 0) return;
    uint32_t body = 8 + 4 + 1 + (uint32_t)data->data_len;
    uint8_t *buf = malloc(body);
    if (!buf) return;
    uint64_t pts = data->ntp_time_remote;
    buf[0] = (uint8_t)(pts >> 56);
    buf[1] = (uint8_t)(pts >> 48);
    buf[2] = (uint8_t)(pts >> 40);
    buf[3] = (uint8_t)(pts >> 32);
    buf[4] = (uint8_t)(pts >> 24);
    buf[5] = (uint8_t)(pts >> 16);
    buf[6] = (uint8_t)(pts >> 8);
    buf[7] = (uint8_t)pts;
    uint32_t nals = htonl((uint32_t)data->nal_count);
    memcpy(buf + 8, &nals, 4);
    buf[12] = data->is_h265 ? 1 : 0;
    memcpy(buf + 13, data->data, (size_t)data->data_len);
    emit_video(buf, body);
    file_log("video frame %d bytes h265=%d", data->data_len, data->is_h265 ? 1 : 0);
    free(buf);
}

static void audio_process_cb(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void)cls;
    (void)ntp;
    (void)data;
    /* Bezel shipped video first; device audio over AirPlay is a later pass. */
}

static void video_pause_cb(void *cls) {
    (void)cls;
    emit_event_fmt("{\"type\":\"paused\"}");
    file_log("video paused (phone locked or screen off)");
}

static void video_resume_cb(void *cls) {
    (void)cls;
    emit_event_fmt("{\"type\":\"resumed\"}");
    file_log("video resumed (phone unlocked)");
}
static void audio_flush_cb(void *cls) { (void)cls; }
static void video_flush_cb(void *cls) { (void)cls; }

static double audio_set_client_volume_cb(void *cls) {
    (void)cls;
    return 0.0;
}

static void audio_set_volume_cb(void *cls, float volume) {
    (void)cls;
    (void)volume;
}

static void audio_set_metadata_cb(void *cls, const void *buffer, int buflen) {
    (void)cls;
    (void)buffer;
    (void)buflen;
}

static void audio_set_coverart_cb(void *cls, const void *buffer, int buflen) {
    (void)cls;
    (void)buffer;
    (void)buflen;
}

static void audio_stop_coverart_cb(void *cls) { (void)cls; }

static void audio_remote_control_id_cb(void *cls, const char *dacp_id, const char *active_remote_header) {
    (void)cls;
    (void)dacp_id;
    (void)active_remote_header;
}

static void audio_set_progress_cb(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {
    (void)cls;
    (void)start;
    (void)curr;
    (void)end;
}

static void audio_get_format_cb(void *cls, unsigned char *ct, unsigned short *spf,
                                bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    (void)cls;
    if (ct) *ct = 0;
    if (spf) *spf = 0;
    if (usingScreen) *usingScreen = true;
    if (isMedia) *isMedia = false;
    if (audioFormat) *audioFormat = 0;
}

static void video_report_size_cb(void *cls, float *width_source, float *height_source,
                                 float *width, float *height) {
    (void)cls;
    float ws = width_source ? *width_source : 0;
    float hs = height_source ? *height_source : 0;
    float w = width ? *width : 0;
    float h = height ? *height : 0;
    emit_event_fmt("{\"type\":\"size\",\"width\":%.0f,\"height\":%.0f,\"sourceWidth\":%.0f,\"sourceHeight\":%.0f}",
                   w, h, ws, hs);
}

static void report_client_request_cb(void *cls, char *deviceid, char *model, char *name, bool *admit) {
    (void)cls;
    if (admit) *admit = true;
    char n[256], m[128], d[128];
    json_escape(name ? name : "", n, sizeof(n));
    json_escape(model ? model : "", m, sizeof(m));
    json_escape(deviceid ? deviceid : "", d, sizeof(d));
    emit_event_fmt("{\"type\":\"client\",\"name\":\"%s\",\"model\":\"%s\",\"deviceID\":\"%s\"}", n, m, d);
}

static void display_pin_cb(void *cls, char *pin) {
    (void)cls;
    char p[32];
    json_escape(pin ? pin : "", p, sizeof(p));
    emit_event_fmt("{\"type\":\"pin\",\"pin\":\"%s\"}", p);
}

static char g_clients_path[1100] = {0};
static bool check_register_cb(void *cls, const char *pk_str);

static bool field_is_safe(const char *s) {
    if (!s) return true;
    for (size_t i = 0; s[i]; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c == '\t' || c == 0x7f) return false;
    }
    return true;
}

static void register_client_cb(void *cls, const char *device_id, const char *pk_str, const char *name) {
    (void)cls;
    file_log("register client %s id=%s", name ? name : "?", device_id ? device_id : "?");
    if (!g_clients_path[0] || !pk_str) return;
    if (!field_is_safe(pk_str) || !field_is_safe(device_id) || !field_is_safe(name)) {
        file_log("rejected client record with control characters");
        return;
    }
    if (check_register_cb(NULL, pk_str)) return;
    int fd = open(g_clients_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    (void)fchmod(fd, 0600); /* fix perms on files created before this hardening */
    FILE *fp = fdopen(fd, "a");
    if (!fp) {
        close(fd);
        return;
    }
    fprintf(fp, "%s\t%s\t%s\n", pk_str, device_id ? device_id : "", name ? name : "");
    fclose(fp);
}

static bool check_register_cb(void *cls, const char *pk_str) {
    (void)cls;
    if (!pk_str || !g_clients_path[0]) return false;
    FILE *fp = fopen(g_clients_path, "r");
    if (!fp) return false;
    char line[1024];
    bool found = false;
    size_t n = strlen(pk_str);
    while (fgets(line, sizeof(line), fp)) {
        if (!strncmp(line, pk_str, n) && (line[n] == '\t' || line[n] == '\n' || line[n] == 0)) {
            found = true;
            break;
        }
    }
    fclose(fp);
    return found;
}

static const char *passwd_cb(void *cls, int *len) {
    (void)cls;
    if (len) *len = 0;
    return NULL;
}

static void export_dacp_cb(void *cls, const char *active_remote, const char *dacp_id) {
    (void)cls;
    (void)active_remote;
    (void)dacp_id;
}

static int video_set_codec_cb(void *cls, video_codec_t codec) {
    (void)cls;
    emit_event_fmt("{\"type\":\"codec\",\"codec\":\"%s\"}",
                   codec == VIDEO_CODEC_H265 ? "h265" : "h264");
    return 0;
}

static void on_video_play_cb(void *cls, const char *location, const float start_position) {
    (void)cls;
    (void)location;
    (void)start_position;
}

static void on_video_scrub_cb(void *cls, const float position) {
    (void)cls;
    (void)position;
}

static void on_video_rate_cb(void *cls, const float rate) {
    (void)cls;
    (void)rate;
}

static void on_video_stop_cb(void *cls) { (void)cls; }

static void on_video_acquire_playback_info_cb(void *cls, playback_info_t *info) {
    (void)cls;
    if (!info) return;
    memset(info, 0, sizeof(*info));
    info->ready_to_play = true;
}

static float on_video_playlist_remove_cb(void *cls) {
    (void)cls;
    return 0;
}

static void apply_features(dnssd_t *dnssd) {
    /* Match UxPlay's mirror-oriented feature bits. HLS off, HEVC on (bit 42). */
    dnssd_set_airplay_features(dnssd, 0, 0);
    dnssd_set_airplay_features(dnssd, 1, 1);
    dnssd_set_airplay_features(dnssd, 2, 1);
    dnssd_set_airplay_features(dnssd, 3, 0);
    dnssd_set_airplay_features(dnssd, 4, 0);
    dnssd_set_airplay_features(dnssd, 5, 1);
    dnssd_set_airplay_features(dnssd, 6, 1);
    dnssd_set_airplay_features(dnssd, 7, 1);
    dnssd_set_airplay_features(dnssd, 8, 0);
    dnssd_set_airplay_features(dnssd, 9, 1);
    dnssd_set_airplay_features(dnssd, 10, 1);
    dnssd_set_airplay_features(dnssd, 11, 1);
    dnssd_set_airplay_features(dnssd, 12, 1);
    dnssd_set_airplay_features(dnssd, 13, 1);
    dnssd_set_airplay_features(dnssd, 14, 1);
    dnssd_set_airplay_features(dnssd, 15, 1);
    dnssd_set_airplay_features(dnssd, 16, 1);
    dnssd_set_airplay_features(dnssd, 17, 1);
    dnssd_set_airplay_features(dnssd, 18, 1);
    dnssd_set_airplay_features(dnssd, 19, 1);
    dnssd_set_airplay_features(dnssd, 20, 1);
    dnssd_set_airplay_features(dnssd, 21, 1);
    dnssd_set_airplay_features(dnssd, 22, 1);
    dnssd_set_airplay_features(dnssd, 23, 0);
    dnssd_set_airplay_features(dnssd, 24, 0);
    dnssd_set_airplay_features(dnssd, 25, 1);
    dnssd_set_airplay_features(dnssd, 26, 0);
    dnssd_set_airplay_features(dnssd, 27, 1);
    dnssd_set_airplay_features(dnssd, 28, 1);
    dnssd_set_airplay_features(dnssd, 29, 0);
    dnssd_set_airplay_features(dnssd, 30, 1);
    dnssd_set_airplay_features(dnssd, 31, 0);
    dnssd_set_airplay_features(dnssd, 42, 1); // current iPhones send HEVC for Screen Mirroring
}

static int parse_mac(const char *str, char *out, int out_len) {
    int n = 0;
    for (int i = 0; str[i] && n < out_len; i += 3) {
        char tmp[3] = { str[i], str[i + 1], 0 };
        out[n++] = (char)strtol(tmp, NULL, 16);
    }
    return n;
}

static void find_mac(char *out, size_t out_len) {
    struct ifaddrs *ifap = NULL;
    out[0] = 0;
    if (getifaddrs(&ifap) != 0) return;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        unsigned char *ptr = (unsigned char *)LLADDR((struct sockaddr_dl *)p->ifa_addr);
        int nonzero = 0;
        for (int i = 0; i < 6; i++) if (ptr[i]) nonzero++;
        if (!nonzero) continue;
        snprintf(out, out_len, "%02x:%02x:%02x:%02x:%02x:%02x",
                 ptr[0], ptr[1], ptr[2], ptr[3], ptr[4], ptr[5]);
        break;
    }
    freeifaddrs(ifap);
}

static void random_mac(char *out, size_t out_len) {
    unsigned char b[6];
    size_t got = 0;
    FILE *ur = fopen("/dev/urandom", "rb");
    if (ur) {
        got = fread(b, 1, 6, ur);
        fclose(ur);
    }
    if (got != 6) {
        /* Local device id only, not a secret. rand() is fine here. */
        srand((unsigned)time(NULL) ^ (unsigned)getpid());
        for (int i = 0; i < 6; i++) b[i] = (unsigned char)(rand() & 0xff);
    }
    b[0] = (unsigned char)((b[0] & ~0x01) | 0x02);
    snprintf(out, out_len, "%02x:%02x:%02x:%02x:%02x:%02x",
             b[0], b[1], b[2], b[3], b[4], b[5]);
}

static void ensure_dir(const char *path) {
    mkdir(path, 0700);
}

int main(int argc, char **argv) {
    const char *name = "Record iPhone";
    const char *key_dir = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--key-dir") && i + 1 < argc) key_dir = argv[++i];
        else if (!strcmp(argv[i], "--video-sock") && i + 1 < argc) {
            strncpy(g_sock_path, argv[++i], sizeof(g_sock_path) - 1);
        }
    }

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    char support[1024];
    if (!key_dir) {
        const char *home = getenv("HOME");
        if (!home) home = ".";
        snprintf(support, sizeof(support),
                 "%s/Library/Application Support/Record iPhone", home);
        ensure_dir(support);
        key_dir = support;
    }

    char keyfile[1100];
    snprintf(keyfile, sizeof(keyfile), "%s/airplay.key", key_dir);
    char logfile[1100];
    snprintf(logfile, sizeof(logfile), "%s/airplay-helper.log", key_dir);
    snprintf(g_clients_path, sizeof(g_clients_path), "%s/airplay-clients.txt", key_dir);
    int logfd = open(logfile, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (logfd >= 0) {
        g_log = fdopen(logfd, "a");
        if (!g_log) close(logfd);
    }
    file_log("---- helper start name=%s sock=%s ----", name, g_sock_path);

    pthread_t video_thr;
    if (pthread_create(&video_thr, NULL, video_connect_thread, NULL) != 0) {
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not start the video transport.\"}");
        return 1;
    }
    pthread_detach(video_thr);

    char mac[32];
    find_mac(mac, sizeof(mac));
    if (!mac[0]) random_mac(mac, sizeof(mac));

    char hw[8];
    int hw_len = parse_mac(mac, hw, 8);
    if (hw_len < 6) {
        fprintf(stderr, "bad MAC %s\n", mac);
        return 1;
    }

    int err = 0;
    g_dnssd = dnssd_init(name, (int)strlen(name), hw, hw_len, 0, &err);
    if (!g_dnssd || err) {
        fprintf(stderr, "dnssd_init failed: %d\n", err);
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not advertise on the local network (code %d).\"}", err);
        return 1;
    }
    /* iPhone Screen Mirroring almost always uses the phone’s private
       wireless hop (AWDL). Without this, the checkmark appears and
       then the picture stream dies. */
    dnssd_set_peer_to_peer(g_dnssd, 1);
    apply_features(g_dnssd);

    raop_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.conn_init = conn_init_cb;
    cbs.conn_destroy = conn_destroy_cb;
    cbs.conn_reset = conn_reset_cb;
    cbs.conn_feedback = conn_feedback_cb;
    cbs.audio_process = audio_process_cb;
    cbs.video_process = video_process_cb;
    cbs.audio_flush = audio_flush_cb;
    cbs.video_flush = video_flush_cb;
    cbs.video_pause = video_pause_cb;
    cbs.video_resume = video_resume_cb;
    cbs.video_reset = video_reset_cb;
    cbs.audio_set_client_volume = audio_set_client_volume_cb;
    cbs.audio_set_volume = audio_set_volume_cb;
    cbs.audio_set_metadata = audio_set_metadata_cb;
    cbs.audio_set_coverart = audio_set_coverart_cb;
    cbs.audio_stop_coverart_rendering = audio_stop_coverart_cb;
    cbs.audio_remote_control_id = audio_remote_control_id_cb;
    cbs.audio_set_progress = audio_set_progress_cb;
    cbs.audio_get_format = audio_get_format_cb;
    cbs.video_report_size = video_report_size_cb;
    cbs.report_client_request = report_client_request_cb;
    cbs.display_pin = display_pin_cb;
    cbs.register_client = register_client_cb;
    cbs.check_register = check_register_cb;
    cbs.passwd = passwd_cb;
    cbs.export_dacp = export_dacp_cb;
    cbs.video_set_codec = video_set_codec_cb;
    cbs.on_video_play = on_video_play_cb;
    cbs.on_video_scrub = on_video_scrub_cb;
    cbs.on_video_rate = on_video_rate_cb;
    cbs.on_video_stop = on_video_stop_cb;
    cbs.on_video_acquire_playback_info = on_video_acquire_playback_info_cb;
    cbs.on_video_playlist_remove = on_video_playlist_remove_cb;

    g_raop = raop_init(&cbs);
    if (!g_raop) {
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not start the wireless receiver.\"}");
        return 1;
    }
    raop_set_log_callback(g_raop, log_cb, NULL);
    raop_set_log_level(g_raop, LOGGER_DEBUG);
    if (raop_init2(g_raop, 1, mac, keyfile)) {
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not finish wireless setup.\"}");
        return 1;
    }

    raop_set_plist(g_raop, "width", 1170);
    raop_set_plist(g_raop, "height", 2532);
    raop_set_plist(g_raop, "refreshRate", 60);
    raop_set_plist(g_raop, "maxFPS", 60);
    raop_set_plist(g_raop, "overscanned", 0);

    unsigned short tcp[2] = {0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(g_raop, tcp);
    raop_set_udp_ports(g_raop, udp);

    unsigned short port = raop_get_port(g_raop);
    if (raop_start_httpd(g_raop, &port) < 0) {
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not open the wireless port.\"}");
        return 1;
    }
    raop_set_port(g_raop, port);
    raop_set_dnssd(g_raop, g_dnssd);

    if (dnssd_register_raop(g_dnssd, port) != 0 ||
        dnssd_register_airplay(g_dnssd, port) != 0) {
        emit_event_fmt("{\"type\":\"error\",\"message\":\"Could not publish Record iPhone on the network.\"}");
        return 1;
    }

    char esc[256];
    json_escape(name, esc, sizeof(esc));
    emit_event_fmt("{\"type\":\"ready\",\"name\":\"%s\",\"port\":%u}", esc, (unsigned)port);
    fprintf(stderr, "advertising '%s' on port %u (mac %s)\n", name, (unsigned)port, mac);

    while (!g_stop) sleep(1);

    close_video_fd();
    if (g_dnssd) {
        dnssd_unregister_raop(g_dnssd);
        dnssd_unregister_airplay(g_dnssd);
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
    }
    if (g_raop) {
        raop_destroy(g_raop);
        g_raop = NULL;
    }
    if (g_log) { fclose(g_log); g_log = NULL; }
    return 0;
}
