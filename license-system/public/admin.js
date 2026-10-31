import { initializeApp } from 'https://www.gstatic.com/firebasejs/13.1.0/firebase-app.js';
import {
  GoogleAuthProvider,
  deleteUser,
  getAuth,
  onAuthStateChanged,
  signInWithPopup,
  signOut,
} from 'https://www.gstatic.com/firebasejs/13.1.0/firebase-auth.js';

(() => {
  const cfg = window.APP_CONFIG || {};
  const apiBase = String(cfg.apiBase || '/api').replace(/\/$/, '');
  const adminEmail = 'thucdang2205@gmail.com';
  const firebaseApp = initializeApp({
    apiKey: cfg.firebaseApiKey,
    authDomain: cfg.firebaseAuthDomain,
    projectId: cfg.firebaseProjectId,
    appId: cfg.firebaseAppId,
  });
  const firebaseAuth = getAuth(firebaseApp);
  const googleProvider = new GoogleAuthProvider();
  googleProvider.setCustomParameters({ prompt: 'select_account', login_hint: adminEmail });
  const plans = { '30D': '30 ngày', '90D': '90 ngày', '1Y': '1 năm', PERM: 'Vĩnh viễn' };
  const $ = (id) => document.getElementById(id);
  let overview = { licenses: [], orders: [], transactions: [], counts: {} };
  let authUser = null;
  let googleSignInInProgress = false;
  let overviewLoadPromise = null;

  function message(target, text, kind = '') {
    const element = $(target);
    element.textContent = text || '';
    element.className = `message ${kind}`.trim();
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, (char) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[char]);
  }

  function money(value) {
    return `${Number(value || 0).toLocaleString('vi-VN')}đ`;
  }

  function date(value) {
    if (value == null) return 'Vĩnh viễn';
    const parsed = new Date(Number(value));
    return Number.isNaN(parsed.getTime()) ? '—' : parsed.toLocaleString('vi-VN');
  }

  function effectiveStatus(license) {
    if (license.status === 'active' && license.expiresAt != null && license.expiresAt <= Date.now()) return 'expired';
    return license.status || 'unknown';
  }

  async function freshToken() {
    if (!authUser) throw new Error('Hãy đăng nhập lại.');
    return authUser.getIdToken();
  }

  async function api(path, options = {}) {
    const token = await freshToken();
    const response = await fetch(`${apiBase}${path}`, {
      ...options,
      headers: { ...(options.headers || {}), Authorization: `Bearer ${token}`, ...(options.body ? { 'Content-Type': 'application/json' } : {}) },
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || `Yêu cầu lỗi (${response.status}).`);
    return result;
  }

  function setSignedIn(signedIn) {
    $('loginPanel').classList.toggle('hidden', signedIn);
    $('dashboard').classList.toggle('hidden', !signedIn);
    $('logoutButton').classList.toggle('hidden', !signedIn);
  }

  function isAllowedAdmin(user) {
    return String(user?.email || '').trim().toLowerCase() === adminEmail;
  }

  function googleAuthError(error) {
    const messages = {
      'auth/unauthorized-domain': 'Tên miền của trang quản trị chưa được thêm vào Firebase Authentication > Settings > Authorized domains.',
      'auth/popup-blocked': 'Trình duyệt đã chặn cửa sổ Google. Hãy cho phép popup rồi thử lại.',
      'auth/popup-closed-by-user': 'Cửa sổ đăng nhập Google đã bị đóng trước khi hoàn tất.',
      'auth/cancelled-popup-request': 'Đang có một cửa sổ đăng nhập khác được mở.',
      'auth/operation-not-allowed': 'Google Sign-In chưa được bật trong Firebase Authentication.',
      'auth/network-request-failed': 'Không kết nối được Firebase Authentication. Hãy kiểm tra mạng rồi thử lại.',
    };
    return messages[error?.code] || error?.message || 'Không đăng nhập được bằng Google.';
  }

  function renderCounts(counts) {
    $('activeCount').textContent = counts.active || 0;
    $('expiredCount').textContent = counts.expired || 0;
    $('revokedCount').textContent = counts.revoked || 0;
    $('pendingCount').textContent = counts.pending || 0;
    $('unmatchedCount').textContent = counts.unmatched || 0;
  }

  function renderLicenses() {
    const query = $('searchInput').value.trim().toUpperCase();
    const filter = $('statusFilter').value;
    const items = overview.licenses.filter((item) => {
      const status = effectiveStatus(item);
      const textMatches = !query || `${item.deviceId} ${item.plan} ${item.source}`.toUpperCase().includes(query);
      return textMatches && (filter === 'all' || status === filter);
    });
    const rows = items.map((item) => {
      const status = effectiveStatus(item);
      const label = status === 'active' ? 'Đang hoạt động' : status === 'expired' ? 'Hết hạn' : status === 'revoked' ? 'Đã thu hồi' : status;
      const action = status === 'active'
        ? `<button class="button button-danger" data-action="revoke" data-device="${escapeHtml(item.deviceId)}">Thu hồi</button>`
        : `<button class="button button-quiet" data-action="grant" data-device="${escapeHtml(item.deviceId)}">Gia hạn</button>`;
      return `<tr><td><code>${escapeHtml(item.deviceId)}</code></td><td>${escapeHtml(plans[item.plan] || item.plan || '—')}</td><td><span class="badge badge-${escapeHtml(status)}">${escapeHtml(label)}</span></td><td>${escapeHtml(date(item.expiresAt))}</td><td>${escapeHtml(item.source || '—')}</td><td class="row-actions">${action}</td></tr>`;
    }).join('');
    $('licenseRows').innerHTML = rows || '<tr><td colspan="6" class="empty">Không có license phù hợp.</td></tr>';
  }

  function renderOrders() {
    const rows = overview.orders.map((item) => `<tr>
      <td><code>${escapeHtml(item.paymentCode)}</code></td><td><code>${escapeHtml(item.deviceId)}</code></td>
      <td>${escapeHtml(plans[item.plan] || item.plan)}</td><td>${escapeHtml(money(item.amount))}</td>
      <td><span class="badge badge-${escapeHtml(item.status)}">${item.status === 'pending' ? 'Chờ xác nhận' : item.status === 'paid' ? 'Đã kích hoạt' : escapeHtml(item.status)}</span></td>
      <td>${escapeHtml(date(item.createdAt))}</td>
      <td class="row-actions">${item.status === 'pending' ? `<button class="button" data-order-action="approve" data-code="${escapeHtml(item.paymentCode)}" data-device="${escapeHtml(item.deviceId)}" data-plan="${escapeHtml(item.plan)}" data-amount="${escapeHtml(item.amount)}">Xác nhận đã nhận tiền</button>` : '—'}</td>
    </tr>`).join('');
    $('orderRows').innerHTML = rows || '<tr><td colspan="7" class="empty">Chưa có đơn thanh toán.</td></tr>';
  }

  function renderTransactions() {
    const rows = overview.transactions.map((item) => `<tr>
      <td><code>${escapeHtml(item.providerTransactionId)}</code></td><td>${escapeHtml(money(item.transferAmount))}</td>
      <td>${escapeHtml(item.content || '—')}</td><td><span class="badge badge-${escapeHtml(item.status)}">${escapeHtml(item.status)}</span></td>
      <td>${escapeHtml(item.reason || '—')}</td>
    </tr>`).join('');
    $('transactionRows').innerHTML = rows || '<tr><td colspan="5" class="empty">Chưa có giao dịch.</td></tr>';
  }

  function renderPagination() {
    for (const [collection, id] of [
      ['licenses', 'loadMoreLicenses'],
      ['orders', 'loadMoreOrders'],
      ['transactions', 'loadMoreTransactions'],
    ]) $(id).hidden = !overview.hasMore?.[collection];
  }

  function loadedSummary() {
    return `Đã tải ${overview.licenses.length}/${overview.totals?.licenses ?? overview.licenses.length} license, `
      + `${overview.orders.length}/${overview.totals?.orders ?? overview.orders.length} đơn và `
      + `${overview.transactions.length}/${overview.totals?.transactions ?? overview.transactions.length} giao dịch.`;
  }

  function loadOverview() {
    if (overviewLoadPromise) return overviewLoadPromise;
    const refreshButton = $('refreshButton');
    refreshButton.disabled = true;
    message('pageMessage', 'Đang tải dữ liệu…');
    overviewLoadPromise = (async () => {
      try {
        const result = await api('/admin/overview');
        overview = result;
        $('adminIdentity').textContent = result.adminEmail || '';
        renderCounts(result.counts || {});
        renderLicenses();
        renderOrders();
        renderTransactions();
        renderPagination();
        message('pageMessage', loadedSummary(), 'success');
      } catch (error) {
        message('pageMessage', error.message, 'error');
        if (!authUser) setSignedIn(false);
      } finally {
        refreshButton.disabled = false;
        overviewLoadPromise = null;
      }
    })();
    return overviewLoadPromise;
  }

  async function loadMore(collection, buttonId, render) {
    const button = $(buttonId);
    const target = overview;
    const cursor = target.cursors?.[collection];
    if (!cursor || button.disabled) return;
    button.disabled = true;
    button.textContent = 'Đang tải…';
    try {
      const result = await api(`/admin/page/${collection}?after=${encodeURIComponent(cursor)}`);
      if (overview !== target) return;
      target[collection].push(...result.items);
      target.cursors[collection] = result.cursor;
      target.hasMore[collection] = result.hasMore;
      render();
      renderPagination();
      message('pageMessage', loadedSummary(), 'success');
    } catch (error) {
      message('pageMessage', error.message, 'error');
    } finally {
      button.disabled = false;
      button.textContent = collection === 'licenses' ? 'Tải thêm license' : collection === 'orders' ? 'Tải thêm đơn' : 'Tải thêm giao dịch';
    }
  }

  async function applyAction(deviceId, action, plan) {
    await api('/admin/license-action', {
      method: 'POST', body: JSON.stringify({ deviceId, action, plan }),
    });
    message('pageMessage', action === 'revoke' ? 'Đã thu hồi license.' : 'Đã cấp/gia hạn license.', 'success');
    await loadOverview();
  }

  async function approveOrder(paymentCode) {
    const order = overview.orders.find((item) => item.paymentCode === paymentCode);
    if (!order) throw new Error('Đơn không còn trong danh sách. Hãy làm mới dữ liệu.');
    const confirmed = window.confirm(
      `Chỉ xác nhận sau khi đã thấy tiền vào tài khoản.\n\n` +
      `Mã máy: ${order.deviceId}\n` +
      `Gói: ${plans[order.plan] || order.plan}\n` +
      `Số tiền: ${money(order.amount)}\n` +
      `Mã đơn: ${order.paymentCode}\n\n` +
      'Xác nhận đã nhận tiền và kích hoạt license?'
    );
    if (!confirmed) return;
    await api('/admin/approve-order', {
      method: 'POST', body: JSON.stringify({ paymentCode }),
    });
    message('pageMessage', `Đã xác nhận thanh toán và kích hoạt ${order.deviceId}.`, 'success');
    await loadOverview();
  }

  $('planInput').innerHTML = Object.entries(plans).map(([id, title]) => `<option value="${id}">${title}</option>`).join('');
  $('googleSignInButton').addEventListener('click', async () => {
    const button = $('googleSignInButton');
    button.disabled = true;
    googleSignInInProgress = true;
    message('loginMessage', 'Đang mở đăng nhập Google…');
    try {
      const result = await signInWithPopup(firebaseAuth, googleProvider);
      if (!isAllowedAdmin(result.user)) {
        try { await deleteUser(result.user); } catch (_) {}
        await signOut(firebaseAuth);
        throw new Error(`Chỉ tài khoản Google ${adminEmail} được phép quản lý.`);
      }
      authUser = result.user;
      setSignedIn(true);
      await loadOverview();
    } catch (error) {
      message('loginMessage', googleAuthError(error), 'error');
    } finally {
      googleSignInInProgress = false;
      button.disabled = false;
    }
  });
  $('logoutButton').addEventListener('click', async () => {
    authUser = null;
    await signOut(firebaseAuth);
    setSignedIn(false);
    message('loginMessage', 'Đã đăng xuất.');
  });
  $('refreshButton').addEventListener('click', loadOverview);
  $('loadMoreLicenses').addEventListener('click', () => loadMore('licenses', 'loadMoreLicenses', renderLicenses));
  $('loadMoreOrders').addEventListener('click', () => loadMore('orders', 'loadMoreOrders', renderOrders));
  $('loadMoreTransactions').addEventListener('click', () => loadMore('transactions', 'loadMoreTransactions', renderTransactions));
  $('searchInput').addEventListener('input', renderLicenses);
  $('statusFilter').addEventListener('change', renderLicenses);
  $('grantForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const deviceId = $('deviceIdInput').value.trim().toUpperCase();
    const plan = $('planInput').value;
    try {
      await applyAction(deviceId, 'grant', plan);
      $('deviceIdInput').value = '';
    } catch (error) { message('pageMessage', error.message, 'error'); }
  });
  $('licenseRows').addEventListener('click', async (event) => {
    const button = event.target.closest('button[data-action]');
    if (!button) return;
    const action = button.dataset.action;
    const deviceId = button.dataset.device;
    try {
      if (action === 'revoke') {
        if (!window.confirm(`Thu hồi bản quyền của ${deviceId}?`)) return;
        await applyAction(deviceId, 'revoke');
      } else {
        const plan = window.prompt('Nhập gói cần cấp: 30D, 90D, 1Y hoặc PERM', '30D');
        if (!plan) return;
        await applyAction(deviceId, 'grant', plan.trim().toUpperCase());
      }
    } catch (error) { message('pageMessage', error.message, 'error'); }
  });
  $('orderRows').addEventListener('click', async (event) => {
    const button = event.target.closest('button[data-order-action="approve"]');
    if (!button) return;
    try {
      await approveOrder(button.dataset.code);
    } catch (error) { message('pageMessage', error.message, 'error'); }
  });

  onAuthStateChanged(firebaseAuth, async (user) => {
    if (googleSignInInProgress) return;
    authUser = null;
    if (!user) {
      setSignedIn(false);
      return;
    }
    if (!isAllowedAdmin(user)) {
      setSignedIn(false);
      try { await deleteUser(user); } catch (_) {}
      await signOut(firebaseAuth);
      message('loginMessage', `Chỉ tài khoản Google ${adminEmail} được phép quản lý.`, 'error');
      return;
    }
    authUser = user;
    setSignedIn(true);
    await loadOverview();
  });
})();
