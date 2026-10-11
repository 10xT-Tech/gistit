// DynamoDB access. One table, string partition key `pk`, TTL attribute `expiresAt` (epoch seconds):
//   challenge#<value>        one-time App Attest challenge (5 min)
//   key#<keyId>              attested key: public key PEM, environment, assertion counter
//   rate#<scope>#<window>    rate-limit counter for one fixed window
//   cooldown#<scope>         last use of a "1 per N seconds" allowance (sliding)
//   sub#<originalTxId>       App Attest key ids sharing one subscription

import {
  DynamoDBClient, PutItemCommand, DeleteItemCommand, GetItemCommand, UpdateItemCommand,
  ConditionalCheckFailedException,
} from '@aws-sdk/client-dynamodb';

const db = new DynamoDBClient({});
const table = () => process.env.TABLE_NAME;
const nowSeconds = () => Math.floor(Date.now() / 1000);

export async function putChallenge(value, ttlSeconds) {
  await db.send(new PutItemCommand({
    TableName: table(),
    Item: { pk: { S: `challenge#${value}` }, expiresAt: { N: String(nowSeconds() + ttlSeconds) } },
  }));
}

/** Deletes the challenge; true only if it existed and hadn't expired (TTL deletion is lazy). */
export async function consumeChallenge(value) {
  try {
    const { Attributes } = await db.send(new DeleteItemCommand({
      TableName: table(),
      Key: { pk: { S: `challenge#${value}` } },
      ConditionExpression: 'attribute_exists(pk)',
      ReturnValues: 'ALL_OLD',
    }));
    return Number(Attributes?.expiresAt?.N ?? 0) > nowSeconds();
  } catch (e) {
    if (e instanceof ConditionalCheckFailedException) return false;
    throw e;
  }
}

/** Stores a newly attested key. Never overwrites an existing key id. */
export async function putKey(keyId, { publicKeyPem, environment }) {
  try {
    await db.send(new PutItemCommand({
      TableName: table(),
      Item: {
        pk: { S: `key#${keyId}` },
        publicKeyPem: { S: publicKeyPem },
        environment: { S: environment },
        counter: { N: '0' },
        createdAt: { N: String(nowSeconds()) },
      },
      ConditionExpression: 'attribute_not_exists(pk)',
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionalCheckFailedException) return false;
    throw e;
  }
}

export async function getKey(keyId) {
  const { Item } = await db.send(new GetItemCommand({
    TableName: table(),
    Key: { pk: { S: `key#${keyId}` } },
    ConsistentRead: true,
  }));
  if (!Item) return null;
  return {
    publicKeyPem: Item.publicKeyPem.S,
    environment: Item.environment.S,
    counter: Number(Item.counter.N),
    revoked: Item.revoked?.BOOL === true,
  };
}

/** Advances the assertion counter; false if another request already used an equal/higher one. */
export async function advanceCounter(keyId, counter) {
  try {
    await db.send(new UpdateItemCommand({
      TableName: table(),
      Key: { pk: { S: `key#${keyId}` } },
      UpdateExpression: 'SET #c = :n',
      ConditionExpression: 'attribute_exists(pk) AND #c < :n',
      ExpressionAttributeNames: { '#c': 'counter' },
      ExpressionAttributeValues: { ':n': { N: String(counter) } },
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionalCheckFailedException) return false;
    throw e;
  }
}

/**
 * Fixed-window rate limit: counts one hit for `scope` in the current window of `windowSeconds`.
 * Returns false (and counts nothing) once `limit` hits are already recorded in this window.
 */
export async function hit(scope, limit, windowSeconds) {
  const window = Math.floor(nowSeconds() / windowSeconds);
  try {
    await db.send(new UpdateItemCommand({
      TableName: table(),
      Key: { pk: { S: `rate#${scope}#${windowSeconds}#${window}` } },
      UpdateExpression: 'ADD #n :one SET expiresAt = :exp',
      ConditionExpression: 'attribute_not_exists(#n) OR #n < :limit',
      ExpressionAttributeNames: { '#n': 'hits' },
      ExpressionAttributeValues: {
        ':one': { N: '1' },
        ':limit': { N: String(limit) },
        ':exp': { N: String((window + 1) * windowSeconds + 60) },
      },
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionalCheckFailedException) return false;
    throw e;
  }
}

/**
 * Sliding "one use per `seconds`" allowance. Returns `{ ok: true, claimedAt }` when the use is
 * granted, or `{ ok: false, retryAfter }` (seconds until the next use).
 */
export async function claimCooldown(scope, seconds) {
  const now = Date.now();
  try {
    await db.send(new UpdateItemCommand({
      TableName: table(),
      Key: { pk: { S: `cooldown#${scope}` } },
      UpdateExpression: 'SET lastAt = :now, expiresAt = :exp',
      ConditionExpression: 'attribute_not_exists(lastAt) OR lastAt <= :cutoff',
      ExpressionAttributeValues: {
        ':now': { N: String(now) },
        ':cutoff': { N: String(now - seconds * 1000) },
        ':exp': { N: String(Math.floor(now / 1000) + seconds + 60) },
      },
    }));
    return { ok: true, claimedAt: now };
  } catch (e) {
    if (!(e instanceof ConditionalCheckFailedException)) throw e;
    const { Item } = await db.send(new GetItemCommand({
      TableName: table(), Key: { pk: { S: `cooldown#${scope}` } }, ConsistentRead: true,
    }));
    const lastAt = Number(Item?.lastAt?.N ?? now);
    return { ok: false, retryAfter: Math.max(1, Math.ceil((lastAt + seconds * 1000 - now) / 1000)) };
  }
}

/** Gives back a granted use (the upstream call failed), unless a newer use replaced it. */
export async function releaseCooldown(scope, claimedAt) {
  try {
    await db.send(new DeleteItemCommand({
      TableName: table(),
      Key: { pk: { S: `cooldown#${scope}` } },
      ConditionExpression: 'lastAt = :claimed',
      ExpressionAttributeValues: { ':claimed': { N: String(claimedAt) } },
    }));
  } catch (e) {
    if (!(e instanceof ConditionalCheckFailedException)) throw e;
  }
}

/** Records `keyId` as a device of the subscription; false once `maxDevices` other keys use it. */
export async function bindSubscriptionDevice(originalTransactionId, keyId, maxDevices) {
  try {
    await db.send(new UpdateItemCommand({
      TableName: table(),
      Key: { pk: { S: `sub#${originalTransactionId}` } },
      UpdateExpression: 'ADD keyIds :key',
      ConditionExpression: 'attribute_not_exists(keyIds) OR contains(keyIds, :k) OR size(keyIds) < :max',
      ExpressionAttributeValues: {
        ':key': { SS: [keyId] },
        ':k': { S: keyId },
        ':max': { N: String(maxDevices) },
      },
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionalCheckFailedException) return false;
    throw e;
  }
}
