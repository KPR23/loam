export async function requireAppleRevocationSuccess(response: Response): Promise<void> {
  if (response.status === 200) return;
  if (response.status === 400) {
    const payload = await response.json().catch(() => ({})) as { error?: unknown };
    if (payload.error === "invalid_client") throw new Error("apple_client_configuration");
    if (payload.error === "invalid_request") throw new Error("apple_revoke_invalid_request");
    throw new Error("apple_revoke_rejected_400");
  }
  throw new Error(`apple_revoke_http_${response.status}`);
}
