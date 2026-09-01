"use strict";

// The page learns which build served it rather than being told at render time.
// Phase 12 plan, D4: this is what lets a tab left open on the production
// listener re-tint itself the moment ECS moves the listener rule, with no
// reload — the difference between discovering a shift and watching one.

const FAST_INTERVAL_MS = 2000;
const SLOW_INTERVAL_MS = 10000;
const FAILURES_BEFORE_BACKOFF = 3;

// The closed set from the server's Literal (D6). A token the CSS has no rule
// for would drop the page to the "unknown" palette rather than to no palette.
const COLORS = ["blue", "green", "slate"];

let consecutiveFailures = 0;
let pollTimer = null;
let currentSha = "unknown";
// True for the whole duration of an in-flight tick(), including the awaited
// /version fetch. pollTimer stays null for that whole span too, because
// scheduleNext() only runs as tick() is finishing — so without this flag a
// visibilitychange firing mid-fetch would find nothing for restartPolling()
// to clearTimeout, and would start a second, independent tick() chain that no
// later restartPolling() could ever fully cancel: the poll rate would creep
// upward for the life of the tab, the opposite of D7.
let tickInFlight = false;

// account_id -> the git_sha this tab was talking to when it POSTed. Client
// side only, and labelled as such: the API does not record which build created
// an account, and this page does not pretend otherwise. Plan D13.
const openedHere = new Map();

function setText(id, value) {
  document.getElementById(id).textContent = value;
}

function showError(message) {
  const box = document.getElementById("error");
  box.textContent = message;
  box.hidden = message === "";
}

function applyVersion(body) {
  const color = COLORS.includes(body.release_color) ? body.release_color : "unknown";
  document.documentElement.setAttribute("data-release-color", color);
  currentSha = body.git_sha;

  // textContent everywhere, including for values the server produced. The
  // habit is the mitigation; an exception "just here" is how the habit ends.
  setText("release-color", body.release_color);
  setText("version", body.version);
  setText("git-sha", body.git_sha);
  setText("image-digest", body.image_digest);
  setText("last-checked", new Date().toLocaleTimeString());
}

async function refresh() {
  const response = await fetch("/version", { cache: "no-store" });
  if (!response.ok) {
    throw new Error("/version answered " + response.status);
  }
  applyVersion(await response.json());
}

function scheduleNext() {
  const backedOff = consecutiveFailures >= FAILURES_BEFORE_BACKOFF;
  pollTimer = window.setTimeout(tick, backedOff ? SLOW_INTERVAL_MS : FAST_INTERVAL_MS);
}

async function tick() {
  // Held for the whole function, across the await below, so restartPolling()
  // can tell "a fetch is in flight" apart from "nothing is scheduled" — see
  // tickInFlight's declaration for what goes wrong without it.
  tickInFlight = true;
  try {
    // D7. Every poll is an ALB request and one access-log line; a hidden tab
    // pays that for nobody. A page left open across a teardown backs off too,
    // rather than hammering a dead load balancer until somebody closes it.
    if (document.visibilityState !== "visible") {
      return;
    }

    try {
      await refresh();
      consecutiveFailures = 0;
    } catch (error) {
      consecutiveFailures += 1;
      // A stalled poller must be visible rather than silently stale: an old
      // colour on screen with no sign that it stopped updating is the one
      // failure mode that looks exactly like success.
      setText("last-checked", "unreachable");
    }
  } finally {
    // Runs for every exit from the try above, including the early return.
    // scheduleNext() lands before tickInFlight clears, so the two flags this
    // module relies on — "a timer is scheduled" and "a tick is in flight" —
    // are never both false at once and never both true at once.
    scheduleNext();
    tickInFlight = false;
  }
}

function restartPolling() {
  if (tickInFlight) {
    // A tick() is already awaiting /version, so pollTimer is null right now —
    // there is nothing here to clearTimeout, and calling tick() again would
    // start the second chain described above. The in-flight tick's own
    // finally block will call scheduleNext() when it finishes, which keeps
    // the single chain alive without this call doing anything.
    return;
  }
  if (pollTimer !== null) {
    window.clearTimeout(pollTimer);
    pollTimer = null;
  }
  tick();
}

function accountRow(account) {
  const row = document.createElement("li");
  row.className = "account";

  const name = document.createElement("span");
  name.className = "account__name";
  // Stored, user-supplied, and rendered back. textContent is the whole
  // mitigation, and it is why this row is assembled rather than formatted.
  name.textContent = account.owner_name;

  const balance = document.createElement("span");
  balance.className = "account__balance";
  balance.textContent = account.balance_minor + " " + account.currency;

  row.append(name, balance);

  const sha = openedHere.get(account.account_id);
  if (sha !== undefined) {
    const origin = document.createElement("span");
    origin.className = "account__origin";
    origin.textContent = "opened via build " + sha + " · this tab";
    row.append(origin);
  }

  return row;
}

async function listAccounts() {
  const response = await fetch("/api/accounts", { cache: "no-store" });
  if (!response.ok) {
    throw new Error("/api/accounts answered " + response.status);
  }
  const body = await response.json();

  const list = document.getElementById("accounts");
  list.replaceChildren(...body.items.map(accountRow));
  document.getElementById("accounts-empty").hidden = body.items.length > 0;
}

async function submitAccount(event) {
  // The CSP says form-action 'none'; this is what makes that consistent
  // rather than broken. The form is never natively submitted.
  event.preventDefault();
  showError("");

  const form = event.currentTarget;
  const payload = {
    owner_name: form.elements.owner_name.value,
    currency: form.elements.currency.value,
    initial_balance_minor: Number(form.elements.initial_balance_minor.value),
  };

  let response;
  try {
    response = await fetch("/api/accounts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      cache: "no-store",
    });
  } catch (error) {
    showError("the API could not be reached");
    return;
  }

  if (!response.ok) {
    // The API answers application/problem+json (errors.py), so the page can
    // surface the real message instead of "something went wrong".
    const problem = await response.json().catch(() => ({}));
    showError(problem.detail || "the API answered " + response.status);
    return;
  }

  const account = await response.json();
  openedHere.set(account.account_id, currentSha);
  form.reset();

  try {
    await listAccounts();
  } catch (error) {
    showError("the account was created, but the list could not be reloaded");
  }
}

document.getElementById("create-account").addEventListener("submit", submitAccount);
document.addEventListener("visibilitychange", restartPolling);

restartPolling();
listAccounts().catch(() => showError("the account list could not be loaded"));
