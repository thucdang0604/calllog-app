const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const secretDirectory = path.join(root, '.secrets');
const privatePath = path.join(secretDirectory, 'license-signing-private.pem');
const publicPath = path.join(root, 'public', 'license-signing-public.pem');
const androidPath = path.resolve(root, '..', 'android', 'app', 'src', 'main', 'res', 'raw', 'license_signing_public.pem');

if (fs.existsSync(privatePath)) {
  throw new Error('Private signing key already exists. Refusing to replace it.');
}
const replacingPublicKey = fs.existsSync(publicPath) || fs.existsSync(androidPath);

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

fs.mkdirSync(secretDirectory, { recursive: true });
fs.mkdirSync(path.dirname(androidPath), { recursive: true });
fs.writeFileSync(privatePath, privateKey, { flag: 'wx', mode: 0o600 });
fs.writeFileSync(publicPath, publicKey);
fs.writeFileSync(androidPath, publicKey);
console.log(`${replacingPublicKey ? 'Replaced the checked-in public key' : 'Created public key files'} with a new RSA signing pair. The private key remains in license-system/.secrets/.`);
