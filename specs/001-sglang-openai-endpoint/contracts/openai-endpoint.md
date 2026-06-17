# Contract: External OpenAI-Compatible HTTPS Endpoint

The endpoint the deployment exposes to clients. All requests go through Caddy
over HTTPS on port 443 and MUST carry a valid API key.

## Base

- **Base URL**: `https://<PUBLIC_IP_or_DOMAIN>/v1`
- **Transport**: HTTPS only. Plain HTTP to the public address MUST NOT serve the
  inference API (connection refused or redirected to HTTPS).
- **Auth**: `Authorization: Bearer <API_KEY>` REQUIRED on every request.
- **Model id**: `Qwen/Qwen3.6-27B`

## Authentication contract

| Condition | Expected result |
|-----------|-----------------|
| Valid `Authorization: Bearer <key>` | Request served (2xx) |
| Missing `Authorization` header | `401 Unauthorized`, no inference |
| Wrong key | `401 Unauthorized`, no inference |
| Plain HTTP to public IP | Connection refused or 308 redirect to HTTPS; never serves inference unencrypted |

## POST /v1/chat/completions

Request (OpenAI-compatible):

```json
{
  "model": "Qwen/Qwen3.6-27B",
  "messages": [{ "role": "user", "content": "Hello" }],
  "max_tokens": 64
}
```

Success response: HTTP 200, OpenAI chat completion shape:

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "Qwen/Qwen3.6-27B",
  "choices": [
    { "index": 0, "message": { "role": "assistant", "content": "..." }, "finish_reason": "stop" }
  ],
  "usage": { "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0 }
}
```

## GET /v1/models

Returns the served model list including `Qwen/Qwen3.6-27B`. Requires the API key.

## Readiness

A readiness probe (e.g., `GET /health` via HTTPS, or `GET /v1/models`) MUST
succeed only after the model is loaded — distinct from the VM being powered on.

## Acceptance mapping

- FR-002, FR-009, FR-010, FR-016; User Story 1 acceptance scenarios 1–4.

## Example (self-signed TLS uses -k)

```bash
curl -k https://<PUBLIC_IP>/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Hello"}]}'
```
