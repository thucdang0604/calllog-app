const { FieldValue } = require('@google-cloud/firestore');

async function syncTrialUsage({ db, deviceId, reportedUsed = 0 }) {
  const usageRef = db.collection('trialUsage').doc(deviceId);
  const claimed = Math.max(0, Math.min(10, Math.trunc(Number(reportedUsed) || 0)));
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(usageRef);
    if (snapshot.exists) return Math.max(0, Number(snapshot.get('used') || 0));
    transaction.create(usageRef, {
      deviceId,
      used: claimed,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return claimed;
  });
}

async function consumeTrialUsage({ db, deviceId, requestId, maxTrialCount, reportedUsed = 0, now = Date.now() }) {
  const requestRef = db.collection('trialConsumptions').doc(requestId);
  const usageRef = db.collection('trialUsage').doc(deviceId);
  const licenseRef = db.collection('licenses').doc(deviceId);

  return db.runTransaction(async (transaction) => {
    const [requestSnapshot, usageSnapshot, licenseSnapshot] = await Promise.all([
      transaction.get(requestRef),
      transaction.get(usageRef),
      transaction.get(licenseRef),
    ]);
    const license = licenseSnapshot.exists ? licenseSnapshot.data() : null;
    if (requestSnapshot.exists) {
      const previous = requestSnapshot.data();
      if (previous.deviceId !== deviceId) return { status: 'conflict', license };
      return { status: previous.status, trialUsed: previous.trialUsed, license, reused: true };
    }

    const storedUsed = Math.max(0, Math.trunc(Number(usageSnapshot.exists ? usageSnapshot.get('used') || 0 : 0)));
    const claimedUsed = Math.max(0, Math.min(maxTrialCount, Math.trunc(Number(reportedUsed) || 0)));
    const trialUsed = Math.max(storedUsed, claimedUsed);
    const licenseActive = license?.status === 'active' &&
      (license.expiresAt == null || license.expiresAt > now);
    if (licenseActive || trialUsed >= maxTrialCount) {
      if (!usageSnapshot.exists || trialUsed > storedUsed) {
        transaction.set(usageRef, { deviceId, used: trialUsed, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      }
      return { status: licenseActive ? 'licensed' : 'exhausted', trialUsed, license };
    }

    const nextTrialUsed = trialUsed + 1;
    transaction.create(requestRef, {
      deviceId,
      status: 'consumed',
      trialUsed: nextTrialUsed,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.set(usageRef, {
      deviceId,
      used: nextTrialUsed,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { status: 'consumed', trialUsed: nextTrialUsed, license };
  });
}

module.exports = { consumeTrialUsage, syncTrialUsage };
