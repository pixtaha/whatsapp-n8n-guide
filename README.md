# WhatsApp Cloud API + n8n: Quick Start

🍎 **Mac** → open **Terminal**
🪟 **Windows** → open **CMD** (not PowerShell)

Every command is **one line**. Paste it, press Enter once.

---

## 1. Variables

Fill them as you go. Run again to update.

**🍎 Mac**
```bash
export TOKEN="PASTE_TOKEN"
export APP_SECRET="PASTE_APP_SECRET"
export PIN="PASTE_6_DIGIT_PIN"
export APP_ID="PASTE_APP_ID"
export WABA_ID="PASTE_WABA_ID"
export PHONE_NUMBER_ID="PASTE_PHONE_NUMBER_ID"
export DOMAIN="your-n8n-domain.com"
export WEBHOOK_PATH="your-webhook-path"
export VERIFY_TOKEN="your_verify_word"
```

**🪟 CMD** (no spaces around `=`, no quotes)
```cmd
set TOKEN=PASTE_TOKEN
set APP_SECRET=PASTE_APP_SECRET
set PIN=PASTE_6_DIGIT_PIN
set APP_ID=PASTE_APP_ID
set WABA_ID=PASTE_WABA_ID
set PHONE_NUMBER_ID=PASTE_PHONE_NUMBER_ID
set DOMAIN=your-n8n-domain.com
set WEBHOOK_PATH=your-webhook-path
set VERIFY_TOKEN=your_verify_word
```

**Check:**

🍎 `echo $APP_ID $WABA_ID $PHONE_NUMBER_ID $DOMAIN`
🪟 `echo %APP_ID% %WABA_ID% %PHONE_NUMBER_ID% %DOMAIN%`

✅ 4 values on one line.

⚠️ Never screenshot or paste `TOKEN`, `APP_SECRET`, `PIN`. Leaked → reset it.

---

## 2. Create the App

1. developers.facebook.com → **My Apps** → **Create App**
2. Use case: **WhatsApp**
3. Business: same portfolio as your WABA
4. App settings → Basic → copy **App ID** + **App Secret** → Step 1

---

## 3. System User

1. Business Settings → **System users** → Add (role **Admin**)
2. **Assign assets** → App (Full control) + WABA (Full control)

---

## 4. Token

1. System user → **Generate token** → your App
2. Expiration: **Never**
3. Permissions: `whatsapp_business_messaging` + `whatsapp_business_management`
4. Save → set `TOKEN` (Step 1)

**Test:**

🍎
```bash
curl "https://graph.facebook.com/v26.0/$WABA_ID/phone_numbers" -H "Authorization: Bearer $TOKEN"
```
🪟
```cmd
curl "https://graph.facebook.com/v26.0/%WABA_ID%/phone_numbers" -H "Authorization: Bearer %TOKEN%"
```

✅ `{"data":[{ ... "id":"1xxxx" ... }]}` → the `id` is your **PHONE_NUMBER_ID**
✅ `{"data":[]}` → no number yet, go to Step 5

❌ `Cannot parse access token` → TOKEN is empty or wrong syntax
❌ `Object with ID '$WABA_ID' does not exist` → you used Mac syntax in CMD

---

## 5. Add & register the number

1. App → **Use cases** → **Connect on WhatsApp** → **Customize**
2. **Step 2. Production setup** (⚠️ not Step 1)
3. **Add phone number** → display name, category → country + number → **Text message** → enter code
4. Copy the number's ID → `PHONE_NUMBER_ID` (Step 1)
5. **Subscribe webhooks** ON → **Register** → choose PIN → set `PIN` (Step 1)

**Register from terminal (if the button fails):**

🍎
```bash
curl -X POST "https://graph.facebook.com/v26.0/$PHONE_NUMBER_ID/register" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"messaging_product\":\"whatsapp\",\"pin\":\"$PIN\"}"
```
🪟
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%PHONE_NUMBER_ID%/register" -H "Authorization: Bearer %TOKEN%" -H "Content-Type: application/json" -d "{\"messaging_product\":\"whatsapp\",\"pin\":\"%PIN%\"}"
```

✅ `{"success":true}`

❌ `messaging_product is required` → copy the command again, the `\"` got lost
❌ `PIN Mismatch` → use the old PIN

**Check** (Step 4 command again) → `"platform_type":"CLOUD_API"` ✅

---

## 6. Connect App to WABA

🍎
```bash
curl -X POST "https://graph.facebook.com/v26.0/$WABA_ID/subscribed_apps" -H "Authorization: Bearer $TOKEN"
```
🪟
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%WABA_ID%/subscribed_apps" -H "Authorization: Bearer %TOKEN%"
```

✅ `{"success":true}`

---

## 7. n8n workflow

1. **Webhook node**: GET + POST, Path = `WEBHOOK_PATH`, Respond = Using 'Respond to Webhook' Node
2. **GET** → **IF node**: `{{ $json.query['hub.verify_token'] }}` equals `VERIFY_TOKEN`
   - true → **Respond to Webhook node**: Text `{{ $('Webhook').item.json.query['hub.challenge'] }}`, code 200
   - false → **Respond to Webhook node**: No data, code 403
3. **POST** → **Respond to Webhook node**: No data, code 200
4. **Publish**

---

## 8. Test n8n

🍎
```bash
curl -i "https://$DOMAIN/webhook/$WEBHOOK_PATH?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=12345"
```
🪟
```cmd
curl -i "https://%DOMAIN%/webhook/%WEBHOOK_PATH%?hub.mode=subscribe&hub.verify_token=%VERIFY_TOKEN%&hub.challenge=12345"
```

✅ first line `200`, last line `12345`

**Wrong token** (replace `VERIFY_TOKEN` value with `wrong`):

✅ first line `403`, no body

| Result | Fix |
| --- | --- |
| `404` | Workflow not published or wrong Path |
| `200` + `12345` with wrong token | IF node not checking the token |
| `403` with correct token | Token in IF node ≠ `VERIFY_TOKEN` |
| Hangs | false branch not connected |

---

## 9. Register webhook with Meta

🍎
```bash
curl -X POST "https://graph.facebook.com/v26.0/$APP_ID/subscriptions" -d "object=whatsapp_business_account" -d "callback_url=https://$DOMAIN/webhook/$WEBHOOK_PATH" -d "verify_token=$VERIFY_TOKEN" -d "fields=messages" -d "access_token=$APP_ID|$APP_SECRET"
```
🪟
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%APP_ID%/subscriptions" -d "object=whatsapp_business_account" -d "callback_url=https://%DOMAIN%/webhook/%WEBHOOK_PATH%" -d "verify_token=%VERIFY_TOKEN%" -d "fields=messages" -d "access_token=%APP_ID%|%APP_SECRET%"
```

✅ `{"success":true}`

**Check:**

🍎
```bash
curl "https://graph.facebook.com/v26.0/$APP_ID/subscriptions?access_token=$APP_ID|$APP_SECRET"
```
🪟
```cmd
curl "https://graph.facebook.com/v26.0/%APP_ID%/subscriptions?access_token=%APP_ID%|%APP_SECRET%"
```

✅ `"callback_url":"https://your-domain/webhook/your-path"`, `"active":true`, `"fields":[{"name":"messages"...}]`

---

## 10. Live test

Send a WhatsApp message to your number → new execution in n8n **Executions**.

Nothing? → App not **Published**, or workflow not **Published**.
