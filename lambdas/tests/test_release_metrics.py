"""The release metrics collector.

Every test injects fake clients through handler._CLIENTS, so the suite makes no
network call and needs no AWS session — the same property lifecycle_hook's suite
has, reached by a different seam because this handler legitimately calls AWS.

lambdas/ deliberately carries no AWS mocking library, the same choice app/ made
for DynamoDB. The seam is a plain dict, so a fake is an ordinary class with the
three methods the handler calls and nothing else.
"""

from datetime import UTC, datetime

import pytest

from release_metrics import handler as h


class FakeCloudWatch:
    def __init__(self, metric_data_response=None):
        self.puts = []
        self.calls = []
        self._metric_data_response = metric_data_response or {"MetricDataResults": []}

    def put_metric_data(self, **kwargs):
        self.calls.append("put_metric_data")
        self.puts.append(kwargs)
        return {}

    def get_metric_data(self, **kwargs):
        self.calls.append("get_metric_data")
        self.get_metric_data_kwargs = kwargs
        return self._metric_data_response


class FakeSNS:
    def __init__(self):
        self.published = []

    def publish(self, **kwargs):
        self.published.append(kwargs)
        return {"MessageId": "fake"}


@pytest.fixture
def clients(monkeypatch):
    """Install fakes and a frozen clock; yield them for assertions."""
    cloudwatch, sns = FakeCloudWatch(), FakeSNS()
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": cloudwatch, "sns": sns})
    monkeypatch.setattr(h, "_now", lambda: datetime(2026, 8, 30, 12, 0, 0, tzinfo=UTC))
    monkeypatch.setenv("BGD_ALERT_TOPIC_ARN", "arn:aws:sns:us-east-1:590184028094:bgd-alerts")
    monkeypatch.setenv("BGD_APP_PIPELINE", "bgd-us-east-1-app-pipeline")
    return {"cloudwatch": cloudwatch, "sns": sns}


def test_an_unrecognised_source_is_ignored_rather_than_raised(clients):
    # D9. Raising here would retry, then fire the errors alarm, then email —
    # for an event the collector simply has no opinion about.
    result = h.handler({"source": "aws.s3", "detail": {}}, None)

    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []
    assert clients["sns"].published == []


def test_an_event_with_no_source_at_all_is_ignored(clients):
    assert h.handler({}, None)["handled"] is False


def test_the_ecs_source_routes_to_the_deployment_handler(clients):
    result = h.handler(
        {"source": "aws.ecs", "detail": {"eventName": "SERVICE_DEPLOYMENT_IN_PROGRESS"}},
        None,
    )

    # IN_PROGRESS arrives on every deployment because the rule deliberately
    # does not filter event names (D4). It must cost nothing but a log line.
    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []
