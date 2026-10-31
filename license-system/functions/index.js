const crypto = require('node:crypto');
const express = require('express');
const admin = require('firebase-admin');
const { Firestore, FieldValue } = require('@google-cloud/firestore');
const { defineSecret, defineString } = require('firebase-functions/params');
const { onRequest } = require('firebase-functions/v2/https');
const {
  createOrReusePendingOrder,
  isValidPaymentCode,
  timestampMillis,
} = require('./pending_orders');
const { createKeyedRateLimiter } = require('./rate_limiter');

admin.initializeApp();

const db = new Firestore({
  projectId: admin.app().options.projectId || process.env.GCLOUD_PROJECT,
  databaseId: 'default',
});
const LICENSE_SIGNING_PRIVATE_KEY = defineSecret('NVPTTT_LICENSE_SIGNING_PRIVATE_KEY');
const TELEGRAM_BOT_TOKEN = defineSecret('NVPTTT_TELEGRAM_BOT_TOKEN');
const TELEGRAM_WEBHOOK_SECRET = defineSecret('NVPTTT_TELEGRAM_WEBHOOK_SECRET');
const TELEGRAM_ADMIN_USER_ID = defineString('TELEGRAM_ADMIN_USER_ID', { default: '0' });
const BANK_ACCOUNT_NUMBER = defineString('BANK_ACCOUNT_NUMBER', { default: '19034108972011' });
const BANK_BIN = defineString('BANK_BIN', { default: '970407' });
const BANK_ACCOUNT_NAME = defineString('BANK_ACCOUNT_NAME', { default: 'DANG TRI THUC' });

const ADMIN_EMAIL = 'thucdang2205@gmail.com';
const OFFLINE_GRACE_MS = 24 * 60 * 60 * 1000;
const PLANS = Object.freeze({
  '30D': { title: '30 ngày', amount: 50000, days: 30 },
  '90D': { title: '90 ngày', amount: 140000, days: 90 },
  '1Y': { title: '1 năm', amount: 365000, days: 365 },
  PERM: { title: 'Vĩnh viễn', amount: 999999, days: null },
});

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));
const telegramApp = express();
telegramApp.disable('x-powered-by');
telegramApp.use(express.json({ limit: '64kb' }));

function createInstanceRateLimiter(maxRequests, windowMs = 60_000) {
  let windowStartedAt = 0;
  let requestCount = 0;
  return (_req, res, next) => {
    const now = Date.now();
    if (now - windowStartedAt >= windowMs) {
      windowStartedAt = now;
      requestCount = 0;
    }
    if (requestCount >= maxRequests) {
      res.set('Retry-After', String(Math.max(1, Math.ceil((windowStartedAt + windowMs - now) / 1000))));
      return sendError(res, 429, 'Máy chủ đang nhận quá nhiều yêu cầu. Hãy thử lại sau.');
    }
    requestCount += 1;
    return next();
  };
}

// shortcut: X-Forwarded-For can be client-supplied, so this only limits bursts; use App Check when compatible clients are available.
app.use(createKeyedRateLimiter(
  120,
  60_000,
  (req) => String(req.get('X-Forwarded-For') || '').split(',')[0].trim(),
));
// Keep the shared cap as an emergency cost guard; normal clients are limited per IP and device.
app.use(createInstanceRateLimiter(1200));
telegramApp.use(createInstanceRateLimiter(60));
const adminOverviewRateLimiter = createKeyedRateLimiter(
  12,
  60_000,
  (req) => String(req.get('Authorization') || ''),
);

function sendError(res, status, message) {
  return res.status(status).json({ success: false, error: message });
}

function normalizeDeviceId(value) {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function isValidDeviceId(value) {
  return /^SMS-(?:[A-F0-9]{4}-[A-F0-9]{4}|[A-F0-9]{8}-[A-F0-9]{8})$/.test(value);
}

function normalizeAccountNumber(value) {
  return String(value || '').replace(/\D/g, '');
}

function planDetails(planId) {
  return Object.prototype.hasOwnProperty.call(PLANS, planId) ? PLANS[planId] : null;
}

function buildQrUrl(paymentCode, amount) {
  const accountNumber = BANK_ACCOUNT_NUMBER.value().trim();
  const bankBin = BANK_BIN.value().trim();
  const accountName = BANK_ACCOUNT_NAME.value().trim();
  const query = new URLSearchParams({
    amount: String(amount),
    addInfo: paymentCode,
    accountName,
  });
  return `https://img.vietqr.io/image/${encodeURIComponent(bankBin)}-${encodeURIComponent(accountNumber)}-compact2.png?${query}`;
}

function signingPrivateKey() {
  return LICENSE_SIGNING_PRIVATE_KEY.value().replace(/\\n/g, '\n');
}

function signEntitlement(license, deviceId) {
  const now = Date.now();
  const active = license?.status === 'active' &&
    (license.expiresAt == null || license.expiresAt > now);
  const payload = {
    v: 1,
    deviceId,
    status: active ? 'active' : (license?.status || 'none'),
    plan: active ? license.plan : (license?.plan || 'TRIAL'),
    expiresAt: active ? (license.expiresAt ?? null) : null,
    issuedAt: now,
    offlineUntil: now + OFFLINE_GRACE_MS,
  };
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.sign('RSA-SHA256', Buffer.from(encodedPayload), signingPrivateKey());
  return `${encodedPayload}.${signature.toString('base64url')}`;
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

function serializeDoc(snapshot) {
  const data = snapshot.data();
  return {
    ...data,
    createdAt: timestampMillis(data.createdAt),
    updatedAt: timestampMillis(data.updatedAt),
    paidAt: timestampMillis(data.paidAt),
    receivedAt: timestampMillis(data.receivedAt),
    expiresAt: timestampMillis(data.expiresAt),
    startedAt: timestampMillis(data.startedAt),
  };
}

async function requireAdmin(req, res) {
  const authorization = String(req.get('Authorization') || '');
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    sendError(res, 401, 'Đăng nhập quản trị viên để tiếp tục.');
    return null;
  }

  try {
    const decoded = await admin.auth().verifyIdToken(match[1], true);
    const email = String(decoded.email || '').toLowerCase();
    if (!decoded.email_verified || email !== ADMIN_EMAIL || decoded.firebase?.sign_in_provider !== 'google.com') {
      sendError(res, 403, 'Tài khoản này không có quyền quản trị.');
      return null;
    }
    return email;
  } catch (_) {
    sendError(res, 401, 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn.');
    return null;
  }
}

app.post('/api/orders', createKeyedRateLimiter(
  6,
  60_000,
  (req) => normalizeDeviceId(req.body?.deviceId),
), async (req, res) => {
  const deviceId = normalizeDeviceId(req.body?.deviceId);
  const planId = String(req.body?.plan || '').trim().toUpperCase();
  const plan = planDetails(planId);
  if (!isValidDeviceId(deviceId)) return sendError(res, 400, 'Mã thiết bị không hợp lệ.');
  if (!plan) return sendError(res, 400, 'Gói bản quyền không hợp lệ.');
  if (!BANK_ACCOUNT_NUMBER.value().trim()) return sendError(res, 503, 'Chưa cấu hình tài khoản nhận tiền.');

  try {
    const accountNumber = BANK_ACCOUNT_NUMBER.value().trim();
    const accountName = BANK_ACCOUNT_NAME.value().trim();
    const { record, reused } = await createOrReusePendingOrder({
      db,
      deviceId,
      planId,
      plan,
      accountNumber,
      accountName,
    });
    const { paymentCode } = record;
    return res.json({
      success: true,
      reused,
      paymentCode,
      deviceId,
      plan: planId,
      planTitle: plan.title,
      amount: plan.amount,
      bank: 'Techcombank',
      accountNumber,
      accountName,
      transferContent: paymentCode,
      telegramMessage: [
        'Yêu cầu kích hoạt bản quyền SMS',
        `Mã máy: ${deviceId}`,
        `Mã đơn: ${paymentCode}`,
        `Gói: ${plan.title}`,
        `Số tiền: ${plan.amount.toLocaleString('vi-VN')}đ`,
      ].join('\n'),
      qrUrl: buildQrUrl(paymentCode, plan.amount),
      expiresAt: null,
    });
  } catch (error) {
    console.error('Could not create payment order', error);
    return sendError(res, 500, 'Chưa tạo được đơn thanh toán. Hãy thử lại.');
  }
});

app.post('/api/orders/status', createKeyedRateLimiter(
  8,
  60_000,
  (req) => `${normalizeDeviceId(req.body?.deviceId)}:${String(req.body?.paymentCode || '').trim().toUpperCase()}`,
), async (req, res) => {
  const deviceId = normalizeDeviceId(req.body?.deviceId);
  const paymentCode = String(req.body?.paymentCode || '').trim().toUpperCase();
  if (!isValidDeviceId(deviceId) || !isValidPaymentCode(paymentCode)) {
    return sendError(res, 400, 'Thông tin đơn thanh toán không hợp lệ.');
  }
  try {
    const snapshot = await db.collection('orders').doc(paymentCode).get();
    if (!snapshot.exists || snapshot.get('deviceId') !== deviceId) {
      return sendError(res, 404, 'Không tìm thấy đơn thanh toán trên thiết bị này.');
    }
    const order = snapshot.data();
    const status = order.status === 'pending' && order.expiresAt != null && order.expiresAt <= Date.now()
      ? 'expired'
      : order.status;
    if (status === 'expired' && order.status !== 'expired') {
      await snapshot.ref.update({ status: 'expired', updatedAt: FieldValue.serverTimestamp() });
    }
    return res.json({
      success: true,
      status,
      plan: order.plan,
      amount: order.amount,
      expiresAt: order.expiresAt,
      paidAt: timestampMillis(order.paidAt),
    });
  } catch (error) {
    console.error('Could not read payment order', error);
    return sendError(res, 500, 'Chưa kiểm tra được trạng thái thanh toán.');
  }
});

app.post('/api/license/sync', createKeyedRateLimiter(
  8,
  60_000,
  (req) => normalizeDeviceId(req.body?.deviceId),
), async (req, res) => {
  const deviceId = normalizeDeviceId(req.body?.deviceId);
  if (!isValidDeviceId(deviceId)) return sendError(res, 400, 'Mã thiết bị không hợp lệ.');
  try {
    const reference = db.collection('licenses').doc(deviceId);
    const snapshot = await reference.get();
    let license = snapshot.exists ? snapshot.data() : null;
    if (license?.status === 'active' && license.expiresAt != null && license.expiresAt <= Date.now()) {
      await reference.update({ status: 'expired', updatedAt: FieldValue.serverTimestamp() });
      license = { ...license, status: 'expired' };
    }
    return res.json({
      success: true,
      licenseToken: signEntitlement(license, deviceId),
      license: license ? {
        status: license.status,
        plan: license.plan,
        expiresAt: license.expiresAt ?? null,
      } : { status: 'none', plan: 'TRIAL', expiresAt: null },
    });
  } catch (error) {
    console.error('Could not sync license', error);
    return sendError(res, 500, 'Chưa đồng bộ được bản quyền.');
  }
});

async function approvePendingOrder(paymentCode, approvedBy, approvalMethod = 'dashboard') {
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
      accountNumber: normalizeAccountNumber(order.accountNumber),
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
    };
  });
}

async function callTelegram(method, payload) {
  const token = TELEGRAM_BOT_TOKEN.value().trim();
  if (!token) throw new Error('Telegram bot token is not configured.');
  const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || result.ok !== true) {
    throw new Error(`Telegram API ${method} failed: ${result.description || response.status}`);
  }
  return result.result;
}

async function sendTelegramMessage(chatId, text) {
  return callTelegram('sendMessage', { chat_id: chatId, text });
}

function telegramWebhookSecretIsValid(req) {
  const expected = TELEGRAM_WEBHOOK_SECRET.value().trim();
  const supplied = String(req.get('X-Telegram-Bot-Api-Secret-Token') || '').trim();
  if (!expected || !supplied) return false;
  const expectedBytes = Buffer.from(expected);
  const suppliedBytes = Buffer.from(supplied);
  return expectedBytes.length === suppliedBytes.length &&
    crypto.timingSafeEqual(expectedBytes, suppliedBytes);
}

async function connectTelegramOrder(paymentCode, deviceId, chatId, userId) {
  if (!isValidPaymentCode(paymentCode) || !isValidDeviceId(deviceId)) {
    return { error: 'Mã đơn hoặc mã máy không đúng định dạng.' };
  }
  const orderRef = db.collection('orders').doc(paymentCode);
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(orderRef);
    if (!snapshot.exists) return { error: 'Không tìm thấy mã đơn này.' };
    const order = snapshot.data();
    if (order.deviceId !== deviceId) return { error: 'Mã máy không khớp với đơn thanh toán.' };
    if (!['pending', 'paid'].includes(order.status)) {
      return { error: 'Đơn này không còn chờ xác nhận thanh toán.' };
    }
    const linkedChatId = String(order.telegramChatId || '');
    if (linkedChatId && linkedChatId !== chatId) {
      return { error: 'Đơn này đã được liên kết với một tài khoản Telegram khác.' };
    }
    transaction.update(orderRef, {
      telegramChatId: chatId,
      telegramUserId: userId,
      telegramLinkedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return {
      status: order.status,
      deviceId: order.deviceId,
      plan: order.plan,
      planTitle: order.planTitle,
      amount: order.amount,
    };
  });
}

async function sendTelegramLicenseCode(paymentCode, chatId) {
  const orderSnapshot = await db.collection('orders').doc(paymentCode).get();
  if (!orderSnapshot.exists) return { error: 'Không tìm thấy mã đơn này.' };
  const order = orderSnapshot.data();
  if (String(order.telegramChatId || '') !== chatId) {
    return { error: 'Tài khoản Telegram này chưa được liên kết với đơn.' };
  }
  if (order.status !== 'paid') return { error: 'Đơn chưa được quản lý xác nhận đã nhận tiền.' };

  const licenseSnapshot = await db.collection('licenses').doc(order.deviceId).get();
  if (!licenseSnapshot.exists || licenseSnapshot.get('status') !== 'active') {
    return { error: 'Chưa tìm thấy license đang hoạt động cho đơn này.' };
  }
  const token = signEntitlement(licenseSnapshot.data(), order.deviceId);
  await sendTelegramMessage(
    chatId,
    `Bản quyền đã được xác nhận. Mã kích hoạt dành riêng cho thiết bị ${order.deviceId}:\n\n${token}\n\nMở app > Bản quyền SMS > Nhập mã kích hoạt. Mã này chỉ dùng được trên đúng thiết bị trên.`,
  );
  return { deviceId: order.deviceId };
}

async function listPendingTelegramOrders() {
  const snapshot = await db.collection('orders').orderBy('createdAt', 'desc').limit(100).get();
  return snapshot.docs
    .map((doc) => ({ paymentCode: doc.id, ...doc.data() }))
    .filter((order) => order.status === 'pending')
    .slice(0, 20);
}

async function handleTelegramUpdate(update) {
  const message = update?.message;
  if (!message?.chat || message.chat.type !== 'private') return;
  const chatId = String(message.chat.id);
  const userId = String(message.from?.id || '');
  const text = String(message.text || '').trim();
  if (!text) return;

  if (/^\/id(?:@\w+)?$/i.test(text)) {
    await sendTelegramMessage(chatId, `Telegram user ID của bạn: ${userId}`);
    return;
  }

  const adminUserId = TELEGRAM_ADMIN_USER_ID.value().trim();
  const isAdmin = adminUserId !== '' && adminUserId !== '0' && userId === adminUserId;
  const command = text.match(/^\/(\w+)(?:@\w+)?(?:\s+([A-Z0-9_-]+))?/i);
  const commandName = command?.[1]?.toLowerCase() || '';
  const commandArgument = String(command?.[2] || '').toUpperCase();

  if (isAdmin && commandName === 'choxacnhan') {
    const orders = await listPendingTelegramOrders();
    const rows = orders.map((order) =>
      `${order.telegramChatId ? '📨' : '—'} ${order.paymentCode}\n${order.deviceId} · ${order.planTitle || order.plan} · ${Number(order.amount || 0).toLocaleString('vi-VN')}đ`,
    );
    await sendTelegramMessage(
      chatId,
      rows.length
        ? `Các đơn đang chờ (${orders.length}):\n\n${rows.join('\n\n')}\n\nSau khi kiểm tra tiền vào tài khoản, dùng /duyet MÃ_ĐƠN.`
        : 'Hiện không có đơn đang chờ.',
    );
    return;
  }

  if (isAdmin && commandName === 'duyet') {
    if (!isValidPaymentCode(commandArgument)) {
      await sendTelegramMessage(chatId, 'Cú pháp: /duyet NVPTTT...');
      return;
    }
    const orderSnapshot = await db.collection('orders').doc(commandArgument).get();
    if (!orderSnapshot.exists) {
      await sendTelegramMessage(chatId, 'Không tìm thấy đơn thanh toán.');
      return;
    }
    const customerChatId = String(orderSnapshot.get('telegramChatId') || '');
    if (!customerChatId) {
      await sendTelegramMessage(chatId, 'Khách chưa gửi mã máy qua bot nên chưa có nơi nhận mã kích hoạt.');
      return;
    }
    const result = await approvePendingOrder(commandArgument, `telegram:${userId}`, 'telegram');
    if (result.error) {
      await sendTelegramMessage(chatId, result.error.message);
      return;
    }
    const delivery = await sendTelegramLicenseCode(commandArgument, customerChatId);
    if (delivery.error) {
      await sendTelegramMessage(chatId, `Đơn đã được duyệt nhưng chưa gửi được mã: ${delivery.error}`);
      return;
    }
    await sendTelegramMessage(
      chatId,
      `Đã xác nhận ${result.amount.toLocaleString('vi-VN')}đ và gửi mã kích hoạt cho ${result.deviceId}.`,
    );
    return;
  }

  if (isAdmin && commandName === 'gui') {
    if (!isValidPaymentCode(commandArgument)) {
      await sendTelegramMessage(chatId, 'Cú pháp: /gui NVPTTT...');
      return;
    }
    const orderSnapshot = await db.collection('orders').doc(commandArgument).get();
    const customerChatId = orderSnapshot.exists
      ? String(orderSnapshot.get('telegramChatId') || '')
      : '';
    if (!customerChatId) {
      await sendTelegramMessage(chatId, 'Đơn chưa liên kết với Telegram của khách.');
      return;
    }
    const result = await sendTelegramLicenseCode(commandArgument, customerChatId);
    await sendTelegramMessage(chatId, result.error || `Đã gửi lại mã cho ${result.deviceId}.`);
    return;
  }

  if (isAdmin && commandName === 'trogiup') {
    await sendTelegramMessage(chatId, 'Lệnh quản lý:\n/choxacnhan — xem đơn chờ\n/duyet MÃ_ĐƠN — chỉ dùng sau khi đã thấy tiền vào tài khoản\n/gui MÃ_ĐƠN — gửi lại mã kích hoạt');
    return;
  }

  if (commandName === 'start') {
    const [startPaymentCode, startDeviceId] = commandArgument.split('_');
    if (isValidPaymentCode(startPaymentCode) && isValidDeviceId(startDeviceId || '')) {
      const result = await connectTelegramOrder(startPaymentCode, startDeviceId, chatId, userId);
      if (result.error) {
        await sendTelegramMessage(chatId, result.error);
      } else if (result.status === 'paid') {
        const delivery = await sendTelegramLicenseCode(startPaymentCode, chatId);
        if (delivery.error) await sendTelegramMessage(chatId, delivery.error);
      } else {
        await sendTelegramMessage(chatId, `Đã ghi nhận ${result.deviceId}. Quản lý sẽ đối soát tài khoản trước khi gửi mã kích hoạt.`);
      }
    } else {
      await sendTelegramMessage(chatId, 'Hãy gửi thông tin đã sao chép trong app, gồm Mã máy và Mã đơn.');
    }
    return;
  }

  if (commandName === 'code') {
    if (!isValidPaymentCode(commandArgument)) {
      await sendTelegramMessage(chatId, 'Cú pháp: /code NVPTTT...');
      return;
    }
    const result = await sendTelegramLicenseCode(commandArgument, chatId);
    if (result.error) await sendTelegramMessage(chatId, result.error);
    return;
  }

  const deviceMatch = text.match(/\bSMS\s*-\s*([A-F0-9]{4}|[A-F0-9]{8})\s*-\s*([A-F0-9]{4}|[A-F0-9]{8})\b/i);
  const deviceId = deviceMatch && deviceMatch[1].length === deviceMatch[2].length
    ? `SMS-${deviceMatch[1]}-${deviceMatch[2]}`.toUpperCase()
    : '';
  const paymentMatch = text.match(/\bNVPTTT[A-F0-9]{15,16}\b/i);
  const paymentCode = paymentMatch?.[0]?.toUpperCase() || '';
  if (!deviceId || !paymentCode) {
    const suppliedPaymentCode = text.match(/\bNVPTTT([A-F0-9]+)\b/i);
    if (!deviceId) {
      await sendTelegramMessage(chatId, 'Không đọc được mã máy. Hãy gửi lại bằng nút “Gửi mã máy qua Telegram” trong app; bot chấp nhận mã dạng SMS-XXXXXXXX-XXXXXXXX kể cả có khoảng trắng quanh dấu gạch.');
    } else if (suppliedPaymentCode) {
      await sendTelegramMessage(chatId, `Mã đơn có ${suppliedPaymentCode[1].length} ký tự sau NVPTTT; mã phải có 15 hoặc 16 ký tự hex. Hãy gửi lại bằng nút “Gửi mã máy qua Telegram” trong app.`);
    } else {
      await sendTelegramMessage(chatId, 'Không tìm thấy mã đơn. Hãy gửi lại bằng nút “Gửi mã máy qua Telegram” trong app để gửi cả Mã máy và Mã đơn.');
    }
    return;
  }

  const result = await connectTelegramOrder(paymentCode, deviceId, chatId, userId);
  if (result.error) {
    await sendTelegramMessage(chatId, result.error);
    return;
  }
  if (result.status === 'paid') {
    const delivery = await sendTelegramLicenseCode(paymentCode, chatId);
    if (delivery.error) await sendTelegramMessage(chatId, delivery.error);
    return;
  }
  await sendTelegramMessage(
    chatId,
    `Đã ghi nhận mã máy ${result.deviceId} cho đơn ${paymentCode}. Quản lý sẽ đối soát tài khoản; bot chỉ gửi mã kích hoạt sau khi được duyệt.`,
  );
}

telegramApp.post('/api/webhook/telegram', async (req, res) => {
  if (!telegramWebhookSecretIsValid(req)) return sendError(res, 401, 'Webhook Telegram không hợp lệ.');
  try {
    await handleTelegramUpdate(req.body || {});
    return res.status(200).json({ success: true });
  } catch (error) {
    console.error('Could not process Telegram update', error);
    return sendError(res, 500, 'Không xử lý được yêu cầu Telegram.');
  }
});

app.get('/api/admin/overview', async (req, res) => {
  const adminEmail = await requireAdmin(req, res);
  if (!adminEmail) return;
  let isAllowed = false;
  adminOverviewRateLimiter(req, res, () => {
    isAllowed = true;
  });
  if (!isAllowed) return;

  try {
    const [licenseSnapshot, orderSnapshot, transactionSnapshot] = await Promise.all([
      db.collection('licenses').orderBy('updatedAt', 'desc').limit(500).get(),
      db.collection('orders').orderBy('createdAt', 'desc').limit(300).get(),
      db.collection('transactions').orderBy('receivedAt', 'desc').limit(300).get(),
    ]);
    const licenses = licenseSnapshot.docs.map(serializeDoc);
    const orders = orderSnapshot.docs.map(serializeDoc);
    const transactions = transactionSnapshot.docs.map(serializeDoc);
    const now = Date.now();
    const active = licenses.filter((item) => item.status === 'active' && (item.expiresAt == null || item.expiresAt > now));
    return res.json({
      success: true,
      adminEmail,
      counts: {
        active: active.length,
        expired: licenses.filter((item) => item.status === 'expired' || (item.status === 'active' && item.expiresAt != null && item.expiresAt <= now)).length,
        revoked: licenses.filter((item) => item.status === 'revoked').length,
        pending: orders.filter((item) => item.status === 'pending' && (item.expiresAt == null || item.expiresAt > now)).length,
        unmatched: transactions.filter((item) => item.status === 'unmatched').length,
      },
      plans: PLANS,
      licenses,
      orders,
      transactions,
    });
  } catch (error) {
    console.error('Could not load admin overview', error);
    return sendError(res, 500, 'Không tải được dữ liệu quản trị.');
  }
});

app.post('/api/admin/approve-order', async (req, res) => {
  const adminEmail = await requireAdmin(req, res);
  if (!adminEmail) return;

  const paymentCode = String(req.body?.paymentCode || '').trim().toUpperCase();
  try {
    const result = await approvePendingOrder(paymentCode, adminEmail, 'dashboard');
    if (result.error) return sendError(res, result.error.status, result.error.message);
    return res.json({
      success: true,
      alreadyPaid: result.alreadyPaid,
      deviceId: result.deviceId,
      plan: result.plan,
      amount: result.amount,
    });
  } catch (error) {
    console.error('Could not approve payment order', error);
    return sendError(res, 500, 'Không thể duyệt và kích hoạt đơn thanh toán.');
  }
});

app.post('/api/admin/license-action', async (req, res) => {
  const adminEmail = await requireAdmin(req, res);
  if (!adminEmail) return;

  const deviceId = normalizeDeviceId(req.body?.deviceId);
  const action = String(req.body?.action || '').trim().toLowerCase();
  const planId = String(req.body?.plan || '').trim().toUpperCase();
  if (!isValidDeviceId(deviceId)) return sendError(res, 400, 'Mã thiết bị không hợp lệ.');
  if (!['grant', 'revoke'].includes(action)) return sendError(res, 400, 'Thao tác không hợp lệ.');
  if (action === 'grant' && !planDetails(planId)) return sendError(res, 400, 'Gói bản quyền không hợp lệ.');

  const licenseRef = db.collection('licenses').doc(deviceId);
  const auditRef = db.collection('auditLogs').doc();
  try {
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(licenseRef);
      const existing = snapshot.exists ? snapshot.data() : null;
      let record;
      if (action === 'grant') {
        record = makeLicenseRecord(deviceId, planId, existing, 'manual', null);
      } else {
        record = {
          ...(existing || { deviceId, plan: 'TRIAL', createdAt: FieldValue.serverTimestamp() }),
          status: 'revoked',
          revokedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        };
      }
      transaction.set(licenseRef, record);
      transaction.create(auditRef, {
        adminEmail,
        action,
        deviceId,
        plan: action === 'grant' ? planId : (existing?.plan || null),
        createdAt: FieldValue.serverTimestamp(),
      });
    });
    return res.json({ success: true });
  } catch (error) {
    console.error('Could not apply admin license action', error);
    return sendError(res, 500, 'Không cập nhật được license.');
  }
});

app.use((error, _req, res, _next) => {
  console.error('Unhandled API error', error);
  return sendError(res, 500, 'Có lỗi phía máy chủ.');
});

exports.licenseApi = onRequest({
  region: 'asia-southeast1',
  secrets: [LICENSE_SIGNING_PRIVATE_KEY],
  timeoutSeconds: 20,
  memory: '256MiB',
  minInstances: 0,
  maxInstances: 1,
  concurrency: 20,
}, app);

exports.telegramWebhook = onRequest({
  region: 'asia-southeast1',
  secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, LICENSE_SIGNING_PRIVATE_KEY],
  timeoutSeconds: 20,
  memory: '256MiB',
  minInstances: 0,
  maxInstances: 1,
  concurrency: 20,
}, telegramApp);
