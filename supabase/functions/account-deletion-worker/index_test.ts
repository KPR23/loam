import { requireAppleRevocationSuccess } from "../_shared/apple_revoke.ts";

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
