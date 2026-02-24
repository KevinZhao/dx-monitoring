"""Tests for enricher.py — IPEnricher cache and lookup logic."""

import os
import sys
import threading
import time
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "probe"))

from enricher import IPEnricher


def _make_ec2_response(instances):
    """Build a mock describe_instances response page."""
    reservations = []
    for inst in instances:
        reservations.append({
            "Instances": [{
                "InstanceId": inst["id"],
                "Tags": [{"Key": k, "Value": v} for k, v in inst.get("tags", {}).items()],
                "NetworkInterfaces": [{
                    "PrivateIpAddresses": [{"PrivateIpAddress": ip} for ip in inst["ips"]]
                }],
            }]
        })
    return {"Reservations": reservations}


@pytest.fixture
def mock_ec2():
    """Patch boto3.client to return a mock EC2 client."""
    with patch("enricher.boto3") as mock_boto:
        mock_client = MagicMock()
        mock_boto.client.return_value = mock_client
        yield mock_client


class TestEnrich:
    def test_enrich_known_ip(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-abc123",
            "tags": {"Name": "web-server", "Owner": "team-a"},
            "ips": ["10.0.1.10"],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        result = enricher.enrich("10.0.1.10")
        assert result["ip"] == "10.0.1.10"
        assert result["instance_id"] == "i-abc123"
        assert result["name"] == "web-server"
        assert result["owner"] == "team-a"

    def test_enrich_unknown_ip(self, mock_ec2):
        mock_ec2.get_paginator.return_value.paginate.return_value = [
            {"Reservations": []}
        ]

        enricher = IPEnricher()
        enricher._refresh()

        result = enricher.enrich("10.0.99.99")
        assert result == {"ip": "10.0.99.99"}

    def test_enrich_no_tags(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-notags",
            "tags": {},
            "ips": ["10.0.1.20"],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        result = enricher.enrich("10.0.1.20")
        assert result["instance_id"] == "i-notags"
        assert result["name"] == ""
        assert result["asg"] == ""


class TestEnrichMany:
    def test_enrich_many_mixed(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-abc",
            "tags": {"Name": "srv-a"},
            "ips": ["10.0.1.1"],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        results = enricher.enrich_many(["10.0.1.1", "10.0.2.2"])
        assert len(results) == 2
        assert results[0]["instance_id"] == "i-abc"
        assert results[1] == {"ip": "10.0.2.2"}

    def test_enrich_many_empty(self, mock_ec2):
        mock_ec2.get_paginator.return_value.paginate.return_value = [
            {"Reservations": []}
        ]

        enricher = IPEnricher()
        enricher._refresh()

        results = enricher.enrich_many([])
        assert results == []


class TestMultipleIPs:
    def test_instance_with_multiple_ips(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-multi",
            "tags": {"Name": "multi-nic"},
            "ips": ["10.0.1.1", "10.0.1.2"],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        r1 = enricher.enrich("10.0.1.1")
        r2 = enricher.enrich("10.0.1.2")
        assert r1["instance_id"] == "i-multi"
        assert r2["instance_id"] == "i-multi"


class TestRefreshFailure:
    def test_refresh_failure_keeps_stale_cache(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-old",
            "tags": {"Name": "old-data"},
            "ips": ["10.0.1.1"],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        # Second refresh fails
        mock_ec2.get_paginator.return_value.paginate.side_effect = Exception("API error")
        enricher._refresh()

        # Stale cache should still work
        result = enricher.enrich("10.0.1.1")
        assert result["instance_id"] == "i-old"


class TestVpcFilter:
    def test_vpc_filter_applied(self, mock_ec2):
        mock_ec2.get_paginator.return_value.paginate.return_value = [
            {"Reservations": []}
        ]

        enricher = IPEnricher()
        enricher._vpc_id = "vpc-test123"
        enricher._refresh()

        mock_ec2.get_paginator.return_value.paginate.assert_called_once_with(
            Filters=[{"Name": "vpc-id", "Values": ["vpc-test123"]}]
        )

    def test_no_vpc_filter_when_empty(self, mock_ec2):
        mock_ec2.get_paginator.return_value.paginate.return_value = [
            {"Reservations": []}
        ]

        enricher = IPEnricher()
        enricher._vpc_id = ""
        enricher._refresh()

        mock_ec2.get_paginator.return_value.paginate.assert_called_once_with(
            Filters=[]
        )


class TestThreadSafety:
    def test_concurrent_enrich_no_crash(self, mock_ec2):
        page = _make_ec2_response([{
            "id": "i-concurrent",
            "tags": {"Name": "concurrent"},
            "ips": [f"10.0.1.{i}" for i in range(50)],
        }])
        mock_ec2.get_paginator.return_value.paginate.return_value = [page]

        enricher = IPEnricher()
        enricher._refresh()

        errors = []

        def reader():
            try:
                for _ in range(100):
                    enricher.enrich_many([f"10.0.1.{i}" for i in range(50)])
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=reader) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        assert len(errors) == 0
