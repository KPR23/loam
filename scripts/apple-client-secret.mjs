#!/usr/bin/env node
// Prints a new Sign in with Apple client secret for APPLE_CLIENT_SECRET, valid for 180 days
// (Apple's limit is six months). docs/account-deletion-runbook.md says where it goes.
//
//   node scripts/apple-client-secret.mjs ~/.appstoreconnect/private_keys/AuthKey_GXS83A2F8N.p8
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const TEAM_ID = "XXJA67J9AN";
const CLIENT_ID = "app.loam.Loam";

const keyPath = process.argv[2];
// Apple names each downloaded key AuthKey_<key ID>.p8.
const keyId = keyPath && basename(keyPath).match(/^AuthKey_([A-Z0-9]{10})\.p8$/)?.[1];
if (!keyId) {
  console.error("usage: node scripts/apple-client-secret.mjs <path to AuthKey_KEYID.p8>");
  process.exit(1);
}

const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const header = { alg: "ES256", kid: keyId };
const claims = { iss: TEAM_ID, iat: now, exp: now + 180 * 86_400, aud: "https://appleid.apple.com", sub: CLIENT_ID };
const unsigned = `${base64url(header)}.${base64url(claims)}`;
// JWS wants the raw r||s signature rather than DER.
const signature = sign("sha256", Buffer.from(unsigned), { key: createPrivateKey(readFileSync(keyPath)), dsaEncoding: "ieee-p1363" });
process.stdout.write(`${unsigned}.${signature.toString("base64url")}`);
