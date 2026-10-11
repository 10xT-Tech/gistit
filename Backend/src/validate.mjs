// Shape check for proxied Messages API requests. The proxy only relays what the app itself sends —
// a single user turn (text + optional image) with a template's system prompt and output schema — so
// a leaked session token can't turn it into a general-purpose Claude endpoint.

export class RequestError extends Error {
  constructor(message) {
    super(message);
    this.status = 400;
  }
}

const ALLOWED_FIELDS = new Set(['model', 'max_tokens', 'system', 'messages', 'output_config', 'stream', 'thinking']);
const ALLOWED_EFFORT = new Set(['low', 'medium', 'high']);

/** The app's Settings connection probe (HealthCheckTemplate): fixed prompt, tiny output, no value to abuse. */
export function isHealthCheck(body) {
  const content = body.messages?.[0]?.content;
  return body.system === 'Reply with {"ok": true}.'
    && body.max_tokens <= 1024
    && Array.isArray(content) && content.length === 1
    && content[0].type === 'text' && content[0].text === 'ping';
}

// Translations are free on every plan. They're recognised by the fixed opening of their template's
// system prompt (Domain/Prompts/Templates.swift — Tests/UseCaseContractTests pins these openings).
// Everything else — explanations, Say it, and anything unrecognised — is metered for free users.
const FREE_PROMPT_OPENINGS = [
  'The user wants to understand some text.',          // Get it → Translate   (UnderstandTemplate)
  'You read text from a photo.',                      // See it → Translate   (PhotoBlocksTemplate)
  'Enrich an English expression for a study card.',   // saving a study card  (EnrichCardTemplate)
];

/** A request that never counts against the free plan: a translation or the Settings probe. */
export function isFreeRequest(body) {
  return isHealthCheck(body) || FREE_PROMPT_OPENINGS.some((opening) => body.system.startsWith(opening));
}

export function validateMessagesRequest(body, { allowedModels, maxTokensCap }) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) throw new RequestError('body must be a JSON object');
  for (const key of Object.keys(body)) {
    if (!ALLOWED_FIELDS.has(key)) throw new RequestError(`field not allowed: ${key}`);
  }
  if (!allowedModels.includes(body.model)) throw new RequestError(`model not allowed: ${body.model}`);
  if (!Number.isInteger(body.max_tokens) || body.max_tokens < 1 || body.max_tokens > maxTokensCap) {
    throw new RequestError(`max_tokens must be 1…${maxTokensCap}`);
  }
  if (typeof body.system !== 'string') throw new RequestError('system must be a string');
  if (body.stream !== undefined && typeof body.stream !== 'boolean') throw new RequestError('stream must be a boolean');
  if (body.thinking !== undefined) {
    const type = body.thinking?.type;
    if (type !== 'adaptive' && type !== 'between_tools') throw new RequestError('thinking type not allowed');
  }
  if (body.output_config !== undefined) {
    const { effort, format, ...rest } = body.output_config ?? {};
    if (Object.keys(rest).length) throw new RequestError('output_config field not allowed');
    if (effort !== undefined && !ALLOWED_EFFORT.has(effort)) throw new RequestError('effort not allowed');
    if (format !== undefined && format?.type !== 'json_schema') throw new RequestError('format must be json_schema');
  }
  if (!Array.isArray(body.messages) || body.messages.length !== 1) throw new RequestError('exactly one message is allowed');
  const [message] = body.messages;
  if (message?.role !== 'user' || !Array.isArray(message.content) || message.content.length === 0) {
    throw new RequestError('the message must be a user turn with content blocks');
  }
  let images = 0;
  for (const block of message.content) {
    if (block?.type === 'text' && typeof block.text === 'string') continue;
    if (block?.type === 'image' && block.source?.type === 'base64') {
      images += 1;
      continue;
    }
    throw new RequestError('only text and base64 image blocks are allowed');
  }
  if (images > 1) throw new RequestError('at most one image is allowed');
  return body;
}
