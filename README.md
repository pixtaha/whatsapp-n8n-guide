# WhatsApp Cloud API + n8n: Quick Start

<p align="center">
  <a href="https://www.youtube.com/watch?v=QaziTSN98rY">
    <img src="https://img.youtube.com/vi/QaziTSN98rY/maxresdefault.jpg" width="720" alt="Watch the full setup video on YouTube">
  </a>
  <br>
  <b>▶️ Watch the full setup video on YouTube (12 min)</b>
</p>

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
3. **Add phone number** → choose your **existing WhatsApp account** (⚠️ not "Create new": that makes a second account) → display name, category → country + number → **Text message** → enter code
4. Copy the number's ID → `PHONE_NUMBER_ID` (Step 1)
5. **Subscribe webhooks** ON → **Register** → choose PIN → set `PIN` (Step 1)

❌ `linked to a business portfolio` / cannot add → limit is **2 numbers per business** before verification. Business Settings → WhatsApp accounts → delete the old number first
❌ `already in use on WhatsApp` → the number is still on the WhatsApp / Business app. In the app: Settings → Account → Delete my account, then retry (can take days)

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

## 7. Database table

Supabase → **SQL Editor** → New query → paste `supabase_whatsapp_messages_table.sql` → **Run**.

✅ `Success. No rows returned` → Table Editor shows `whatsapp_messages`

---

## 8. n8n workflow

1. n8n → **Create workflow** → `...` → **Import from file** → `n8n_whatsapp_inbound_starter.json`
2. Follow the 7 numbered sticky notes on the canvas:
   - **Webhook node** → Path = `WEBHOOK_PATH`
   - **Check Verify Token** (IF node) → `CHANGE_ME_VERIFY_TOKEN` = `VERIFY_TOKEN`
   - **Mark as Read** (HTTP Request node) → Header Auth credential: Name `Authorization`, Value `Bearer <TOKEN>`
   - **Log Incoming Message** + **Update WhatsApp Status** (Postgres node) → your Supabase credential
   - **Config** (Set node) → `supabase_url`, `system_prompt`
3. Unpin the sample data on **Webhook node**
4. **Publish**

---

## 9. Test n8n

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

## 10. Register webhook with Meta

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

## 11. Live test

From your personal WhatsApp, send `hello` to the business number.

**Check 1: n8n** → Executions → a new green execution within ~2 seconds
- Open it → **Webhook node** output → `body.entry[0].changes[0].value.messages[0].text.body` = `hello`
- **Parse Message** output → `phone`, `user_id`, `reply_to`, `type: text`
- **Log Incoming Message** output → `id: 1`

**Check 2: Supabase** → Table Editor → `whatsapp_messages` → 1 row, `direction = incoming`, `content = hello`

**Check 3: your phone** → blue double ticks ✓✓ on your message (Mark as Read worked)

Send the same message again → new execution, but **Log Incoming Message** stops at **Is New Message?** (no second row).

| Result | Fix |
| --- | --- |
| No execution at all | Workflow not **Published** · Step 6 skipped (`subscribed_apps`) · Step 10 `active: false` · App not **Published** |
| Execution red at **Log Incoming Message** | Wrong Postgres credential, or Step 7 SQL not run |
| Execution red at **Mark as Read** | Header Auth credential: `Bearer <TOKEN>` with a space, token has `whatsapp_business_messaging` |
| Row saved but no ✓✓ | Same as above; row is fine, only the read receipt failed |
| Execution green, `messages` missing | A status event, not a message: normal, check **Event Type** → Status branch |

✅ All 3 checks pass → inbound is done. Next: build replies after **Message Type** (HTTP Request node → `/messages`, then Postgres node to log `direction = outgoing`).
