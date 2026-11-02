const { FieldPath } = require('@google-cloud/firestore');

async function readAdminPage(db, collectionName, cursorId = '', pageSize = 100) {
  const collection = db.collection(collectionName);
  let query = collection.orderBy(collectionName === 'orders' ? 'createdAt' : FieldPath.documentId(), 'desc');
  if (cursorId) {
    const cursor = await collection.doc(cursorId).get();
    if (!cursor.exists) throw new Error('Trang dữ liệu không còn tồn tại. Hãy làm mới.');
    query = query.startAfter(cursor);
  }
  const snapshot = await query.limit(pageSize + 1).get();
  const docs = snapshot.docs.slice(0, pageSize);
  return {
    docs,
    hasMore: snapshot.docs.length > pageSize,
    cursor: docs.length ? docs[docs.length - 1].id : null,
  };
}

async function listPendingTelegramOrders(db) {
  const snapshot = await db.collection('orders').where('status', '==', 'pending')
    .orderBy('createdAt', 'desc').limit(20).get();
  return snapshot.docs.map((doc) => ({ paymentCode: doc.id, ...doc.data() }));
}

module.exports = { readAdminPage, listPendingTelegramOrders };
