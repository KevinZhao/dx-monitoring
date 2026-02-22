"""Tests for fast_parse.c (C VXLAN parser) and Python parser equivalence."""

import ctypes
import os
import socket
import struct
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "probe"))

from multiproc_probe import parse_vxlan_packet, _CFlowResult

PROBE_DIR = os.path.join(os.path.dirname(__file__), "..", "probe")
SO_PATH = os.path.join(PROBE_DIR, "fast_parse.so")


def _build_vxlan_packet(
    src_ip: str = "10.0.1.1",
    dst_ip: str = "10.0.2.2",
    proto: int = 6,
    src_port: int = 12345,
    dst_port: int = 80,
    ip_total_length: int = 60,
) -> bytes:
    """Build a minimal VXLAN-encapsulated packet for testing."""
    # VXLAN header (8 bytes): flags + VNI
    vxlan = struct.pack("!II", 0x08000000, 12345 << 8)

    # Ethernet header (14 bytes)
    eth = b"\x00" * 12 + struct.pack("!H", 0x0800)

    # IP header (20 bytes, IHL=5)
    ihl_ver = (4 << 4) | 5
    ip_hdr = struct.pack(
        "!BBHHHBBH4s4s",
        ihl_ver,
        0,  # DSCP/ECN
        ip_total_length,
        0,  # identification
        0,  # flags/fragment
        64,  # TTL
        proto,
        0,  # checksum
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    )

    # TCP/UDP ports (4 bytes)
    if proto in (6, 17):
        transport = struct.pack("!HH", src_port, dst_port) + b"\x00" * 16
    else:
        transport = b"\x00" * 20

    return vxlan + eth + ip_hdr + transport


class TestPythonParser:
    def test_basic_tcp(self):
        pkt = _build_vxlan_packet(
            src_ip="10.0.1.100", dst_ip="10.0.2.200", proto=6, src_port=55555, dst_port=443
        )
        result = parse_vxlan_packet(pkt)
        assert result is not None
        key, pkt_len = result
        assert key == ("10.0.1.100", "10.0.2.200", 6, 55555, 443)
        assert pkt_len == 60

    def test_basic_udp(self):
        pkt = _build_vxlan_packet(proto=17, src_port=53, dst_port=1024)
        result = parse_vxlan_packet(pkt)
        assert result is not None
        key, _ = result
        assert key[2] == 17
        assert key[3] == 53
        assert key[4] == 1024

    def test_icmp_no_ports(self):
        pkt = _build_vxlan_packet(proto=1)  # ICMP
        result = parse_vxlan_packet(pkt)
        assert result is not None
        key, _ = result
        assert key[2] == 1
        assert key[3] == 0
        assert key[4] == 0

    def test_too_short_vxlan(self):
        assert parse_vxlan_packet(b"\x00" * 5) is None

    def test_too_short_eth(self):
        # 8 bytes VXLAN + only 10 bytes (not enough for eth)
        assert parse_vxlan_packet(b"\x00" * 18) is None

    def test_non_ipv4_ethertype(self):
        pkt = _build_vxlan_packet()
        # Overwrite ethertype to IPv6 (0x86DD)
        pkt = bytearray(pkt)
        pkt[8 + 12] = 0x86
        pkt[8 + 13] = 0xDD
        assert parse_vxlan_packet(bytes(pkt)) is None

    def test_too_short_ip(self):
        # VXLAN(8) + ETH(14) + only 15 bytes of IP
        pkt = b"\x00" * 8 + b"\x00" * 12 + struct.pack("!H", 0x0800) + b"\x00" * 15
        assert parse_vxlan_packet(pkt) is None

    def test_invalid_ihl(self):
        pkt = bytearray(_build_vxlan_packet())
        # Set IHL to 3 (invalid, min is 5)
        pkt[8 + 14] = (4 << 4) | 3
        assert parse_vxlan_packet(bytes(pkt)) is None


@pytest.mark.skipif(not os.path.isfile(SO_PATH), reason="fast_parse.so not compiled")
class TestCParser:
    @pytest.fixture(autouse=True)
    def load_lib(self):
        self.lib = ctypes.CDLL(SO_PATH)
        self.lib.parse_vxlan_packet.argtypes = [
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.POINTER(_CFlowResult),
        ]
        self.lib.parse_vxlan_packet.restype = ctypes.c_int
        self.lib.ip_to_str.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_int]
        self.lib.ip_to_str.restype = None

    def _parse(self, data: bytes):
        result = _CFlowResult()
        rc = self.lib.parse_vxlan_packet(data, len(data), ctypes.byref(result))
        return rc, result

    def _ip_str(self, ip_u32: int) -> str:
        buf = ctypes.create_string_buffer(16)
        self.lib.ip_to_str(ip_u32, buf, 16)
        return buf.value.decode()

    def test_basic_tcp(self):
        pkt = _build_vxlan_packet(
            src_ip="10.0.1.100", dst_ip="10.0.2.200", proto=6, src_port=55555, dst_port=443
        )
        rc, result = self._parse(pkt)
        assert rc == 0
        assert self._ip_str(result.src_ip) == "10.0.1.100"
        assert self._ip_str(result.dst_ip) == "10.0.2.200"
        assert result.protocol == 6
        assert result.src_port == 55555
        assert result.dst_port == 443
        assert result.pkt_len == 60

    def test_basic_udp(self):
        pkt = _build_vxlan_packet(proto=17, src_port=53, dst_port=1024)
        rc, result = self._parse(pkt)
        assert rc == 0
        assert result.protocol == 17
        assert result.src_port == 53
        assert result.dst_port == 1024

    def test_icmp_no_ports(self):
        pkt = _build_vxlan_packet(proto=1)
        rc, result = self._parse(pkt)
        assert rc == 0
        assert result.protocol == 1
        assert result.src_port == 0
        assert result.dst_port == 0

    def test_too_short(self):
        rc, _ = self._parse(b"\x00" * 5)
        assert rc == -1

    def test_non_ipv4(self):
        pkt = bytearray(_build_vxlan_packet())
        pkt[8 + 12] = 0x86
        pkt[8 + 13] = 0xDD
        rc, _ = self._parse(bytes(pkt))
        assert rc == -1

    def test_invalid_ihl(self):
        pkt = bytearray(_build_vxlan_packet())
        pkt[8 + 14] = (4 << 4) | 3
        rc, _ = self._parse(bytes(pkt))
        assert rc == -1


@pytest.mark.skipif(not os.path.isfile(SO_PATH), reason="fast_parse.so not compiled")
class TestParserEquivalence:
    """Ensure C and Python parsers produce identical results."""

    @pytest.fixture(autouse=True)
    def load_lib(self):
        self.lib = ctypes.CDLL(SO_PATH)
        self.lib.parse_vxlan_packet.argtypes = [
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.POINTER(_CFlowResult),
        ]
        self.lib.parse_vxlan_packet.restype = ctypes.c_int
        self.lib.ip_to_str.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_int]
        self.lib.ip_to_str.restype = None

    def _c_parse(self, data: bytes):
        result = _CFlowResult()
        rc = self.lib.parse_vxlan_packet(data, len(data), ctypes.byref(result))
        if rc != 0:
            return None
        buf = ctypes.create_string_buffer(16)
        self.lib.ip_to_str(result.src_ip, buf, 16)
        src_ip = buf.value.decode()
        self.lib.ip_to_str(result.dst_ip, buf, 16)
        dst_ip = buf.value.decode()
        return (src_ip, dst_ip, result.protocol, result.src_port, result.dst_port), result.pkt_len

    @pytest.mark.parametrize(
        "proto,sport,dport",
        [(6, 80, 443), (17, 53, 1024), (1, 0, 0), (6, 0, 0), (17, 65535, 65535)],
    )
    def test_equivalence(self, proto, sport, dport):
        pkt = _build_vxlan_packet(
            src_ip="192.168.1.1", dst_ip="172.16.0.1", proto=proto, src_port=sport, dst_port=dport
        )
        py_result = parse_vxlan_packet(pkt)
        c_result = self._c_parse(pkt)
        assert py_result == c_result

    def test_equivalence_invalid_packets(self):
        invalid_packets = [
            b"",
            b"\x00" * 5,
            b"\x00" * 20,
        ]
        for pkt in invalid_packets:
            assert parse_vxlan_packet(pkt) is None
            result = _CFlowResult()
            rc = self.lib.parse_vxlan_packet(pkt, len(pkt), ctypes.byref(result))
            assert rc == -1
