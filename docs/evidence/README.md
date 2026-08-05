# docs/evidence — Phase 11

Captured proof that rollback works. Three demonstrations, each driven by hand and
each using a **genuinely broken commit** on a dedicated branch rather than a
simulated failure toggle — the evidence is only worth something if the failure is
real.

1. **Hook rejection** — `POST_TEST_TRAFFIC_SHIFT` fails and the bad build never
   receives production traffic.
2. **Alarm-triggered rollback during bake** — the 5xx rate breaches and ECS reverts
   automatically.
3. **Manual rollback** — redeploy the previous image digest.

Console screenshots are captured by hand; CloudWatch logs and CLI output are
collected alongside them here.
