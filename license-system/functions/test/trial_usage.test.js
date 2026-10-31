const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const { Firestore } = require('@google-cloud/firestore');
const { consumeTrialUsage } = require('../trial_usage');

const db = new Firestore({
  projectId: process.env.GCLOUD_PROJECT || 'demo-nvpttt',
  databaseId: 'default',
});

after(() => db.terminate());

test('trial consumption is capped, idempotent, and ignores paid licenses', async () => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'Run this test with the Firestore emulator.');
  const suffix = crypto.randomBytes(4).toString('hex').toUpperCase();
  const deviceId = `SMS-${suffix.slice(0, 4)}-${suffix.slice(4)}`;
  const requestIds = Array.from({ length: 11 }, () => crypto.randomUUID());

  try {
    const first = await consumeTrialUsage({ db, deviceId, requestId: requestIds[0], maxTrialCount: 10 });
    const repeated = await consumeTrialUsage({ db, deviceId, requestId: requestIds[0], maxTrialCount: 10 });
    assert.equal(first.trialUsed, 1);
    assert.equal(repeated.trialUsed, 1);
    assert.equal(repeated.reused, true);

    for (const requestId of requestIds.slice(1, 10)) {
      await consumeTrialUsage({ db, deviceId, requestId, maxTrialCount: 10 });
    }
    const exhausted = await consumeTrialUsage({ db, deviceId, requestId: requestIds[10], maxTrialCount: 10 });
    assert.equal(exhausted.status, 'exhausted');
    assert.equal(exhausted.trialUsed, 10);

    await db.collection('licenses').doc(deviceId).set({ status: 'active', plan: 'PERM', expiresAt: null });
    const licensed = await consumeTrialUsage({ db, deviceId, requestId: crypto.randomUUID(), maxTrialCount: 10 });
    assert.equal(licensed.status, 'licensed');
    assert.equal(licensed.trialUsed, 10);
  } finally {
    const [usage, consumptions] = await Promise.all([
      db.collection('trialUsage').doc(deviceId).get(),
      db.collection('trialConsumptions').where('deviceId', '==', deviceId).get(),
    ]);
    const batch = db.batch();
    if (usage.exists) batch.delete(usage.ref);
    consumptions.docs.forEach((document) => batch.delete(document.ref));
    batch.delete(db.collection('licenses').doc(deviceId));
    await batch.commit();
  }
});
