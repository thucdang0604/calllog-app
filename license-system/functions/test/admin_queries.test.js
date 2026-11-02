const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const { Firestore, Timestamp } = require('@google-cloud/firestore');
const { readAdminPage, listPendingTelegramOrders } = require('../admin_queries');

const db = new Firestore({ projectId: process.env.GCLOUD_PROJECT || 'demo-nvpttt', databaseId: 'default' });
after(() => db.terminate());

test('admin orders use creation time and the bot sees pending orders beyond 100 paid orders', async () => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'Run this test with the Firestore emulator.');
  const suffix = crypto.randomBytes(4).toString('hex');
  const collection = db.collection('orders');
  const deviceId = `SMS-${suffix.slice(0, 4).toUpperCase()}-${suffix.slice(4).toUpperCase()}`;
  const base = Date.now() + 100_000_000;
  const batch = db.batch();
  batch.set(collection.doc(`${suffix}-Z`), { deviceId, status: 'pending', createdAt: Timestamp.fromMillis(base + 1000) });
  batch.set(collection.doc(`${suffix}-A`), { deviceId, status: 'paid', createdAt: Timestamp.fromMillis(base + 3000) });
  batch.set(collection.doc(`${suffix}-B`), { deviceId, status: 'paid', createdAt: Timestamp.fromMillis(base + 2000) });
  for (let index = 0; index < 101; index++) {
    batch.set(collection.doc(`${suffix}-paid-${index}`), {
      deviceId, status: 'paid', createdAt: Timestamp.fromMillis(base + 4000 + index),
    });
  }
  await batch.commit();
  try {
    const first = await readAdminPage(db, 'orders', '', 2);
    assert.equal(first.docs[0].id, `${suffix}-paid-100`);
    const second = await readAdminPage(db, 'orders', first.cursor, 2);
    assert.equal(second.docs[0].id, `${suffix}-paid-98`);
    const pending = await listPendingTelegramOrders(db);
    assert.ok(pending.some((order) => order.paymentCode === `${suffix}-Z`));
  } finally {
    const snapshot = await collection.where('deviceId', '==', deviceId).get();
    const cleanup = db.batch();
    snapshot.docs.forEach((document) => cleanup.delete(document.ref));
    await cleanup.commit();
  }
});
