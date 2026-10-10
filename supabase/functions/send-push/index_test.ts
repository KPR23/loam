import { classifyApnsResponse, providerToken, resetProviderToken } from "../_shared/apns.ts";
import { notificationCategory, pushContent, type PushEvent } from "../_shared/push_content.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const viewer = "b0000000-0000-4000-8000-000000000001";
const event = (overrides: Partial<PushEvent>): PushEvent => ({
  kind: "shared", actor_id: "a0000000-0000-4000-8000-000000000001", actor_name: "Anna",
  recipient_id: viewer, recipient_name: "Ben", expense_id: "e0000000-0000-4000-8000-000000000001", repayment_id: null,
  expense_title: "Dinner", affected_share_minor: 2500, currency: "PLN", ...overrides,
});

Deno.test("every activity kind maps to a switch", () => {
  const kinds: Record<string, string> = {
    shared: "requests", proposal_created: "requests",
    accepted: "replies", rejected: "replies", proposal_accepted: "replies", proposal_rejected: "replies", auto_accepted: "replies",
    edited: "changes", participant_removed: "changes", deleted: "changes", proposal_superseded: "changes",
    repayment_recorded: "repayments", repayment_reversed: "repayments",
  };
  for (const [kind, category] of Object.entries(kinds)) {
    assertEquals(notificationCategory(kind), category);
    if (pushContent(event({ kind }), viewer) === null) throw new Error(`${kind} has no text`);
  }
});

Deno.test("an expense push names the expense and the actor", () => {
  assertEquals(pushContent(event({}), viewer), { title: "Dinner", body: "Anna shared this with you", category: "requests" });
  assertEquals(pushContent(event({ kind: "deleted" }), viewer)?.body, "Anna deleted this expense");
  assertEquals(pushContent(event({ kind: "participant_removed" }), viewer)?.body, "Anna removed you from this expense");
});

Deno.test("suggestion answers address the proposer", () => {
  assertEquals(pushContent(event({ kind: "proposal_accepted" }), viewer)?.body, "Anna accepted your changes");
  assertEquals(pushContent(event({ kind: "proposal_rejected", recipient_id: "c1", recipient_name: "Chris" }), viewer)?.body, "Anna declined Chris' changes");
  assertEquals(pushContent(event({ kind: "proposal_superseded", actor_name: "Chris" }), viewer)?.body, "Chris' suggested changes were replaced");
});

Deno.test("repayments carry the amount and ignore the expense title", () => {
  const recorded = pushContent(event({ kind: "repayment_recorded", expense_id: null, expense_title: "" }), viewer);
  assertEquals(recorded?.title, "Repayment");
  assertEquals(recorded?.category, "repayments");
  if (!/25,00/.test(recorded?.body ?? "")) throw new Error(`Amount missing: ${recorded?.body}`);
});

Deno.test("a blank title falls back and an unknown kind sends nothing", () => {
  assertEquals(pushContent(event({ expense_title: "  " }), viewer)?.title, "Expense");
  assertEquals(pushContent(event({ kind: "from_the_future" }), viewer), null);
});

Deno.test("APNs responses are classified for cleanup and retry", () => {
  assertEquals(classifyApnsResponse(200), "sent");
  assertEquals(classifyApnsResponse(410, "Unregistered"), "dead");
  assertEquals(classifyApnsResponse(400, "BadDeviceToken"), "dead");
  assertEquals(classifyApnsResponse(400, "DeviceTokenNotForTopic"), "dead");
  assertEquals(classifyApnsResponse(429, "TooManyRequests"), "retry");
  assertEquals(classifyApnsResponse(503), "retry");
  assertEquals(classifyApnsResponse(403, "InvalidProviderToken"), "failed");
});

Deno.test("the provider token is a reusable ES256 JWT", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  const config = { keyP8: pem, keyId: "ABC123DEFG", teamId: "TEAM123456", topic: "app.loam.Loam" };
  resetProviderToken();
  const now = Date.UTC(2026, 9, 10);
  const token = await providerToken(config, now);
  const [header, claims] = token.split(".").slice(0, 2).map((part) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/"))));
  assertEquals(header, { alg: "ES256", kid: "ABC123DEFG" });
  assertEquals(claims, { iss: "TEAM123456", iat: Math.floor(now / 1000) });
  assertEquals(await providerToken(config, now + 10 * 60_000), token);
  if (await providerToken(config, now + 55 * 60_000) === token) throw new Error("Stale provider token reused");
});
