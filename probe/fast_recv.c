/*
 * High-performance VXLAN capture + parse + aggregate in C.
 * Uses recvmmsg() to batch-receive packets, eliminating Python per-packet overhead.
 *
 * Compile: gcc -O2 -shared -fPIC -o fast_recv.so fast_recv.c
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* ---- Configuration ---- */
#define BATCH_SIZE      256
#define MAX_PKT_SIZE    2048
#define HT_SIZE         (1 << 18)   /* 262144 slots */
#define HT_MASK         (HT_SIZE - 1)
#define MAX_FLOWS       200000
#define FLUSH_BUF_MAX   200000

/* ---- VXLAN parsing constants ---- */
#define VXLAN_HDR       8
#define ETH_HDR         14
#define IP_MIN_HDR      20
#define ETH_P_IP        0x0800

/* ---- Hash table entry (32 bytes, aligned) ---- */
struct ht_entry {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
    uint8_t  occupied;
    uint16_t _pad;
    uint64_t packets;
    uint64_t bytes;
};

/* ---- Flush output record (32 bytes) ---- */
struct flow_record {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
    uint8_t  _pad1;
    uint16_t _pad2;
    uint64_t packets;
    uint64_t bytes;
};

/* ---- Capture context ---- */
typedef struct {
    int sock_fd;
    volatile int running;
    int num_flows;
    struct ht_entry table[HT_SIZE];
    /* recvmmsg buffers */
    struct mmsghdr msgs[BATCH_SIZE];
    struct iovec   iovecs[BATCH_SIZE];
    uint8_t        pktbufs[BATCH_SIZE][MAX_PKT_SIZE];
    /* flush output */
    struct flow_record flush_buf[FLUSH_BUF_MAX];
    uint64_t total_pkts;
    uint64_t total_bytes;
    uint64_t total_parsed;
} capture_ctx_t;

/* ---- FNV-1a hash on 13-byte key ---- */
static inline uint32_t hash_key(uint32_t sip, uint32_t dip, uint8_t proto,
                                 uint16_t sport, uint16_t dport)
{
    uint32_t h = 2166136261u;
    const uint8_t *p;

    p = (const uint8_t *)&sip;
    h = (h ^ p[0]) * 16777619u; h = (h ^ p[1]) * 16777619u;
    h = (h ^ p[2]) * 16777619u; h = (h ^ p[3]) * 16777619u;

    p = (const uint8_t *)&dip;
    h = (h ^ p[0]) * 16777619u; h = (h ^ p[1]) * 16777619u;
    h = (h ^ p[2]) * 16777619u; h = (h ^ p[3]) * 16777619u;

    h = (h ^ proto) * 16777619u;

    p = (const uint8_t *)&sport;
    h = (h ^ p[0]) * 16777619u; h = (h ^ p[1]) * 16777619u;

    p = (const uint8_t *)&dport;
    h = (h ^ p[0]) * 16777619u; h = (h ^ p[1]) * 16777619u;

    return h;
}

/* ---- Inline VXLAN parse + aggregate ---- */
static inline void parse_and_record(capture_ctx_t *ctx, const uint8_t *data, int len)
{
    /* Minimum: VXLAN(8) + ETH(14) + IP(20) = 42 */
    if (len < VXLAN_HDR + ETH_HDR + IP_MIN_HDR)
        return;

    /* Ethernet ethertype check */
    uint16_t etype = (uint16_t)(data[VXLAN_HDR + 12] << 8 | data[VXLAN_HDR + 13]);
    if (etype != ETH_P_IP)
        return;

    const uint8_t *ip = data + VXLAN_HDR + ETH_HDR;
    int ihl = (ip[0] & 0x0F) * 4;
    if (ihl < IP_MIN_HDR || VXLAN_HDR + ETH_HDR + ihl > len)
        return;

    uint16_t total_len = (uint16_t)(ip[2] << 8 | ip[3]);
    uint8_t  proto     = ip[9];
    uint32_t src_ip, dst_ip;
    memcpy(&src_ip, ip + 12, 4);
    memcpy(&dst_ip, ip + 16, 4);

    uint16_t sport = 0, dport = 0;
    if (proto == 6 || proto == 17) {
        int l4off = VXLAN_HDR + ETH_HDR + ihl;
        if (l4off + 4 <= len) {
            sport = (uint16_t)(data[l4off] << 8 | data[l4off + 1]);
            dport = (uint16_t)(data[l4off + 2] << 8 | data[l4off + 3]);
        }
    }

    ctx->total_parsed++;

    /* Hash table lookup + insert */
    uint32_t h = hash_key(src_ip, dst_ip, proto, sport, dport);
    uint32_t idx = h & HT_MASK;

    for (int probe = 0; probe < 64; probe++) {
        struct ht_entry *e = &ctx->table[idx];
        if (!e->occupied) {
            /* Empty slot: insert new flow */
            if (ctx->num_flows >= MAX_FLOWS)
                return; /* Table full, skip */
            e->src_ip   = src_ip;
            e->dst_ip   = dst_ip;
            e->src_port = sport;
            e->dst_port = dport;
            e->proto    = proto;
            e->occupied = 1;
            e->packets  = 1;
            e->bytes    = total_len;
            ctx->num_flows++;
            return;
        }
        if (e->src_ip == src_ip && e->dst_ip == dst_ip &&
            e->proto == proto && e->src_port == sport && e->dst_port == dport) {
            /* Existing flow: update */
            e->packets++;
            e->bytes += total_len;
            return;
        }
        idx = (idx + 1) & HT_MASK;
    }
    /* Max probes exceeded, skip this flow */
}

/* ---- Public API ---- */

capture_ctx_t* cap_create(int port, int rcvbuf)
{
    capture_ctx_t *ctx = calloc(1, sizeof(capture_ctx_t));
    if (!ctx) return NULL;

    ctx->sock_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (ctx->sock_fd < 0) { free(ctx); return NULL; }

    int one = 1;
    setsockopt(ctx->sock_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (setsockopt(ctx->sock_fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0) {
        close(ctx->sock_fd); free(ctx); return NULL;
    }
    if (setsockopt(ctx->sock_fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
        /* Non-fatal: kernel may cap the value, log via cap_get_rcvbuf() */
    }

    /* Set socket recv timeout — more reliable than recvmmsg timeout */
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; /* 100ms */
    setsockopt(ctx->sock_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(ctx->sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(ctx->sock_fd);
        free(ctx);
        return NULL;
    }

    /* Setup recvmmsg buffers */
    for (int i = 0; i < BATCH_SIZE; i++) {
        ctx->iovecs[i].iov_base = ctx->pktbufs[i];
        ctx->iovecs[i].iov_len  = MAX_PKT_SIZE;
        ctx->msgs[i].msg_hdr.msg_iov    = &ctx->iovecs[i];
        ctx->msgs[i].msg_hdr.msg_iovlen = 1;
        ctx->msgs[i].msg_hdr.msg_name    = NULL;
        ctx->msgs[i].msg_hdr.msg_namelen = 0;
    }

    ctx->running = 0;
    return ctx;
}

int cap_get_rcvbuf(capture_ctx_t *ctx)
{
    int val = 0;
    socklen_t len = sizeof(val);
    getsockopt(ctx->sock_fd, SOL_SOCKET, SO_RCVBUF, &val, &len);
    return val;
}

int cap_run(capture_ctx_t *ctx, int duration_ms)
{
    ctx->running = 1;
    ctx->total_pkts = 0;
    ctx->total_bytes = 0;
    ctx->total_parsed = 0;

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    long deadline_ns = (long)duration_ms * 1000000L;

    while (ctx->running) {
        /* Reset iov lengths */
        for (int i = 0; i < BATCH_SIZE; i++)
            ctx->iovecs[i].iov_len = MAX_PKT_SIZE;

        int n = recvmmsg(ctx->sock_fd, ctx->msgs, BATCH_SIZE, MSG_WAITFORONE, NULL);
        if (n <= 0) {
            if (errno == EAGAIN || errno == EINTR || errno == ETIMEDOUT)
                goto check_time;
            break;
        }

        for (int i = 0; i < n; i++) {
            int pktlen = ctx->msgs[i].msg_len;
            ctx->total_pkts++;
            ctx->total_bytes += pktlen;
            parse_and_record(ctx, ctx->pktbufs[i], pktlen);
        }

check_time:
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000000000L +
                       (now.tv_nsec - start.tv_nsec);
        if (elapsed >= deadline_ns)
            break;
    }

    return (int)ctx->total_pkts;
}

void cap_stop(capture_ctx_t *ctx)
{
    ctx->running = 0;
}

/*
 * Flush: copy occupied entries to flush_buf, reset table.
 * Returns count of flows. Caller reads flush_buf via cap_get_flush_buf().
 */
int cap_flush(capture_ctx_t *ctx)
{
    int count = 0;
    for (int i = 0; i < HT_SIZE && count < FLUSH_BUF_MAX; i++) {
        struct ht_entry *e = &ctx->table[i];
        if (e->occupied) {
            struct flow_record *r = &ctx->flush_buf[count];
            r->src_ip   = e->src_ip;
            r->dst_ip   = e->dst_ip;
            r->src_port = e->src_port;
            r->dst_port = e->dst_port;
            r->proto    = e->proto;
            r->_pad1    = 0;
            r->_pad2    = 0;
            r->packets  = e->packets;
            r->bytes    = e->bytes;
            count++;
        }
    }

    /* Reset table */
    memset(ctx->table, 0, sizeof(ctx->table));
    ctx->num_flows = 0;

    return count;
}

struct flow_record* cap_get_flush_buf(capture_ctx_t *ctx)
{
    return ctx->flush_buf;
}

uint64_t cap_get_total_pkts(capture_ctx_t *ctx) { return ctx->total_pkts; }
uint64_t cap_get_total_bytes(capture_ctx_t *ctx) { return ctx->total_bytes; }
uint64_t cap_get_total_parsed(capture_ctx_t *ctx) { return ctx->total_parsed; }
int cap_get_num_flows(capture_ctx_t *ctx) { return ctx->num_flows; }

void cap_destroy(capture_ctx_t *ctx)
{
    if (ctx) {
        if (ctx->sock_fd >= 0) close(ctx->sock_fd);
        free(ctx);
    }
}

/* Utility: IP u32 (network byte order in struct) to string */
void ip_to_str(uint32_t ip_raw, char *buf, int buflen)
{
    /* ip_raw is stored as memcpy from packet (network byte order) */
    inet_ntop(AF_INET, &ip_raw, buf, (socklen_t)buflen);
}
