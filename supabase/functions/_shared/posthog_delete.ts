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
  await response.body?.cancel();
  // PostHog queues the deletion and answers 202, also when no person exists
  // because the user never opted in to analytics.
  if (response.status === 200 || response.status === 202) return;
  if (response.status === 401 || response.status === 403) throw new Error("posthog_client_configuration");
  throw new Error(`posthog_delete_http_${response.status}`);
}
