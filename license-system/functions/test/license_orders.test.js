const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const { Firestore } = require('@google-cloud/firestore');
const { createOrReusePendingOrder } = require('../pending_orders');
const { PLANS, approvePendingOrder } = require('../license_orders');

const db = new Firestore({ projectId: process.env.GCLOUD_PROJECT || 'demo-nvpttt', databaseId: 'default' });
after(() => db.terminate());

test('approval is idempotent, renews from expiry, and rejects a permanent license purchase', async () => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'Run this test with the Firestore emulator.');
  const suffix = crypto.randomBytes(4).toString('hex').toUpperCase();
  const deviceId = `SMS-${suffix.slice(0, 4)}-${suffix.slice(4)}`;
  const create = (planId) => createOrReusePendingOrder({
    db, deviceId, planId, plan: PLANS[planId],
    accountNumber: '19034108972011', accountName: 'DANG TRI THUC',
  });
  try {
    const first = await create('30D');
    const [a, b] = await Promise.all([
      approvePendingOrder(db, first.record.paymentCode, 'owner'),
      approvePendingOrder(db, first.record.paymentCode, 'owner'),
    ]);
    assert.deepEqual([a.alreadyPaid, b.alreadyPaid].sort(), [false, true]);
    const firstLicense = (await db.collection('licenses').doc(deviceId).get()).data();
    assert.equal(firstLicense.plan, '30D');
    assert.equal((await db.collection('transactions').where('deviceId', '==', deviceId).get()).size, 1);

    const second = await create('90D');
    assert.equal((await approvePendingOrder(db, second.record.paymentCode, 'owner')).alreadyPaid, false);
    const renewed = (await db.collection('licenses').doc(deviceId).get()).data();
    assert.equal(renewed.plan, '90D');
    assert.ok(renewed.expiresAt >= firstLicense.expiresAt + 90 * 24 * 60 * 60 * 1000);

    const pendingBeforePermanent = await create('30D');
    const permanent = await create('PERM');
    assert.equal((await approvePendingOrder(db, permanent.record.paymentCode, 'owner')).alreadyPaid, false);
    assert.equal((await create('30D')).blocked, 'permanent-license');
    assert.equal((await approvePendingOrder(db, pendingBeforePermanent.record.paymentCode, 'owner')).error.status, 409);
    const finalLicense = (await db.collection('licenses').doc(deviceId).get()).data();
    assert.equal(finalLicense.plan, 'PERM');
    assert.equal(finalLicense.expiresAt, null);
    assert.equal((await db.collection('transactions').where('deviceId', '==', deviceId).get()).size, 3);
  } finally {
    const collections = ['orders', 'pendingOrderPointers', 'transactions', 'auditLogs'];
    const batch = db.batch();
    for (const collection of collections) {
      const snapshot = await db.collection(collection).where('deviceId', '==', deviceId).get();
      snapshot.docs.forEach((document) => batch.delete(document.ref));
    }
    batch.delete(db.collection('licenses').doc(deviceId));
    await batch.commit();
  }
});
