const { FieldValue } = require('@google-cloud/firestore');
const { hasActivePermanentLicense, isValidPaymentCode } = require('./pending_orders');

const PLANS = Object.freeze({
  '30D': { title: '30 ngày', amount: 50000, days: 30 },
  '90D': { title: '90 ngày', amount: 140000, days: 90 },
  '1Y': { title: '1 năm', amount: 365000, days: 365 },
  PERM: { title: 'Vĩnh viễn', amount: 999999, days: null },
});

function planDetails(planId) {
  return Object.prototype.hasOwnProperty.call(PLANS, planId) ? PLANS[planId] : null;
}

function nextExpiry(existing, planId, now = Date.now()) {
  if (planId === 'PERM' || existing?.plan === 'PERM' && existing?.status === 'active') {
    return null;
  }
  const plan = planDetails(planId);
  const previousExpiry = existing?.status === 'active' ? existing.expiresAt : null;
  const start = previousExpiry && previousExpiry > now ? previousExpiry : now;
  return start + plan.days * 24 * 60 * 60 * 1000;
}

function makeLicenseRecord(deviceId, planId, existing, source, transactionId = null) {
  const now = Date.now();
  const effectivePlan = existing?.plan === 'PERM' && existing?.status === 'active' ? 'PERM' : planId;
  return {
    deviceId,
    plan: effectivePlan,
    status: 'active',
    startedAt: existing?.status === 'active' && existing.startedAt ? existing.startedAt : now,
    expiresAt: nextExpiry(existing, effectivePlan, now),
    source,
    lastTransactionId: transactionId,
    createdAt: existing?.createdAt || FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

async function approvePendingOrder(db, paymentCode, approvedBy, approvalMethod = 'dashboard') {
  if (!isValidPaymentCode(paymentCode)) {
    return { error: { status: 400, message: 'Mã đơn thanh toán không hợp lệ.' } };
  }

  const orderRef = db.collection('orders').doc(paymentCode);
  const manualTransactionId = `manual-${paymentCode}`;
  const transactionRef = db.collection('transactions').doc(manualTransactionId);
  const auditRef = db.collection('auditLogs').doc();

  return db.runTransaction(async (transaction) => {
    const [orderSnapshot, transactionSnapshot] = await Promise.all([
      transaction.get(orderRef),
      transaction.get(transactionRef),
    ]);
    if (!orderSnapshot.exists) {
      return { error: { status: 404, message: 'Không tìm thấy đơn thanh toán.' } };
    }

    const order = orderSnapshot.data();
    if (order.status === 'paid') {
      return {
        alreadyPaid: true,
        deviceId: order.deviceId,
        plan: order.plan,
        amount: order.amount,
        telegramChatId: String(order.telegramChatId || ''),
      };
    }
    if (order.status !== 'pending') {
      return { error: { status: 409, message: 'Đơn này không còn ở trạng thái chờ duyệt.' } };
    }
    if (transactionSnapshot.exists) {
      return { error: { status: 409, message: 'Đơn đã có giao dịch ghi nhận, hãy tải lại dữ liệu.' } };
    }

    const licenseRef = db.collection('licenses').doc(order.deviceId);
    const licenseSnapshot = await transaction.get(licenseRef);
    const existingLicense = licenseSnapshot.exists ? licenseSnapshot.data() : null;
    if (hasActivePermanentLicense(existingLicense)) {
      return { error: { status: 409, message: 'Thiết bị đã có bản quyền vĩnh viễn; hãy kiểm tra khoản chuyển trước khi xử lý đơn này.' } };
    }
    const licenseRecord = makeLicenseRecord(
      order.deviceId,
      order.plan,
      existingLicense,
      'manual-payment',
      manualTransactionId,
    );

    transaction.update(orderRef, {
      status: 'paid',
      paidAt: FieldValue.serverTimestamp(),
      approvedAt: FieldValue.serverTimestamp(),
      approvedBy,
      approvalMethod,
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.set(licenseRef, licenseRecord);
    transaction.create(transactionRef, {
      provider: 'manual',
      providerTransactionId: manualTransactionId,
      paymentCode,
      deviceId: order.deviceId,
      plan: order.plan,
      accountNumber: String(order.accountNumber || '').replace(/\D/g, ''),
      transferType: 'in',
      transferAmount: order.amount,
      content: paymentCode,
      status: 'matched',
      approvedBy,
      approvalMethod,
      receivedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(auditRef, {
      adminEmail: approvedBy,
      action: 'approve-payment',
      approvalMethod,
      paymentCode,
      deviceId: order.deviceId,
      plan: order.plan,
      amount: order.amount,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      alreadyPaid: false,
      deviceId: order.deviceId,
      plan: order.plan,
      amount: order.amount,
      license: licenseRecord,
      telegramChatId: String(order.telegramChatId || ''),
    };
  });
}

module.exports = { PLANS, approvePendingOrder, makeLicenseRecord, planDetails };
