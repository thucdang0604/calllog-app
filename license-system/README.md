# NVPTTT SMS License

Firebase backend and authenticated admin page for the SMS license feature. Payment confirmation currently uses manual review because the configured Techcombank account is not supported by SePay webhooks. This checkout is configured for Firebase project `mylove-2026` and the isolated Hosting site `mylove-2026-sms-admin`; existing Hosting sites in the project are left untouched.

## Product prices

| Plan ID | Period | Price |
| --- | --- | ---: |
| `30D` | 30 days | 50,000 VND |
| `90D` | 90 days | 140,000 VND |
| `1Y` | 1 year | 365,000 VND |
| `PERM` | Permanent | 999,999 VND |

Each purchase order has a unique memo beginning with `NVPTTT`. Orders stay pending until the owner confirms receipt of the transfer. Approval creates the license and payment audit record atomically; repeated approvals cannot issue a second license for the same order.

## Firebase setup

1. This project uses Firebase project `mylove-2026`, Cloud Firestore, Google-only Authentication, Hosting, and Node.js 22 Cloud Functions. Functions require the Blaze plan. The named Firestore database is `default` in `asia-southeast1`.
2. From this directory run `firebase use --add` and select the project.
3. Google sign-in is the only enabled provider. There is no account-creation flow. The management API accepts only the verified Google account `thucdang2205@gmail.com` and rejects tokens from all other providers. If reusing this project, Firebase CLI enables providers from `firebase.json` but does not disable previously enabled providers; disable Email/Password in Authentication settings as well.
4. The receiving account is prefilled from the existing app QR (`19034108972011`, Techcombank BIN `970407`, account name `DANG TRI THUC`); change it if that is no longer the intended account.
5. The SePay webhook is not deployed because the current Techcombank flow requires manual review.
6. A signing pair has been provisioned in this working copy. Its private key is kept only in `.secrets/license-signing-private.pem` (ignored by Git), and its public key is embedded in the Android app. Add the complete PEM private key as the `NVPTTT_LICENSE_SIGNING_PRIVATE_KEY` secret using Firebase / Google Cloud Secret Manager. Never commit or send the private key in chat. On a fresh checkout where the private key is absent, run `node scripts/generate-signing-key.js`; it creates a new private key and updates both public key files. Rebuild the Android app after generating a new pair.
7. `public/config.js` contains the Firebase Web app configuration. These values are public client configuration; admin access is enforced by verified Firebase ID tokens, the fixed email allowlist, and the Google sign-in provider claim on the server.
8. Deploy with `firebase deploy --only auth,functions,firestore,hosting --project mylove-2026` so the rules and composite indexes are applied together.

The HTTP functions have bounded instances (license API: 1; Telegram: 1), no warm instances, short timeouts, and in-memory request limits. The admin overview is limited to 12 requests per minute per signed-in token; lists load in pages and status totals use Firestore count queries. Artifact Registry cleanup is configured to remove stored function deployment images after 1 day; deployed functions keep their runtime image. The Cloud Functions spend cap is 25,000 VND/month; a separate 25,000 VND/month project-wide budget only sends alerts and does not stop other services.

App Check is not enforced for the mobile license API. The Android client is not registered in Firebase, and Play Integrity setup requires the app to be linked through Google Play Console even when distributing APKs outside Play. Do not enforce App Check until a production provider is configured and a compatible APK has been distributed; existing clients do not send App Check tokens.

The first deployment may prompt for the non-secret string parameters. A `.env.<project-id>` file can be used for local emulator values; it is ignored by Git. Do not put private keys, service account files, or SePay secrets in the web folder.

## Payment provider status

The current receiving account is Techcombank (`19034108972011`), but SePay's current published webhook bank list does not include Techcombank. The QR remains available for transfers, but the app must not claim the bank confirmed payment automatically.

Current manual-review flow:

- The app creates a pending order and displays a QR, transfer memo, device ID, and order details. Repeated requests for the same device and plan reuse that pending order. The order does not expire while awaiting manual review.
- The customer can share the device ID and order details from the app through Telegram. The deployed bot can record the order and send the activation code after manual approval.
- Open `https://mylove-2026-sms-admin.web.app/`, inspect the Techcombank account statement, and only then use **Xác nhận đã nhận tiền** for the matching order. The backend records the approver and activates the license in one Firestore transaction.
- While the purchase dialog is open, the app checks order state immediately and then every 5 minutes for up to 15 minutes. The customer can still request a manual status check or paste a server-signed Telegram token in the activation field.

## Telegram bot

The webhook and bot are deployed with the bot token and owner Telegram user ID configured. Customers send the app's copied message (device ID and order code) to the bot. The owner can use `/choxacnhan`, then `/duyet MÃ_ĐƠN` only after checking the bank statement. The bot sends a device-bound signed activation token; `/gui MÃ_ĐƠN` resends it, and the customer can use `/code MÃ_ĐƠN` to request it again. Telegram linkage is stored on the existing order document; the bot does not create a separate customer/session collection.

Setup after creating a bot with `@BotFather`:

1. Save the bot token locally in `license-system/.secrets/telegram-bot-token.txt`. Generate a webhook secret with `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` and save it in `license-system/.secrets/telegram-webhook-secret.txt`. Both files are ignored by Git.
2. In `license-system/functions`, run `firebase functions:secrets:set NVPTTT_TELEGRAM_BOT_TOKEN --project mylove-2026` and `firebase functions:secrets:set NVPTTT_TELEGRAM_WEBHOOK_SECRET --project mylove-2026`; paste each value at the CLI prompt.
3. Deploy `firebase deploy --only functions:telegramWebhook,hosting --project mylove-2026`.
4. Run `node scripts/set-telegram-webhook.js` from `license-system`; it registers the webhook with Telegram without printing either secret.
5. Send `/id` to the bot, then set `TELEGRAM_ADMIN_USER_ID=<your numeric Telegram user ID>` in `license-system/functions/.env.mylove-2026` and deploy `firebase deploy --only functions:telegramWebhook --project mylove-2026` again. Only this Telegram user ID can list or approve orders.

The bot and dashboard share the same `approvePendingOrder` operation. Never put the license private key or Telegram bot token in the app or web client.

If switching to a SePay-supported bank later, configure payment-code recognition with prefix `NVPTT` and a 17-character alphanumeric suffix. The complete app code remains `NVPTTT` plus 16 hexadecimal characters. The webhook should be incoming-only and verify the matching receiving account, exact amount, signature, pending order, and duplicate transaction ID before activation.

## App build

Deploy the updated `licenseApi` function and Firestore index before distributing the app: it now consumes trial SMS quotas on the server. The default Hosting URL is already embedded. If the backend URL changes, set `LICENSE_API_BASE_URL` in the build environment; the build scripts pass it to both Flutter and Android:

```powershell
cd ..
$env:LICENSE_API_BASE_URL = 'https://your-hosting-site.web.app/api'
.\build_apk.bat
```

The app syncs a server-signed entitlement on launch and when returning to the app, at most every 12 hours after a successful sync. For three days after creating an order, resumed sessions may sync every 5 minutes so a late manual approval is noticed. Opening the license dialog requests an immediate sync; while the purchase dialog is open, it also checks order status every 5 minutes for up to 15 minutes. The signed entitlement is cached with a 24-hour offline grace. The server signing key remains in Secret Manager; the APK contains only the public key. The app release must be built with `LICENSE_API_BASE_URL` pointing to the deployed Hosting `/api` URL.

The release APK keeps the existing sideload signing identity via the local `~/.android/debug.keystore` so current installs remain updatable. A different key can be supplied with Gradle properties `CALLLOG_RELEASE_KEYSTORE`, `CALLLOG_RELEASE_STORE_PASSWORD`, `CALLLOG_RELEASE_KEY_ALIAS`, and `CALLLOG_RELEASE_KEY_PASSWORD`; changing keys breaks direct APK upgrades unless a supported signing-key migration is set up.

## Admin page

Open `https://mylove-2026-sms-admin.web.app/`. The dashboard lists active, expired, revoked and pending records, shows recorded transactions, and provides an explicit payment approval action plus manual grant/renew/revoke. Admin actions are written to `auditLogs`. Sign in with Google as `thucdang2205@gmail.com`; the client removes other Google identities when possible, and the server never grants them management access.

Firestore client rules deny direct reads and writes. The dashboard uses Firebase Authentication for Google sign-in and calls the HTTPS function; the function verifies the ID token, email verification, Google provider, and the single allowed admin email before returning records or changing a license.
