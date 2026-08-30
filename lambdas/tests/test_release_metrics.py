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


@pytest.mark.parametrize("phrase", ["rollback", "rolling back", "rolled back"])
def test_each_rollback_reason_phrase_is_detected(clients, phrase):
    # D8. ROLLBACK_REASON_PHRASES has three entries because ECS writes three
    # different phrasings and no single substring covers all three. Only one
    # of them was ever exercised by a reason string before this test: deleting
    # either of the other two passed every other test in this file, because
    # the `any(...)` generator line is covered regardless of which phrase in
    # the tuple actually matched.
    reason = f"backend unhealthy, {phrase} to revision 4"
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason=reason), None)

    names = _metric_names(clients["cloudwatch"])
    assert h.METRIC_DEPLOYMENT_ROLLED_BACK in names
    assert h.METRIC_DEPLOYMENT_FAILED not in names


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


def test_the_namespace_and_environment_come_from_their_own_env_vars(clients, monkeypatch):
    # Both defaults happen to coincide with the Terraform defaults, which
    # means an overridden var.metric_namespace would today send metrics to the
    # wrong namespace — the IAM condition would deny the write, and nothing in
    # this suite would catch it, because no test until this one set either var.
    monkeypatch.setenv("BGD_METRIC_NAMESPACE", "SomeOtherNamespace")
    monkeypatch.setenv("BGD_ENVIRONMENT", "not-prod")

    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    put = clients["cloudwatch"].puts[0]
    assert put["Namespace"] == "SomeOtherNamespace"
    assert put["MetricData"][0]["Dimensions"] == [{"Name": "Environment", "Value": "not-prod"}]


def test_an_alert_without_a_topic_arn_logs_rather_than_raising(clients, monkeypatch, caplog):
    # D9 again: a missing topic is a misconfiguration, but raising would retry
    # and alarm, and the alarm's own delivery path is the topic that is missing.
    monkeypatch.delenv("BGD_ALERT_TOPIC_ARN", raising=False)

    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    assert clients["sns"].published == []
    assert "BGD_ALERT_TOPIC_ARN" in caplog.text


def test_an_ordinary_failure_whose_reason_merely_contains_back_is_not_a_rollback(clients):
    # "backend", "backoff" and "fallback" all contain "back". Matching that
    # bare substring would move a real failure out of the change-failure-rate
    # numerator and email the operator the wrong verdict. D8.
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="backend unhealthy, backoff limit"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_FAILED]
    assert "FAILED" in clients["sns"].published[0]["Subject"]


class FakeCodePipeline:
    def __init__(self, execution=None, summaries=None):
        self._execution = execution if execution is not None else {}
        self._summaries = summaries or []

    def get_pipeline_execution(self, **kwargs):
        self.get_kwargs = kwargs
        return {"pipelineExecution": self._execution}

    def list_pipeline_executions(self, **kwargs):
        self.list_kwargs = kwargs
        return {"pipelineExecutionSummaries": self._summaries}


def _pipeline_event(state, pipeline="bgd-us-east-1-app-pipeline", execution_id="exec-1"):
    return {
        "source": "aws.codepipeline",
        "region": "us-east-1",
        "detail": {"pipeline": pipeline, "state": state, "execution-id": execution_id},
    }


def test_a_failed_pipeline_is_counted_per_pipeline_and_emails(clients):
    result = h.handler(_pipeline_event("FAILED", pipeline="bgd-us-east-1-infra-pipeline"), None)

    assert result["outcome"] == "failed"
    datum = clients["cloudwatch"].puts[0]["MetricData"][0]
    assert datum["MetricName"] == h.METRIC_PIPELINE_FAILED
    # PipelineName, not Environment: this metric is about the pipeline, and the
    # infra pipeline is not an environment. Plan D5.
    assert datum["Dimensions"] == [
        {"Name": "PipelineName", "Value": "bgd-us-east-1-infra-pipeline"}
    ]
    assert "bgd-us-east-1-infra-pipeline" in clients["sns"].published[0]["Subject"]


def test_every_alert_subject_is_ascii(clients):
    # CRITICAL: SNS documents Publish's Subject as ASCII text, and a non-ASCII
    # subject makes the call raise InvalidParameterException outright. An em
    # dash is idiomatic in this project's prose and easy to reintroduce here;
    # this is what stops it. For the ECS FAILED path a raising Publish is
    # worse than a lost email: `_put` runs first, so EventBridge's two retries
    # would write DeploymentFailed three times for one failure, inflating
    # change failure rate, while the only mail that arrives is the watchdog
    # saying the collector raised.
    h.handler(_ecs("SERVICE_DEPLOYMENT_ROLLBACK_IN_PROGRESS"), None)
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="tasks failed to start"), None)
    h.handler(_pipeline_event("FAILED", pipeline="bgd-us-east-1-infra-pipeline"), None)

    assert len(clients["sns"].published) == 3
    for published in clients["sns"].published:
        assert published["Subject"].isascii()


def test_lead_time_uses_the_commit_timestamp_when_the_api_supplies_one(clients, monkeypatch):
    # This execution carries no "variables" key at all, which is also the
    # "APP_SCOPE is absent" case IMPORTANT 2 requires: a git-trigger-started
    # run supplies no execution variables and must still emit lead time.
    committed = datetime(2026, 8, 30, 10, 0, 0, tzinfo=UTC)  # two hours before _now
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(execution={"artifactRevisions": [{"created": committed}]}),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    datum = clients["cloudwatch"].puts[0]["MetricData"][0]
    assert datum["MetricName"] == h.METRIC_LEAD_TIME
    assert datum["Unit"] == "Seconds"
    assert datum["Value"] == 7200.0


def test_lead_time_is_emitted_when_app_scope_resolves_to_all(clients, monkeypatch):
    committed = datetime(2026, 8, 30, 10, 0, 0, tzinfo=UTC)
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(
            execution={
                "variables": [{"name": "APP_SCOPE", "resolvedValue": "all"}],
                "artifactRevisions": [{"created": committed}],
            }
        ),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts[0]["MetricData"][0]["MetricName"] == h.METRIC_LEAD_TIME


def test_no_lead_time_is_emitted_when_app_scope_stopped_before_production(
    clients, monkeypatch, caplog
):
    # IMPORTANT 2. codepipeline-app.tf's DeployStaging and Prod stages both
    # carry a before_entry condition with result = "SKIP", so a run scoped to
    # "build" or "staging" skips the deploy stages and still finishes
    # SUCCEEDED. Reaching SUCCEEDED is only reaching production when the
    # resolved APP_SCOPE is "all".
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(
            execution={
                "variables": [{"name": "APP_SCOPE", "resolvedValue": "build"}],
                "artifactRevisions": [{"created": datetime(2026, 8, 30, 10, 0, 0, tzinfo=UTC)}],
            }
        ),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts == []
    assert "APP_SCOPE=build" in caplog.text


def test_lead_time_falls_back_to_the_execution_start_time(clients, monkeypatch, caplog):
    # F4: whether CodeConnections populates artifactRevisions[].created cannot be
    # confirmed offline. Absent it, the number is merge-to-production rather than
    # commit-to-production, and the log says which.
    started = datetime(2026, 8, 30, 11, 30, 0, tzinfo=UTC)
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(
            execution={"artifactRevisions": [{"revisionId": "abc123"}]},
            summaries=[{"pipelineExecutionId": "exec-1", "startTime": started}],
        ),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts[0]["MetricData"][0]["Value"] == 1800.0
    assert "lead_time_basis=merge" in caplog.text


def test_lead_time_falls_back_scanning_past_a_non_matching_summary(clients, monkeypatch, caplog):
    # F4's likely real path in production: ListPipelineExecutions returns many
    # executions and this one's id is not the first. No prior test exercised
    # the loop's non-matching iteration in _release_started_at — a summary
    # whose id does not equal execution_id must be skipped, not returned.
    started = datetime(2026, 8, 30, 11, 30, 0, tzinfo=UTC)
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(
            execution={"artifactRevisions": [{"revisionId": "abc123"}]},
            summaries=[
                {
                    "pipelineExecutionId": "some-other-exec",
                    "startTime": datetime(2026, 8, 29, 0, 0, 0, tzinfo=UTC),
                },
                {"pipelineExecutionId": "exec-1", "startTime": started},
            ],
        ),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts[0]["MetricData"][0]["Value"] == 1800.0
    assert "lead_time_basis=merge" in caplog.text


def test_no_lead_time_is_emitted_when_neither_timestamp_exists(clients, monkeypatch):
    monkeypatch.setitem(h._CLIENTS, "codepipeline", FakeCodePipeline())

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts == []


def test_the_infra_pipeline_succeeding_produces_no_lead_time(clients, monkeypatch):
    # Lead time is commit-to-PRODUCTION. The infra pipeline deploys layers, not
    # the application, and counting it would measure a different thing under the
    # same name. Plan D6.
    monkeypatch.setitem(h._CLIENTS, "codepipeline", FakeCodePipeline())

    result = h.handler(_pipeline_event("SUCCEEDED", pipeline="bgd-us-east-1-infra-pipeline"), None)

    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []


def _series(metric_id, timestamps):
    return {"Id": metric_id, "Timestamps": list(timestamps), "Values": [1.0] * len(timestamps)}


def test_a_success_after_a_failure_emits_recovery_time(clients, monkeypatch):
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)  # one hour before _now
    monkeypatch.setattr(
        h,
        "_CLIENTS",
        {
            "cloudwatch": FakeCloudWatch(
                {"MetricDataResults": [_series("failed", [failed_at]), _series("succeeded", [])]}
            ),
            "sns": FakeSNS(),
        },
    )

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    names = _metric_names(h._CLIENTS["cloudwatch"])
    assert names == [h.METRIC_RECOVERY_TIME, h.METRIC_DEPLOYMENT_SUCCEEDED]
    assert h._CLIENTS["cloudwatch"].puts[0]["MetricData"][0]["Value"] == 3600.0


def test_the_lookback_runs_before_the_success_is_written(clients, monkeypatch):
    # Plan D7, and the single most breakable line in this handler. Written after,
    # the query finds the success just published, concludes it is the newest
    # datapoint, and every recovery measures zero — a flat MTTR line that looks
    # like excellent operations.
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)
    fake = FakeCloudWatch(
        {"MetricDataResults": [_series("failed", [failed_at]), _series("succeeded", [])]}
    )
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert fake.calls.index("get_metric_data") < fake.calls.index("put_metric_data")


def test_a_success_with_no_prior_failure_emits_no_recovery_time(clients):
    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_SUCCEEDED]


def test_a_second_success_after_the_recovery_emits_nothing_further(clients, monkeypatch):
    # The failure was already followed by a success, so this one recovers from
    # nothing. Without this branch every deployment after an outage reports an
    # ever-growing MTTR.
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)
    recovered_at = datetime(2026, 8, 30, 11, 30, 0, tzinfo=UTC)
    fake = FakeCloudWatch(
        {
            "MetricDataResults": [
                _series("failed", [failed_at]),
                _series("succeeded", [recovered_at]),
            ]
        }
    )
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert _metric_names(fake) == [h.METRIC_DEPLOYMENT_SUCCEEDED]


def test_the_lookback_window_is_configurable(clients, monkeypatch):
    monkeypatch.setenv("BGD_MTTR_LOOKBACK_DAYS", "7")
    fake = FakeCloudWatch()
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    window = fake.get_metric_data_kwargs
    assert (window["EndTime"] - window["StartTime"]).days == 7
    assert window["ScanBy"] == "TimestampDescending"
