// PostHog identifies app users by their lowercase Supabase user ID. Deleting
// by that distinct ID removes the person with their events and recordings.
export async function deletePostHogPerson(
  distinctId: string,
  config: { host: string; projectId: string; apiKey: string },
  fetcher: typeof fetch = fetch,
): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  let response: Response;
  try {
    response = await fetcher(`${config.host}/api/projects/${config.projectId}/persons/bulk_delete/`, {
      method: "POST", signal: controller.signal,
      headers: { "authorization": `Bearer ${config.apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ distinct_ids: [distinctId.toLowerCase()], delete_events: true, delete_recordings: true }),
    });
  } finally { clearTimeout(timeout); }
  if (response.status === 401 || response.status === 403) {
    await response.body?.cancel();
    throw new Error("posthog_client_configuration");
  }
  if (response.status !== 202) {
    await response.body?.cancel();
    throw new Error(`posthog_delete_http_${response.status}`);
  }
  // PostHog accepts the request and erases events and recordings in the
  // background, which can take days; completion wording says so. It also
  // answers 202 when no person exists because the user never opted in.
  const summary = await response.json().catch(() => null) as { deletion_errors?: unknown } | null;
  if (!summary || !Array.isArray(summary.deletion_errors)) throw new Error("posthog_delete_unreadable_response");
  if (summary.deletion_errors.length > 0) throw new Error("posthog_delete_partial");
}
