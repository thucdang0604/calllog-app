const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const { Firestore } = require('@google-cloud/firestore');
const { createOrReusePendingOrder } = require('../pending_orders');

const db = new Firestore({
  projectId: process.env.GCLOUD_PROJECT || 'demo-nvpttt',
  databaseId: 'default',
});

after(() => db.terminate());

test('concurrent requests reuse pending orders and refresh changed or paid orders', async () => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'Run this test with the Firestore emulator.');
  const suffix = crypto.randomBytes(4).toString('hex').toUpperCase();
  const deviceId = `SMS-${suffix.slice(0, 4)}-${suffix.slice(4)}`;
  const input = {
    db,
    deviceId,
    planId: '30D',
    plan: { title: '30 ngày', amount: 50000 },
    accountNumber: '19034108972011',
    accountName: 'DANG TRI THUC',
  };

  try {
    const [first, second] = await Promise.all([
      createOrReusePendingOrder(input),
      createOrReusePendingOrder(input),
    ]);
    assert.equal(first.record.paymentCode, second.record.paymentCode);
    assert.deepEqual([first.reused, second.reused].sort(), [false, true]);
    assert.equal((await db.collection('orders').where('deviceId', '==', deviceId).get()).size, 1);

    const renamed = await createOrReusePendingOrder({ ...input, accountName: 'DANG TRI THUC 2' });
    assert.notEqual(renamed.record.paymentCode, first.record.paymentCode);
    await db.collection('orders').doc(renamed.record.paymentCode).update({ status: 'paid' });

    const renewed = await createOrReusePendingOrder({ ...input, accountName: 'DANG TRI THUC 2' });
    assert.notEqual(renewed.record.paymentCode, renamed.record.paymentCode);
  } finally {
    const [orders, pointers] = await Promise.all([
      db.collection('orders').where('deviceId', '==', deviceId).get(),
      db.collection('pendingOrderPointers').where('deviceId', '==', deviceId).get(),
    ]);
    const batch = db.batch();
    orders.docs.forEach((document) => batch.delete(document.ref));
    pointers.docs.forEach((document) => batch.delete(document.ref));
    if (!orders.empty || !pointers.empty) await batch.commit();
  }
});
