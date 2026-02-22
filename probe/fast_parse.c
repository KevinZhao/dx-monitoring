#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>

struct flow_result {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint8_t  protocol;
    uint8_t  _pad1;
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t pkt_len;
};

#define VXLAN_HDR_LEN  8
#define ETH_HDR_LEN    14
#define ETH_P_IP       0x0800
#define IP_MIN_HDR_LEN 20

static inline uint16_t read_u16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

static inline uint32_t read_u32(const uint8_t *p)
{
    return (uint32_t)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]);
}

int parse_vxlan_packet(const uint8_t *data, int data_len, struct flow_result *result)
{
    int offset = 0;

    /* VXLAN header: 8 bytes */
    if (data_len < VXLAN_HDR_LEN + ETH_HDR_LEN + IP_MIN_HDR_LEN)
        return -1;
    offset += VXLAN_HDR_LEN;

    /* Ethernet header: 14 bytes, check IPv4 ethertype */
    uint16_t ethertype = read_u16(data + offset + 12);
    if (ethertype != ETH_P_IP)
        return -1;
    offset += ETH_HDR_LEN;

    /* IP header */
    const uint8_t *ip = data + offset;
    uint8_t ver_ihl = ip[0];
    if ((ver_ihl >> 4) != 4)
        return -1;

    int ihl = (ver_ihl & 0x0F) * 4;
    if (ihl < IP_MIN_HDR_LEN)
        return -1;
    if (offset + ihl > data_len)
        return -1;

    result->pkt_len  = read_u16(ip + 2);
    result->protocol = ip[9];
    result->src_ip   = read_u32(ip + 12);
    result->dst_ip   = read_u32(ip + 16);

    /* TCP or UDP: extract ports */
    if (result->protocol == IPPROTO_TCP || result->protocol == IPPROTO_UDP) {
        int l4_offset = offset + ihl;
        if (l4_offset + 4 > data_len) {
            result->src_port = 0;
            result->dst_port = 0;
        } else {
            const uint8_t *l4 = data + l4_offset;
            result->src_port = read_u16(l4);
            result->dst_port = read_u16(l4 + 2);
        }
    } else {
        result->src_port = 0;
        result->dst_port = 0;
    }

    return 0;
}

void ip_to_str(uint32_t ip, char *buf, int buf_len)
{
    uint32_t net = htonl(ip);
    inet_ntop(AF_INET, &net, buf, (socklen_t)buf_len);
}
