"""Release metrics collector.

One handler, two event sources. EventBridge delivers CodePipeline execution
state changes and production ECS deployment state changes; this writes the
ReleaseMetrics series behind the dashboard and publishes the failures worth an
email.

See docs/phases/phase9/2026-08-30-phase-09-implementation-plan.md D3 through D9.

THE RETURN CONTRACT IS THE OPPOSITE OF lifecycle_hook's, deliberately. That
handler raises when in doubt, because its failure mode is promoting a bad build.
This one returns, because it is invoked asynchronously: an exception is retried
and then fires the errors alarm, so raising on an event shape it merely does not
recognise would make the alarm that says "the collector is broken" fire
continuously while the collector worked perfectly. It raises only when an AWS
call it needs actually fails, which is what that alarm is for. Plan D9.

boto3 only, from the Lambda managed runtime — nothing vendored, so the
deployment package is still one file and terraform test still really builds it.
Plan D10 and F2.
"""

import json
import logging
import os
from datetime import UTC, datetime, timedelta

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DEFAULT_NAMESPACE = "ReleaseMetrics"
DEFAULT_ENVIRONMENT = "prod"
DEFAULT_MTTR_LOOKBACK_DAYS = 30

METRIC_DEPLOYMENT_SUCCEEDED = "DeploymentSucceeded"
METRIC_DEPLOYMENT_FAILED = "DeploymentFailed"
METRIC_DEPLOYMENT_ROLLED_BACK = "DeploymentRolledBack"
METRIC_LEAD_TIME = "LeadTimeSeconds"
METRIC_RECOVERY_TIME = "RecoveryTimeSeconds"
METRIC_PIPELINE_FAILED = "PipelineFailed"

# The starting vocabulary, not a confirmed one. Which names ECS emits for a
# BLUE_GREEN deployment is a runtime contract with no offline source of truth
# (plan F3), which is exactly why the EventBridge rule does not filter on it and
# why an unrecognised name is logged rather than raised. The runbook's step 8
# reads the real set out of CloudWatch after the first deployment; if these are
# wrong the fix is one line here, with these tests already around it.
SUCCEEDED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_COMPLETED"})
FAILED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_FAILED"})

# Matched against the free-text `reason`, because a rollback may arrive shaped
# like a failure and the event name alone is not enough. Three phrasings rather
# than one substring: ECS writes "rolling back", "rolled back" and "rollback"
# in different messages, and no single substring covers all three. Emphatically
# NOT the bare word "back" — that also matches "backend", "backoff" and
# "fallback", any of which would misfile an ordinary failure as a rollback and
# quietly remove it from the change-failure-rate numerator D8 is about.
ROLLBACK_REASON_PHRASES = ("rollback", "rolling back", "rolled back")

# One client per service per container, created on first use rather than at
# import. Two reasons: a module-level boto3.client() runs during the cold start
# of every invocation whether or not that call is needed, and — the reason that
# matters here — a dict is a seam a test can write a fake into without patching
# boto3 itself or installing a mocking library. lambdas/ deliberately has no
# such dependency, the same choice app/ made for DynamoDB.
_CLIENTS: dict[str, object] = {}


def _client(service: str):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _now() -> datetime:
    """The clock, as a function so tests can freeze it.

    Aware and UTC, because every timestamp boto3 returns is aware and comparing
    an aware datetime to a naive one raises TypeError — during an alert.
    """
    return datetime.now(UTC)


def _namespace() -> str:
    return os.environ.get("BGD_METRIC_NAMESPACE", DEFAULT_NAMESPACE)


def _environment() -> str:
    return os.environ.get("BGD_ENVIRONMENT", DEFAULT_ENVIRONMENT)


def _put(metric_name: str, value: float, unit: str, dimensions: dict[str, str]) -> None:
    """One datapoint. Raises if CloudWatch refuses — see the module docstring."""
    _client("cloudwatch").put_metric_data(
        Namespace=_namespace(),
        MetricData=[
            {
                "MetricName": metric_name,
                "Value": value,
                "Unit": unit,
                # Sorted so two invocations with the same dimensions produce the
                # same list. CloudWatch treats dimension sets as unordered, but
                # a stable order makes the log line and the test comparable.
                "Dimensions": [
                    {"Name": name, "Value": val} for name, val in sorted(dimensions.items())
                ],
            }
        ],
    )
    LOGGER.info("metric %s=%s %s %s", metric_name, value, unit, dimensions)


def _alert(subject: str, message: str) -> None:
    topic_arn = os.environ.get("BGD_ALERT_TOPIC_ARN")
    if not topic_arn:
        LOGGER.error("BGD_ALERT_TOPIC_ARN is not set; this alert is lost: %s", subject)
        return

    # SNS documents Subject as ASCII text, less than 100 characters — strictly
    # less than, so the cap here is 99, not 100. A subject over the limit, or
    # one carrying a non-ASCII character (an em dash is idiomatic in this
    # project's prose and easy to reintroduce here), is rejected outright by
    # Publish, which would turn a deployment failure into a collector failure.
    _client("sns").publish(TopicArn=topic_arn, Subject=subject[:99], Message=message)
    LOGGER.info("alert published subject=%s", subject)


def _service_name(event: dict) -> str:
    """The service the event is about, from the resource ARN's last segment."""
    resources = event.get("resources") or []
    return resources[0].rsplit("/", 1)[-1] if resources else "unknown"


def _deployment_console_url(event: dict) -> str:
    region = event.get("region", "us-east-1")
    resources = event.get("resources") or []
    if not resources:
        return ""
    cluster, service = resources[0].split("/")[-2:]
    return (
        f"https://{region}.console.aws.amazon.com/ecs/v2/clusters/{cluster}"
        f"/services/{service}/deployments?region={region}"
    )


def _handle_ecs(event: dict) -> dict[str, object]:
    """One ECS deployment event to at most one outcome metric.

    Checked in this order — rollback, failed, succeeded — because a rollback
    event may also be shaped like a failure and each event must yield exactly
    one outcome. Plan D8.
    """
    detail = event.get("detail") or {}
    event_name = (detail.get("eventName") or "").upper()
    reason = detail.get("reason") or ""
    service = _service_name(event)
    dimensions = {"Environment": _environment()}

    lowered_reason = reason.lower()
    if "ROLLBACK" in event_name or any(p in lowered_reason for p in ROLLBACK_REASON_PHRASES):
        _put(METRIC_DEPLOYMENT_ROLLED_BACK, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment ROLLED BACK - {service}",
            f"ECS rolled production back.\n\nevent: {event_name}\nreason: {reason}\n"
            f"deployment: {detail.get('deploymentId', 'unknown')}\n\n"
            f"{_deployment_console_url(event)}\n",
        )
        return {"handled": True, "outcome": "rolled_back"}

    if event_name in FAILED_EVENTS:
        _put(METRIC_DEPLOYMENT_FAILED, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment FAILED - {service}",
            f"A production deployment failed.\n\nevent: {event_name}\nreason: {reason}\n"
            f"deployment: {detail.get('deploymentId', 'unknown')}\n\n"
            f"{_deployment_console_url(event)}\n",
        )
        return {"handled": True, "outcome": "failed"}

    if event_name in SUCCEEDED_EVENTS:
        # Before the success is written, and the order is load-bearing. Plan D7.
        _emit_recovery_time(_now(), dimensions)
        _put(METRIC_DEPLOYMENT_SUCCEEDED, 1, "Count", dimensions)
        return {"handled": True, "outcome": "succeeded"}

    LOGGER.info("ignoring ECS eventName=%s", event_name or "<absent>")
    return {"handled": False, "eventName": event_name}


def _emit_recovery_time(now: datetime, dimensions: dict[str, str]) -> None:
    """Emit RecoveryTimeSeconds when this success ends an outage.

    Stateless by construction: the metric store is the state store. One query
    returns both series newest-first; if the most recent failure has no success
    after it, this success is the recovery.

    MUST be called before DeploymentSucceeded is written for this event, or the
    query finds the datapoint it is about to create. Plan D7.
    """
    lookback_days = int(os.environ.get("BGD_MTTR_LOOKBACK_DAYS", DEFAULT_MTTR_LOOKBACK_DAYS))
    metric_dimensions = [
        {"Name": name, "Value": value} for name, value in sorted(dimensions.items())
    ]

    def query(query_id: str, metric_name: str) -> dict:
        return {
            "Id": query_id,
            "MetricStat": {
                "Metric": {
                    "Namespace": _namespace(),
                    "MetricName": metric_name,
                    "Dimensions": metric_dimensions,
                },
                # 300s, not 60s. CloudWatch only retains 1-minute datapoints
                # for 15 days but keeps 5-minute datapoints for 63 — and the
                # window below is 30 days by default, so a 60s period would
                # make a failure older than about two weeks invisible to this
                # query, silently. At the multi-day scale a recovery is
                # actually measured on, rounding to the nearest 5 minutes is
                # immaterial; losing half the lookback window is not.
                "Period": 300,
                "Stat": "Sum",
            },
        }

    response = _client("cloudwatch").get_metric_data(
        StartTime=now - timedelta(days=lookback_days),
        EndTime=now,
        # Newest first, so Timestamps[0] of each series is the latest datapoint
        # and neither series has to be sorted here.
        ScanBy="TimestampDescending",
        MetricDataQueries=[
            query("failed", METRIC_DEPLOYMENT_FAILED),
            query("succeeded", METRIC_DEPLOYMENT_SUCCEEDED),
        ],
    )

    latest = {
        result["Id"]: (result["Timestamps"][0] if result.get("Timestamps") else None)
        for result in response.get("MetricDataResults", [])
    }
    last_failure, last_success = latest.get("failed"), latest.get("succeeded")

    if last_failure is None:
        LOGGER.info("no failure in the last %s days; this success recovers nothing", lookback_days)
        return

    if last_success is not None and last_success >= last_failure:
        LOGGER.info("the last failure was already followed by a success; not a recovery")
        return

    _put(METRIC_RECOVERY_TIME, (now - last_failure).total_seconds(), "Seconds", dimensions)


def _pipeline_console_url(event: dict, pipeline: str, execution_id: str) -> str:
    region = event.get("region", "us-east-1")
    return (
        f"https://{region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/"
        f"{pipeline}/executions/{execution_id}?region={region}"
    )


def _resolved_app_scope(execution: dict) -> str:
    """The APP_SCOPE this execution actually ran with, from the same
    GetPipelineExecution response the caller already fetched.

    Absent from `variables` when the run was started by the git trigger, which
    supplies no execution variables and takes the pipeline's own default —
    the same fact Phase 7 §F4 recorded for DEPLOY_SCOPE, and
    `var.app_scope_default` names it `all`. Absent therefore means "all", NOT
    "skip": the trigger-started run IS a full production deployment, and it is
    the main case this metric exists for. Treating a missing variable as
    "skip" would make every merge-triggered production deployment emit no
    lead time at all.
    """
    for variable in execution.get("variables") or []:
        if variable.get("name") == "APP_SCOPE":
            return variable.get("resolvedValue") or "all"
    return "all"


def _release_started_at(
    client, pipeline: str, execution_id: str, execution: dict
) -> tuple[datetime | None, str]:
    """When the change that just reached production was made.

    Preferred: the source revision's commit timestamp, which makes the metric
    genuinely commit-to-production. Whether CodePipeline populates it for a
    CodeConnections source cannot be confirmed offline (plan F4), so the fallback
    is the execution's own start time — merge-to-production. The caller logs
    which basis was used; the metric is emitted either way, because a lead-time
    series that silently stops when an API field is absent is worse than one
    whose basis is written beside it.
    """
    for revision in execution.get("artifactRevisions") or []:
        created = revision.get("created")
        if created is not None:
            return created, "commit"

    summaries = client.list_pipeline_executions(pipelineName=pipeline, maxResults=100)
    for summary in summaries.get("pipelineExecutionSummaries") or []:
        if summary.get("pipelineExecutionId") == execution_id and summary.get("startTime"):
            return summary["startTime"], "merge"

    return None, "unavailable"


def _emit_lead_time(pipeline: str, execution_id: str, now: datetime) -> None:
    client = _client("codepipeline")
    execution = client.get_pipeline_execution(
        pipelineName=pipeline, pipelineExecutionId=execution_id
    ).get("pipelineExecution", {})

    # Lead time is commit-to-PRODUCTION (plan D6), and reaching SUCCEEDED is
    # only that moment when the run actually deployed. APP_SCOPE=build and
    # APP_SCOPE=staging both stop the pipeline before the Prod stage — its
    # before_entry condition evaluates to SKIP, not the stage failing — so
    # those runs also finish SUCCEEDED without ever touching production.
    scope = _resolved_app_scope(execution)
    if scope != "all":
        LOGGER.info(
            "APP_SCOPE=%s execution=%s; this run never reached production, no lead time emitted",
            scope,
            execution_id,
        )
        return

    started_at, basis = _release_started_at(client, pipeline, execution_id, execution)

    if started_at is None:
        LOGGER.warning(
            "lead_time_basis=unavailable execution=%s; no lead time emitted", execution_id
        )
        return

    seconds = (now - started_at).total_seconds()
    LOGGER.info("lead_time_basis=%s seconds=%s execution=%s", basis, seconds, execution_id)
    _put(METRIC_LEAD_TIME, seconds, "Seconds", {"Environment": _environment()})


def _handle_codepipeline(event: dict) -> dict[str, object]:
    detail = event.get("detail") or {}
    pipeline = detail.get("pipeline") or "unknown"
    state = detail.get("state")
    execution_id = detail.get("execution-id")

    if state == "FAILED":
        _put(METRIC_PIPELINE_FAILED, 1, "Count", {"PipelineName": pipeline})
        _alert(
            f"[bgd] Pipeline FAILED - {pipeline}",
            f"A pipeline execution failed.\n\nexecution: {execution_id}\n\n"
            f"{_pipeline_console_url(event, pipeline, execution_id)}\n",
        )
        return {"handled": True, "outcome": "failed"}

    if state == "SUCCEEDED" and pipeline == os.environ.get("BGD_APP_PIPELINE"):
        _emit_lead_time(pipeline, execution_id, _now())
        return {"handled": True, "outcome": "succeeded"}

    LOGGER.info("ignoring pipeline=%s state=%s", pipeline, state)
    return {"handled": False, "state": state}


def handler(event: dict, context: object) -> dict[str, object]:
    """Route one EventBridge event to the handler for its source."""
    LOGGER.info("event=%s", json.dumps(event, default=str))

    source = (event or {}).get("source")

    if source == "aws.ecs":
        return _handle_ecs(event)
    if source == "aws.codepipeline":
        return _handle_codepipeline(event)

    LOGGER.warning("ignoring unrecognised source=%s", source)
    return {"handled": False, "source": source}
