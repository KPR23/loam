export const PRO_ENTITLEMENT = "loam_pro";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type ProState = { active: boolean; expiresAt: string | null };

type Entitlement = { expires_date?: string | null; grace_period_expires_date?: string | null };

// RevenueCat's v1 subscriber lists expired entitlements too. A null expiry is a
// lifetime purchase; a billing grace period keeps Pro until it ends.
export function proStateFrom(
  subscriber: { entitlements?: Record<string, Entitlement> } | undefined,
  now = new Date(),
): ProState {
  const entitlement = subscriber?.entitlements?.[PRO_ENTITLEMENT];
  if (!entitlement) return { active: false, expiresAt: null };
  if (entitlement.expires_date == null) return { active: true, expiresAt: null };
  const ends = [entitlement.expires_date, entitlement.grace_period_expires_date]
    .filter((value): value is string => typeof value === "string")
    .map((value) => new Date(value))
    .filter((date) => !Number.isNaN(date.getTime()));
  if (ends.length === 0) return { active: false, expiresAt: null };
  const latest = new Date(Math.max(...ends.map((date) => date.getTime())));
  return latest > now ? { active: true, expiresAt: latest.toISOString() } : { active: false, expiresAt: null };
}

// Loam logs customers in with their lowercase Supabase user ID. Anonymous
// RevenueCat IDs belong to no account and are skipped.
export function accountIdsInWebhook(body: unknown): string[] {
  const event = (body as { event?: Record<string, unknown> } | null)?.event;
  if (!event) return [];
  const candidates = [
    event.app_user_id,
    event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : []),
    ...(Array.isArray(event.transferred_from) ? event.transferred_from : []),
    ...(Array.isArray(event.transferred_to) ? event.transferred_to : []),
  ];
  return [...new Set(candidates.filter((id): id is string => typeof id === "string" && UUID_PATTERN.test(id)))];
}

export function isAccountId(value: string): boolean {
  return UUID_PATTERN.test(value);
}

export async function fetchProState(
  accountId: string,
  apiKey: string,
  fetcher: typeof fetch = fetch,
  timeoutMs = 10_000,
): Promise<ProState> {
  const response = await fetcher(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(accountId)}`, {
    headers: { "authorization": `Bearer ${apiKey}`, "accept": "application/json" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`revenuecat_subscriber_http_${response.status}`);
  }
  const payload = await response.json() as { subscriber?: { entitlements?: Record<string, Entitlement> } };
  return proStateFrom(payload.subscriber);
}

// Constant-time comparison for the webhook's shared Authorization value.
export function matchesSecret(received: string, expected: string): boolean {
  const a = new TextEncoder().encode(received), b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  for (let index = 0; index < b.length; index++) difference |= (a[index] ?? 0) ^ b[index];
  return expected.length > 0 && difference === 0;
}
