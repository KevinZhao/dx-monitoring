/*
 * High-performance VXLAN packet flood generator v2.
 * - Configurable flow count (default 100K) and packet size (default 128B)
 * - Uses sendmmsg() for batched sends
 * - Atomic counters for live progress reporting
 *
 * Compile: gcc -O2 -o vxlan_flood vxlan_flood.c -lpthread
 * Usage:   ./vxlan_flood <target_ip> <port> <threads> <duration> [pkt_size] [num_flows]
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <signal.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdatomic.h>

#define BATCH_SIZE 256

static volatile int running = 1;
static atomic_long counters[64];

struct thread_args {
    int thread_id;
    struct sockaddr_in target;
    int pkt_size;
    int num_flows;
};

static void build_vxlan_packet(uint8_t *buf, int pkt_size, int flow_id)
{
    memset(buf, 0, pkt_size);

    /* VXLAN header (8 bytes) */
    buf[0] = 0x08;
    buf[4] = (12345 >> 16) & 0xFF;
    buf[5] = (12345 >> 8) & 0xFF;
    buf[6] = 12345 & 0xFF;

    /* Ethernet header (14 bytes) at offset 8 */
    buf[8 + 12] = 0x08;
    buf[8 + 13] = 0x00;

    /* IP header (20 bytes) at offset 22 */
    int off = 22;
    buf[off] = 0x45;
    int ip_total = pkt_size - 8 - 14;
    buf[off + 2] = (ip_total >> 8) & 0xFF;
    buf[off + 3] = ip_total & 0xFF;
    buf[off + 8] = 64;
    buf[off + 9] = (flow_id % 3 == 0) ? 17 : 6;  /* mix TCP/UDP */

    /* src IP: spread across 10.x.x.x */
    buf[off + 12] = 10;
    buf[off + 13] = (flow_id >> 16) & 0xFF;
    buf[off + 14] = (flow_id >> 8) & 0xFF;
    buf[off + 15] = (flow_id & 0xFF) | 1;

    /* dst IP: spread across 172.16.x.x */
    buf[off + 16] = 172;
    buf[off + 17] = 16 + ((flow_id >> 16) & 0x0F);
    buf[off + 18] = (flow_id >> 8) & 0xFF;
    buf[off + 19] = (flow_id & 0xFF) | 1;

    /* TCP/UDP ports at offset 42 */
    if (pkt_size >= 46) {
        uint16_t sport = htons(1024 + (flow_id % 60000));
        uint16_t dport = htons(80 + (flow_id % 1000));
        memcpy(buf + 42, &sport, 2);
        memcpy(buf + 44, &dport, 2);
    }
}

static void *sender_thread(void *arg)
{
    struct thread_args *ta = (struct thread_args *)arg;
    int tid = ta->thread_id;
    int pkt_size = ta->pkt_size;
    int flows_per_thread = ta->num_flows;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return NULL; }

    /* Increase send buffer */
    int sndbuf = 16 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    /* Pre-build packets for diverse flows */
    int batch = BATCH_SIZE;
    if (batch > flows_per_thread) batch = flows_per_thread;

    uint8_t *packets = malloc(batch * pkt_size);
    if (!packets) { perror("malloc"); close(sock); return NULL; }

    for (int i = 0; i < batch; i++) {
        build_vxlan_packet(packets + i * pkt_size, pkt_size,
                           tid * flows_per_thread + i);
    }

    struct mmsghdr *msgs = calloc(batch, sizeof(struct mmsghdr));
    struct iovec *iovecs = calloc(batch, sizeof(struct iovec));

    for (int i = 0; i < batch; i++) {
        iovecs[i].iov_base = packets + i * pkt_size;
        iovecs[i].iov_len = pkt_size;
        msgs[i].msg_hdr.msg_name = &ta->target;
        msgs[i].msg_hdr.msg_namelen = sizeof(ta->target);
        msgs[i].msg_hdr.msg_iov = &iovecs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    while (running) {
        int sent = sendmmsg(sock, msgs, batch, 0);
        if (sent > 0) {
            atomic_fetch_add(&counters[tid], sent);
        } else if (errno == ENOBUFS || errno == EAGAIN) {
            usleep(1);
        }
    }

    free(packets);
    free(msgs);
    free(iovecs);
    close(sock);
    return NULL;
}

static void handle_signal(int sig) { (void)sig; running = 0; }

int main(int argc, char *argv[])
{
    if (argc < 5) {
        fprintf(stderr, "Usage: %s <ip> <port> <threads> <duration> [pkt_size=128] [total_flows=100000]\n", argv[0]);
        return 1;
    }

    const char *target_ip = argv[1];
    int port = atoi(argv[2]);
    int num_threads = atoi(argv[3]);
    int duration = atoi(argv[4]);
    int pkt_size = argc > 5 ? atoi(argv[5]) : 128;
    int total_flows = argc > 6 ? atoi(argv[6]) : 100000;

    if (num_threads > 64) num_threads = 64;
    if (pkt_size < 64) pkt_size = 64;
    if (pkt_size > 9000) pkt_size = 9000;
    int flows_per_thread = total_flows / num_threads;

    struct sockaddr_in target = {0};
    target.sin_family = AF_INET;
    target.sin_port = htons(port);
    inet_pton(AF_INET, target_ip, &target.sin_addr);

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("VXLAN Flood v2\n");
    printf("  Target:    %s:%d\n", target_ip, port);
    printf("  Threads:   %d\n", num_threads);
    printf("  Duration:  %ds\n", duration);
    printf("  Pkt size:  %d bytes\n", pkt_size);
    printf("  Flows:     %d total (%d/thread)\n", total_flows, flows_per_thread);
    printf("  Batch:     %d\n", BATCH_SIZE);
    printf("\n");

    pthread_t threads[64];
    struct thread_args args[64];

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (int i = 0; i < num_threads; i++) {
        args[i].thread_id = i;
        args[i].target = target;
        args[i].pkt_size = pkt_size;
        args[i].num_flows = flows_per_thread;
        atomic_store(&counters[i], 0);
        pthread_create(&threads[i], NULL, sender_thread, &args[i]);
    }

    long prev_total = 0;
    for (int s = 0; s < duration && running; s++) {
        sleep(1);
        long total = 0;
        for (int i = 0; i < num_threads; i++)
            total += atomic_load(&counters[i]);

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
        double avg_pps = total / elapsed;
        double avg_gbps = avg_pps * pkt_size * 8 / 1e9;
        long delta = total - prev_total;
        double inst_pps = delta;
        double inst_gbps = inst_pps * pkt_size * 8 / 1e9;
        prev_total = total;

        printf("[%3ds] total=%ld  avg=%.0f pps/%.2f Gbps  inst=%.0f pps/%.2f Gbps\n",
               s + 1, total, avg_pps, avg_gbps, inst_pps, inst_gbps);
    }

    running = 0;
    for (int i = 0; i < num_threads; i++)
        pthread_join(threads[i], NULL);

    long total = 0;
    for (int i = 0; i < num_threads; i++) {
        long c = atomic_load(&counters[i]);
        printf("  Thread-%d: %ld pkts\n", i, c);
        total += c;
    }

    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    double pps = total / elapsed;
    double gbps = pps * pkt_size * 8 / 1e9;

    printf("\nTotal: %ld packets in %.1fs\n", total, elapsed);
    printf("Rate:  %.0f pps (%.2f Gbps)\n", pps, gbps);

    return 0;
}
