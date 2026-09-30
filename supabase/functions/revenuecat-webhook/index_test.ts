import { accountIdsInWebhook, fetchProState, matchesSecret, proStateFrom } from "../_shared/revenuecat.ts";

const now = new Date("2026-09-30T12:00:00Z");
const account = "5481122e-1e46-4b1c-8453-a55a4cf21189";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

Deno.test("a lifetime purchase is active with no expiry", () => {
  assertEquals(proStateFrom({ entitlements: { loam_pro: { expires_date: null } } }, now), { active: true, expiresAt: null });
});

Deno.test("a running subscription is active until it expires", () => {
  assertEquals(
    proStateFrom({ entitlements: { loam_pro: { expires_date: "2026-10-30T12:00:00Z" } } }, now),
    { active: true, expiresAt: "2026-10-30T12:00:00.000Z" },
  );
});

Deno.test("an expired subscription is inactive", () => {
  assertEquals(proStateFrom({ entitlements: { loam_pro: { expires_date: "2026-09-01T00:00:00Z" } } }, now), { active: false, expiresAt: null });
});

Deno.test("a billing grace period keeps Pro until it ends", () => {
  assertEquals(
    proStateFrom({ entitlements: { loam_pro: { expires_date: "2026-09-29T00:00:00Z", grace_period_expires_date: "2026-10-05T00:00:00Z" } } }, now),
    { active: true, expiresAt: "2026-10-05T00:00:00.000Z" },
  );
});

Deno.test("other entitlements never grant Pro", () => {
  assertEquals(proStateFrom({ entitlements: { other: { expires_date: null } } }, now), { active: false, expiresAt: null });
  assertEquals(proStateFrom(undefined, now), { active: false, expiresAt: null });
});

Deno.test("webhooks sync every account they name, skipping anonymous IDs", () => {
  const other = "8b8f3c6a-f7f1-4691-a9ae-d9ada30d6796";
  assertEquals(accountIdsInWebhook({ event: { app_user_id: account, original_app_user_id: "$RCAnonymousID:abc", aliases: [account, "$RCAnonymousID:abc"] } }), [account]);
  assertEquals(accountIdsInWebhook({ event: { type: "TRANSFER", transferred_from: [account], transferred_to: [other] } }), [account, other]);
  assertEquals(accountIdsInWebhook(null), []);
});

Deno.test("the webhook secret must match exactly and cannot be empty", () => {
  assertEquals(matchesSecret("Bearer abc", "Bearer abc"), true);
  assertEquals(matchesSecret("Bearer abd", "Bearer abc"), false);
  assertEquals(matchesSecret("Bearer ab", "Bearer abc"), false);
  assertEquals(matchesSecret("", ""), false);
});

Deno.test("a RevenueCat failure throws so the caller retries", async () => {
  const failing = (() => Promise.resolve(new Response("{}", { status: 500 }))) as typeof fetch;
  try {
    await fetchProState(account, "sk_test", failing);
  } catch (error) {
    if (error instanceof Error && error.message === "revenuecat_subscriber_http_500") return;
    throw error;
  }
  throw new Error("Expected a failure");
});
