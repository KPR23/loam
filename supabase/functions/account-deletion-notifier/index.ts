import { createClient } from "npm:@supabase/supabase-js@2.116.0";

async function decryptAddress(value: string): Promise<string> {
  const encodedKey = Deno.env.get("DELETION_CREDENTIAL_ENCRYPTION_KEY");
  if (!encodedKey) throw new Error("encryption_key_missing");
  const [encodedIV, encodedCiphertext] = value.split(".");
  if (!encodedIV || !encodedCiphertext) throw new Error("encrypted_address_invalid");
  const rawKey = Uint8Array.from(atob(encodedKey), (character) => character.charCodeAt(0));
  if (rawKey.byteLength !== 32) throw new Error("encryption_key_invalid");
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: Uint8Array.from(atob(encodedIV), (character) => character.charCodeAt(0)) },
    key,
    Uint8Array.from(atob(encodedCiphertext), (character) => character.charCodeAt(0)),
  );
  return new TextDecoder().decode(plaintext);
}

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left), b = encoder.encode(right);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return mismatch === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  const expectedKey = Deno.env.get("DELETION_NOTIFIER_KEY");
  if (!expectedKey) return Response.json({ error: "notifier_not_configured" }, { status: 503 });
  if (!constantTimeEqual(request.headers.get("X-Deletion-Notifier-Key") ?? "", expectedKey)) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const resendKey = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("DELETION_EMAIL_FROM");
  if (!url || !serviceKey || !resendKey || !from) return Response.json({ error: "notifier_not_configured" }, { status: 503 });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: notices, error } = await admin.rpc("claim_account_deletion_notifications");
  if (error) return Response.json({ error: "notification_claim_failed" }, { status: 500 });
  let processed = 0, retrying = 0, failed = 0;
  for (const notice of notices ?? []) {
    let success = false, errorCode = "delivery_failed";
    try {
      const recipient = await decryptAddress(notice.encrypted_address);
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `loam-account-deletion-${notice.operation_id}`,
        },
        body: JSON.stringify({
          from,
          to: [recipient],
          subject: "Your Loam account deletion is complete",
          text: "Your Loam account deletion has finished. Your account and private account data have been removed. Shared expenses remain available to their other participants.",
        }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) errorCode = `email_provider_http_${response.status}`;
      else success = true;
    } catch (error) {
      errorCode = error instanceof Error && error.message.startsWith("encryption_") ? error.message : "email_delivery_error";
    }
    const { data: transitionApplied, error: finishError } = await admin.rpc("finish_account_deletion_notification", {
      p_operation_id: notice.operation_id, p_lease_token: notice.lease_token,
      p_success: success, p_error_code: success ? null : errorCode,
    });
    if (finishError || transitionApplied !== true) {
      failed++;
      console.error(JSON.stringify({ event: "deletion_email_transition_failed", operation_id: notice.operation_id, code: "notification_transition_failed" }));
    } else if (success) {
      processed++;
      console.info(JSON.stringify({ event: "deletion_email_delivered", operation_id: notice.operation_id }));
    } else {
      retrying++;
      console.error(JSON.stringify({ event: "deletion_email_retry", operation_id: notice.operation_id, code: errorCode }));
    }
  }
  const { error: heartbeatError } = await admin.rpc("record_account_deletion_notifier_heartbeat", {
    p_processed: processed, p_retrying: retrying, p_failed: failed,
  });
  if (heartbeatError) return Response.json({ error: "notifier_heartbeat_failed" }, { status: 500 });
  return Response.json({ processed, retrying, failed });
});
