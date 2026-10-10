// Minimal APNs client: ES256 provider tokens over HTTP/2 (fetch negotiates it).

export interface ApnsConfig {
  keyP8: string;
  keyId: string;
  teamId: string;
  topic: string;
}

export type ApnsOutcome = "sent" | "dead" | "retry" | "failed";

const HOSTS = { sandbox: "https://api.sandbox.push.apple.com", production: "https://api.push.apple.com" } as const;
// Apple rejects provider tokens older than an hour and newer than 20 minutes is the minimum reuse rule.
const TOKEN_TTL_MS = 50 * 60_000;

function base64Url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

let cached: { token: string; issuedAt: number; keyId: string } | null = null;

export async function providerToken(config: ApnsConfig, now = Date.now()): Promise<string> {
  if (cached && cached.keyId === config.keyId && now - cached.issuedAt < TOKEN_TTL_MS) return cached.token;
  const header = base64Url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64Url(JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) }));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await importKey(config.keyP8),
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const token = `${header}.${claims}.${base64Url(new Uint8Array(signature))}`;
  cached = { token, issuedAt: now, keyId: config.keyId };
  return token;
}

export function resetProviderToken(): void {
  cached = null;
}

// 410 and the BadDeviceToken family mean the token will never work again.
const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

export function classifyApnsResponse(status: number, reason?: string): ApnsOutcome {
  if (status === 200) return "sent";
  if (status === 410 || (reason && DEAD_REASONS.has(reason))) return "dead";
  if (status === 429 || status >= 500 || reason === "ExpiredProviderToken") return "retry";
  return "failed";
}

export async function sendApns(
  config: ApnsConfig,
  device: { token: string; environment: "sandbox" | "production" },
  payload: unknown,
  options: { collapseId?: string } = {},
): Promise<ApnsOutcome> {
  const send = async () => {
    const headers: Record<string, string> = {
      authorization: `bearer ${await providerToken(config)}`,
      "apns-topic": config.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3 * 86_400),
    };
    if (options.collapseId) headers["apns-collapse-id"] = options.collapseId;
    const response = await fetch(`${HOSTS[device.environment]}/3/device/${device.token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
    let reason: string | undefined;
    if (response.status !== 200) reason = (await response.json().catch(() => ({}))).reason;
    else await response.body?.cancel();
    return { status: response.status, reason };
  };
  try {
    let result = await send();
    // An expired provider token is ours to refresh, once.
    if (result.reason === "ExpiredProviderToken") {
      resetProviderToken();
      result = await send();
    }
    return classifyApnsResponse(result.status, result.reason);
  } catch {
    return "retry";
  }
}
