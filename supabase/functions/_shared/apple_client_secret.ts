// Apple caps a Sign in with Apple client secret at six months. Once it lapses,
// account deletion can no longer revoke the user's Apple token, so the monitor
// warns ahead of time. Renewal: docs/account-deletion-runbook.md.
export const APPLE_CLIENT_SECRET_WARNING_DAYS = 30;

export function appleClientSecretExpiry(secret: string | undefined): Date | null {
  const payload = secret?.split(".")[1];
  if (!payload) return null;
  try {
    const { exp } = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/"))) as { exp?: unknown };
    return typeof exp === "number" ? new Date(exp * 1000) : null;
  } catch {
    return null;
  }
}

// A missing or unreadable secret counts as expiring: deletion would fail either way.
export function appleClientSecretNeedsRenewal(secret: string | undefined, now = new Date()): boolean {
  const expiry = appleClientSecretExpiry(secret);
  return !expiry || expiry.getTime() - now.getTime() < APPLE_CLIENT_SECRET_WARNING_DAYS * 86_400_000;
}
