import { appleClientSecretExpiry, appleClientSecretNeedsRenewal } from "../_shared/apple_client_secret.ts";

function clientSecret(payload: unknown): string {
  const encode = (value: unknown) => btoa(JSON.stringify(value)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${encode({ alg: "ES256", kid: "TESTKEY" })}.${encode(payload)}.signature`;
}

const now = new Date("2026-10-03T12:00:00Z");
const inDays = (days: number) => Math.floor(now.getTime() / 1000) + days * 86_400;

Deno.test("reads the expiry of an Apple client secret", () => {
  const expiry = appleClientSecretExpiry(clientSecret({ iss: "TEAM", exp: inDays(90) }));
  if (expiry?.getTime() !== inDays(90) * 1000) throw new Error(`Unexpected expiry ${expiry}`);
});

Deno.test("a secret with more than thirty days left needs no renewal", () => {
  if (appleClientSecretNeedsRenewal(clientSecret({ exp: inDays(31) }), now)) throw new Error("Flagged a valid secret");
});

Deno.test("a secret within thirty days of expiry needs renewal", () => {
  if (!appleClientSecretNeedsRenewal(clientSecret({ exp: inDays(29) }), now)) throw new Error("Missed an expiring secret");
});

Deno.test("an expired secret needs renewal", () => {
  if (!appleClientSecretNeedsRenewal(clientSecret({ exp: inDays(-1) }), now)) throw new Error("Missed an expired secret");
});

Deno.test("a missing or unreadable secret needs renewal", () => {
  for (const secret of [undefined, "", "not-a-jwt", clientSecret({ iss: "TEAM" })]) {
    if (!appleClientSecretNeedsRenewal(secret, now)) throw new Error(`Accepted ${secret}`);
  }
});
