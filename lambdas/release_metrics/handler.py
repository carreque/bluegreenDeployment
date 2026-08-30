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
from datetime import UTC, datetime

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
# why an unrecognised name is logged rather than raised. The runbook's step 7
# reads the real set out of CloudWatch after the first deployment; if these are
# wrong the fix is one line here, with these tests already around it.
SUCCEEDED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_COMPLETED"})
FAILED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_FAILED"})

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

    # Subject is capped at 100 characters by SNS and a longer one is rejected
    # outright, which would turn a deployment failure into a collector failure.
    _client("sns").publish(TopicArn=topic_arn, Subject=subject[:100], Message=message)
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

    if "ROLLBACK" in event_name or "back" in reason.lower():
        _put(METRIC_DEPLOYMENT_ROLLED_BACK, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment ROLLED BACK — {service}",
            f"ECS rolled production back.\n\nevent: {event_name}\nreason: {reason}\n"
            f"deployment: {detail.get('deploymentId', 'unknown')}\n\n"
            f"{_deployment_console_url(event)}\n",
        )
        return {"handled": True, "outcome": "rolled_back"}

    if event_name in FAILED_EVENTS:
        _put(METRIC_DEPLOYMENT_FAILED, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment FAILED — {service}",
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
    # Task 4. Deliberately a no-op rather than absent: _handle_ecs already calls
    # it at the one point in the sequence where it has to run (plan D7), so the
    # ordering is established by the task that can be tested for it.
    return None


def _handle_codepipeline(event: dict) -> dict[str, object]:
    LOGGER.info("codepipeline event received; Task 3 implements the outcomes")
    return {"handled": False}


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
