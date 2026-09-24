import { requireAppleRevocationSuccess } from "../_shared/apple_revoke.ts";
import { deletePostHogPerson } from "../_shared/posthog_delete.ts";

async function expectFailure(response: Response, expectedCode: string): Promise<void> {
  try {
    await requireAppleRevocationSuccess(response);
  } catch (error) {
    if (error instanceof Error && error.message === expectedCode) return;
    throw new Error(`Expected ${expectedCode}, got ${String(error)}`);
  }
  throw new Error(`Expected ${expectedCode}, got success`);
}

Deno.test("Apple 200 confirms revocation or a previously invalid token", async () => {
  await requireAppleRevocationSuccess(new Response(null, { status: 200 }));
});

Deno.test("Apple invalid_client is a configuration failure, never success", async () => {
  await expectFailure(new Response(JSON.stringify({ error: "invalid_client" }), { status: 400 }), "apple_client_configuration");
});

Deno.test("Apple invalid_request is classified as a retryable request failure", async () => {
  await expectFailure(new Response(JSON.stringify({ error: "invalid_request" }), { status: 400 }), "apple_revoke_invalid_request");
});

Deno.test("unknown Apple 400 responses are failures, never successful revocations", async () => {
  await expectFailure(new Response(JSON.stringify({ error: "unsupported_error" }), { status: 400 }), "apple_revoke_rejected_400");
});

Deno.test("Apple service failures remain retryable failures", async () => {
  await expectFailure(new Response(null, { status: 503 }), "apple_revoke_http_503");
});

const postHogConfig = { host: "https://eu.posthog.com", projectId: "216307", apiKey: "phx_test" };

function postHogResponding(status: number, requests: Request[] = []): typeof fetch {
  return (input, init) => {
    requests.push(new Request(input, init));
    return Promise.resolve(new Response(null, { status }));
  };
}

async function expectPostHogFailure(status: number, expectedCode: string): Promise<void> {
  try {
    await deletePostHogPerson("user", postHogConfig, postHogResponding(status));
  } catch (error) {
    if (error instanceof Error && error.message === expectedCode) return;
    throw new Error(`Expected ${expectedCode}, got ${String(error)}`);
  }
  throw new Error(`Expected ${expectedCode}, got success`);
}

Deno.test("PostHog deletion removes the person with events and recordings by lowercase user ID", async () => {
  const requests: Request[] = [];
  await deletePostHogPerson("7C9E6679-7425-40DE-944B-E07FC1F90AE7", postHogConfig, postHogResponding(202, requests));
  const request = requests[0];
  if (request.url !== "https://eu.posthog.com/api/projects/216307/persons/bulk_delete/") throw new Error(request.url);
  if (request.headers.get("authorization") !== "Bearer phx_test") throw new Error("missing bearer key");
  const body = await request.json();
  if (JSON.stringify(body) !== JSON.stringify({ distinct_ids: ["7c9e6679-7425-40de-944b-e07fc1f90ae7"], delete_events: true, delete_recordings: true })) {
    throw new Error(JSON.stringify(body));
  }
});

Deno.test("PostHog key rejections are configuration failures, never success", async () => {
  await expectPostHogFailure(401, "posthog_client_configuration");
  await expectPostHogFailure(403, "posthog_client_configuration");
});

Deno.test("PostHog service failures remain retryable failures", async () => {
  await expectPostHogFailure(503, "posthog_delete_http_503");
});
