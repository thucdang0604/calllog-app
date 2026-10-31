const crypto = require('node:crypto');
const { FieldValue } = require('@google-cloud/firestore');

function isValidPaymentCode(value) {
  return /^NVPTTT[A-F0-9]{15,16}$/.test(value);
}

function timestampMillis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (typeof value === 'number') return value;
  return null;
}

function pendingOrderPointerId(deviceId, planId) {
  return crypto.createHash('sha256').update(`${deviceId}:${planId}`).digest('hex');
}

async function createOrReusePendingOrder({
  db,
  deviceId,
  planId,
  plan,
  accountNumber,
  accountName,
}) {
  const pointerRef = db.collection('pendingOrderPointers').doc(
    pendingOrderPointerId(deviceId, planId),
  );
  return db.runTransaction(async (transaction) => {
    const pointer = await transaction.get(pointerRef);
    const previousCode = String(pointer.exists ? pointer.get('paymentCode') || '' : '');
    if (isValidPaymentCode(previousCode)) {
      const previousOrder = await transaction.get(db.collection('orders').doc(previousCode));
      if (previousOrder.exists) {
        const previous = previousOrder.data();
        const previousExpiry = timestampMillis(previous.expiresAt);
        if (previous.status === 'pending' && previous.deviceId === deviceId &&
            previous.plan === planId && previous.amount === plan.amount &&
            previous.accountNumber === accountNumber && previous.accountName === accountName &&
            (previousExpiry == null || previousExpiry > Date.now())) {
          return { record: previous, reused: true };
        }
      }
    }

    const paymentCode = `NVPTTT${crypto.randomBytes(8).toString('hex').toUpperCase()}`;
    const record = {
      paymentCode,
      deviceId,
      plan: planId,
      planTitle: plan.title,
      amount: plan.amount,
      status: 'pending',
      manualReview: true,
      bank: 'Techcombank',
      accountNumber,
      accountName,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: null,
    };
    transaction.create(db.collection('orders').doc(paymentCode), record);
    transaction.set(pointerRef, { paymentCode, deviceId, plan: planId });
    return { record, reused: false };
  });
}

module.exports = { createOrReusePendingOrder, isValidPaymentCode, timestampMillis };
