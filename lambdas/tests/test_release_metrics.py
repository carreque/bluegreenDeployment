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


ECS_EVENT = {
    "source": "aws.ecs",
    "region": "us-east-1",
    "resources": [
        "arn:aws:ecs:us-east-1:590184028094:service/"
        "bgd-us-east-1-prod-cluster/bgd-us-east-1-prod-api"
    ],
    "detail": {"eventName": "SERVICE_DEPLOYMENT_COMPLETED", "deploymentId": "ecs-svc/123"},
}


def _ecs(event_name, reason=None):
    detail = dict(ECS_EVENT["detail"], eventName=event_name)
    if reason is not None:
        detail["reason"] = reason
    return dict(ECS_EVENT, detail=detail)


def _metric_names(fake):
    return [put["MetricData"][0]["MetricName"] for put in fake.puts]


def test_a_completed_deployment_is_counted_and_sends_no_email(clients):
    result = h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert result["outcome"] == "succeeded"
    assert h.METRIC_DEPLOYMENT_SUCCEEDED in _metric_names(clients["cloudwatch"])
    # D16: success is not an alert.
    assert clients["sns"].published == []


def test_a_failed_deployment_is_counted_and_emails(clients):
    result = h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="tasks failed to start"), None)

    assert result["outcome"] == "failed"
    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_FAILED]

    published = clients["sns"].published[0]
    assert "FAILED" in published["Subject"]
    assert "bgd-us-east-1-prod-api" in published["Message"]
    assert "tasks failed to start" in published["Message"]


def test_a_rollback_is_counted_once_and_never_also_as_a_failure(clients):
    # D8. If ECS emits both a rollback event and a FAILED event for the same
    # deployment — likely, and unconfirmable offline — emitting both here would
    # double the change-failure-rate numerator. Each event yields one outcome.
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="rolling back to revision 4"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_ROLLED_BACK]
    assert h.METRIC_DEPLOYMENT_FAILED not in _metric_names(clients["cloudwatch"])


def test_a_rollback_is_detected_from_the_event_name_too(clients):
    # The reason string is free text and may not mention it; the event name may.
    # Either is enough, because missing a rollback is the failure this phase's
    # whole rollback story rests on.
    h.handler(_ecs("SERVICE_DEPLOYMENT_ROLLBACK_IN_PROGRESS"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_ROLLED_BACK]


def test_the_metric_carries_the_environment_dimension(clients):
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    dimensions = clients["cloudwatch"].puts[0]["MetricData"][0]["Dimensions"]
    assert dimensions == [{"Name": "Environment", "Value": "prod"}]


def test_an_alert_without_a_topic_arn_logs_rather_than_raising(clients, monkeypatch, caplog):
    # D9 again: a missing topic is a misconfiguration, but raising would retry
    # and alarm, and the alarm's own delivery path is the topic that is missing.
    monkeypatch.delenv("BGD_ALERT_TOPIC_ARN", raising=False)

    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    assert clients["sns"].published == []
    assert "BGD_ALERT_TOPIC_ARN" in caplog.text
