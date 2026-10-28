const fs = require('node:fs');
const path = require('node:path');

const secretDirectory = path.resolve(__dirname, '..', '.secrets');
const tokenPath = path.join(secretDirectory, 'telegram-bot-token.txt');
const webhookSecretPath = path.join(secretDirectory, 'telegram-webhook-secret.txt');
const token = fs.readFileSync(tokenPath, 'utf8').trim();
const webhookSecret = fs.readFileSync(webhookSecretPath, 'utf8').trim();

if (!token || !webhookSecret) {
  throw new Error('Telegram bot token and webhook secret must not be empty.');
}
if (!/^[A-Za-z0-9_-]{1,256}$/.test(webhookSecret)) {
  throw new Error('Telegram webhook secret must use only letters, numbers, _ or - (1-256 characters).');
}

async function main() {
  const response = await fetch(`https://api.telegram.org/bot${token}/setWebhook`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      url: 'https://mylove-2026-sms-admin.web.app/api/webhook/telegram',
      secret_token: webhookSecret,
      allowed_updates: ['message'],
      max_connections: 5,
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || result.ok !== true) {
    throw new Error(`Telegram setWebhook failed: ${result.description || response.status}`);
  }
  process.stdout.write('Telegram webhook configured. Bot token and webhook secret were not printed.\n');
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
