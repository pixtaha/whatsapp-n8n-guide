# WhatsApp Cloud API + n8n: Direct Meta Setup Guide

Connect a WhatsApp number directly to Meta Cloud API and receive messages in n8n, with no provider in between.

**Order:** App → System User → Token → Add & register number → Connect App to WABA → n8n workflow → Test → Register webhook

> 💡 **الغرض من الـ guide ده:** كل أمر فيه نسختين. **🍎 Mac / Linux** (bash أو zsh) و **🪟 Windows CMD**. اختار اللي يناسب جهازك والتزم بيه لآخر الـ guide. متخلطش بينهم.

---

## 0. Pick your terminal

| Your machine | Open this | Variables look like | Why |
| --- | --- | --- | --- |
| 🍎 Mac | **Terminal** | `$TOKEN` | Built-in |
| 🐧 Linux | **Terminal** | `$TOKEN` | Built-in |
| 🪟 Windows | **Command Prompt (CMD)** | `%TOKEN%` | Built-in, tested with students ✅ |
| 🪟 Windows (alternative) | **Git Bash** (installed with Git for Windows) | `$TOKEN` | Then use the 🍎 commands as-is |

⚠️ **Windows: do not use PowerShell** for this guide. In PowerShell, `curl` is a different command (`Invoke-WebRequest`) and the `\` line breaks don't work. CMD or Git Bash only.

⚠️ **Each command is ONE line.** Some look long; paste the whole thing, then press Enter once.

---

## 1. Variables & secrets

> 💡 **الغرض:** الأسرار والـ IDs بنحطها في التيرمنال مرة واحدة، عشان ما نكتبهاش في أي أمر ولا تتسرّب في screenshot.

Fill the values as you get them in the next steps. You can run this block again any time to update a value.

**🍎 Mac / Linux**

```bash
# Secrets (never paste these into commands, nodes, or chats)
export TOKEN="PASTE_SYSTEM_USER_TOKEN"
export APP_SECRET="PASTE_APP_SECRET"
export PIN="PASTE_6_DIGIT_PIN"

# IDs
export APP_ID="PASTE_APP_ID"
export WABA_ID="PASTE_WABA_ID"
export PHONE_NUMBER_ID="PASTE_PHONE_NUMBER_ID"

# n8n webhook
export DOMAIN="your-n8n-domain.com"
export WEBHOOK_PATH="your-webhook-path"
export VERIFY_TOKEN="your_verify_word"
```

**🪟 Windows CMD**

```cmd
set TOKEN=PASTE_SYSTEM_USER_TOKEN
set APP_SECRET=PASTE_APP_SECRET
set PIN=PASTE_6_DIGIT_PIN
set APP_ID=PASTE_APP_ID
set WABA_ID=PASTE_WABA_ID
set PHONE_NUMBER_ID=PASTE_PHONE_NUMBER_ID
set DOMAIN=your-n8n-domain.com
set WEBHOOK_PATH=your-webhook-path
set VERIFY_TOKEN=your_verify_word
```

CMD rules:
- `set NAME=value` → **no spaces** around `=` and **no quotes** around the value.
- ✅ `set WABA_ID=2514141999064472`
- ❌ `set WABA_ID = "2514141999064472"` (stores the spaces and quotes inside the value)
- Lines starting with `#` in the Mac block are comments. In CMD use `REM` or just skip them.

**Check that the variables are saved:**

**🍎** `echo $APP_ID $WABA_ID $PHONE_NUMBER_ID $DOMAIN`
**🪟** `echo %APP_ID% %WABA_ID% %PHONE_NUMBER_ID% %DOMAIN%`

✅ **Expected:** your 4 values printed on one line. An empty spot = that variable is not set.

**Check the token without printing it:**

**🍎** `echo ${#TOKEN}`
**🪟** `echo %TOKEN:~0,10%...`

✅ **Expected:** 🍎 a number above 150 (token length). 🪟 the first 10 characters (starts with `EAA`).

| Mistake (seen in class) | What happened | Fix |
| --- | --- | --- |
| `TOKEN` → `'TOKEN' is not recognized` | Typed the name alone | Use `set TOKEN=...` (CMD) or `export TOKEN=...` (Mac) |
| `set "EAAxxxxxx..."` → `Environment variable ... not defined` | Pasted the value without the name | `set TOKEN=EAAxxxxxx...` |
| `set WABA` → prints `WABA_ID=...` | `set NAME` without `=` **lists** variables starting with that name. Harmless. | Nothing |
| 🪟 `$WABA_ID` in the URL → `Object with ID '$WABA_ID' does not exist` | Mac syntax in CMD. CMD sent the literal text `$WABA_ID` | Use `%WABA_ID%` |
| 🪟 `$env:TOKEN` → `Cannot parse access token` | PowerShell syntax in CMD | Use `%TOKEN%` |
| 🪟 `-H` → `'-H' is not recognized` | The `\` at the end of the line split the command in two | One line, no `\` |

Other rules:
- These variables live only in the current terminal window. New window → set them again.
- Tokens, secrets and PINs: **password manager only**. Leaked → Revoke / Reset immediately.
- Sharing your terminal output (with a student, a colleague, or an AI)? Remove `TOKEN`, `APP_SECRET`, `PIN` and `VERIFY_TOKEN` first. **`echo %TOKEN%` prints the full token: never screenshot it.**
- Use separate values for **dev / demo / production** (separate App or number, separate n8n credentials, separate DB).

### How to read the terminal output

| You see | Meaning |
| --- | --- |
| `%` at the very end, e.g. `{"success":true}%` | 🍎 only. Not part of the response. zsh adds it when the response has no newline at the end. |
| `"paging":{"cursors":{...}}` | Page markers for long lists. Ignore them. |
| `HTTP/2 200` (🍎) or `HTTP/1.1 200 OK` (🪟) + many header lines | You used `curl -i`. Headers first, then an empty line, then the body. Both versions are fine. |
| `https:\/\/www.facebook.com\/...` | Escaped slashes in JSON. Normal. |
| Values in the examples like `1xxxxxxxxxxxxxx` | Your real IDs and names will be different. Check the **field names and values that matter**, not the exact text. |

---

## 2. Create the App

> 💡 **الغرض:** الـ App هو **الوسيط** بين واتساب وn8n. من غيره Meta متعرفش تبعت الرسايل لمين.

1. developers.facebook.com → **My Apps** → **Create App**
2. Use case: **WhatsApp**
3. Business: the **same business portfolio** that has (or will have) the WABA
4. Copy the **App ID** and **App Secret** (App settings → Basic) → put them in Step 1.

✅ **Check:** Business Settings → System users → Generate token → your App appears in **Select app**.

---

## 3. System User access

> 💡 **الغرض:** بنعمل **موظف آلي** وندّيله مفتاح للـ App ومفتاح للرقم، عشان يشتغل عليهم من غير ما نسجّل دخول كل مرة.

1. Business Settings → **System users**
    - No system user in this portfolio? **Add** → role **Admin**
2. Select the system user → **Assign assets**:
    - The **App** → Full control
    - The **WABA** (WhatsApp account) → Full control

---

## 4. Generate token

> 💡 **الغرض:** الـ token هو **كارنيه** الموظف الآلي. أي أمر بنبعته لـ Meta لازم يكون معاه الكارنيه ده.

1. System user → **Generate token** → choose your App
2. Expiration: **Never**
3. Permissions:
    - `whatsapp_business_messaging`
    - `whatsapp_business_management`
4. Save it in your password manager → set `TOKEN` (Step 1)

**Test the token:**

**🍎 Mac / Linux**
```bash
curl "https://graph.facebook.com/v26.0/$WABA_ID/phone_numbers" -H "Authorization: Bearer $TOKEN"
```

**🪟 Windows CMD**
```cmd
curl "https://graph.facebook.com/v26.0/%WABA_ID%/phone_numbers" -H "Authorization: Bearer %TOKEN%"
```

✅ **Expected:** a `data` list. Each item is one number on this WABA:

```json
{"data":[{
  "verified_name":"Your Business",
  "code_verification_status":"VERIFIED",
  "display_phone_number":"+20 10 0000 0000",
  "quality_rating":"UNKNOWN",
  "platform_type":"NOT_APPLICABLE",
  "throughput":{"level":"NOT_APPLICABLE"},
  "id":"1xxxxxxxxxxxxxx"
}], "paging":{...}}
```

- `id` = the **Phone Number ID** → set `PHONE_NUMBER_ID` (Step 1)
- `{"data":[]}` = no numbers yet. Normal → Step 5.

| Error says | Meaning | Fix |
| --- | --- | --- |
| `Invalid OAuth access token - Cannot parse access token` | `TOKEN` is empty or the variable syntax is wrong | Check with the "token without printing it" command in Step 1 |
| `OAuthException` + `permission` | WABA not assigned to the System User | Step 3 |
| `Object with ID '...' does not exist` | `WABA_ID` is wrong or empty | `echo` it (Step 1) |

---

## 5. Add a new number (skip if the number already exists)

> 💡 **الغرض:** بنضيف **خط التليفون** نفسه لحساب الواتساب، ونسجّله على Cloud API عشان يقدر يبعت ويستقبل.

### Before you start

| Check | How | If not |
| --- | --- | --- |
| The number has **no WhatsApp** on it | Open WhatsApp on that phone. It must be empty or not installed | WhatsApp → Settings → Account → **Delete account** first |
| You have a valid **display name** | Clearly linked to your business, e.g. "Pixtaha Lectures". Not a generic word alone ("Support"), not an unrelated brand | A wrong name gets **Rejected** |

### Add the number

1. Your App → **Use cases** → **Connect on WhatsApp** → **Customize**
2. Left menu → **Step 2. Production setup**
⚠️ Not **Step 1. Try it out**. That page sends the code on WhatsApp, so it never arrives.
3. **Register your WhatsApp phone number** → **Add phone number**
4. **WA Business Profile** screen:
    - Display name, Category
    - WhatsApp Business account: existing or new
    - **Next**
5. **Add number** screen:
    - Country code + number without the leading 0 (Egypt: `10xxxxxxxx`)
    - **Text message** (or **Phone call** for landlines) → **Next**
6. Enter the code → **Next**

✅ **Expected:** the number appears with an orange **Not registered** label. Copy its ID (grey, under the number) → `PHONE_NUMBER_ID` in Step 1.

In the terminal (Step 4 command) the number now shows `"code_verification_status":"VERIFIED"` but still `"platform_type":"NOT_APPLICABLE"`. That means: the code was confirmed, but the number is **not on Cloud API yet**.

### Register the number

1. On the number card, turn **Subscribe webhooks** ON.
2. **Register** → choose a 6-digit PIN → confirm.
Save the PIN in your password manager **before** you confirm → set `PIN` (Step 1).

✅ **Expected:** green **Registered** label.

### Register from the terminal (or if you see "Registration failed")

Don't keep clicking. The terminal shows the real error.

**🍎 Mac / Linux**
```bash
curl -X POST "https://graph.facebook.com/v26.0/$PHONE_NUMBER_ID/register" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"messaging_product\":\"whatsapp\",\"pin\":\"$PIN\"}"
```

**🪟 Windows CMD**
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%PHONE_NUMBER_ID%/register" -H "Authorization: Bearer %TOKEN%" -H "Content-Type: application/json" -d "{\"messaging_product\":\"whatsapp\",\"pin\":\"%PIN%\"}"
```

`PIN` = the **old** PIN if this number was registered before.

✅ **Expected:** `{"success":true}`

| Error says | Do this |
| --- | --- |
| `The parameter messaging_product is required` | The JSON quotes got eaten. Every `"` inside `-d` must be `\"` exactly as above. Copy the command again. |
| `PIN Mismatch` | Use the old PIN |
| `133016` | Too many tries, wait 1 hour |
| `permission` | Add the WABA to the System User (Step 3) |

ℹ️ Limit: **2 numbers** per business until Business verification.

**Final check** (same command as Step 4):

**🍎** `curl "https://graph.facebook.com/v26.0/$WABA_ID/phone_numbers" -H "Authorization: Bearer $TOKEN"`
**🪟** `curl "https://graph.facebook.com/v26.0/%WABA_ID%/phone_numbers" -H "Authorization: Bearer %TOKEN%"`

✅ **Expected:** these 3 fields changed:

| Field | Before register | After register ✅ |
| --- | --- | --- |
| `platform_type` | `NOT_APPLICABLE` | **`CLOUD_API`** ← the one that matters |
| `throughput.level` | `NOT_APPLICABLE` | `STANDARD` |
| `quality_rating` | `UNKNOWN` | `GREEN` (or `UNKNOWN` for a while) |

Still `NOT_APPLICABLE` after `{"success":true}`? Wait 1–2 minutes and run the check again.

---

## 6. Connect App to WABA

> 💡 **الغرض:** بنقول لـ Meta: **رسايل الرقم ده تخص الـ App ده**. من غير الخطوة دي الـ App مش هيشوف أي رسالة.

**🍎 Mac / Linux**
```bash
curl -X POST "https://graph.facebook.com/v26.0/$WABA_ID/subscribed_apps" -H "Authorization: Bearer $TOKEN"
```

**🪟 Windows CMD**
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%WABA_ID%/subscribed_apps" -H "Authorization: Bearer %TOKEN%"
```

✅ **Expected:** `{"success":true}`

**Check:**

**🍎** `curl "https://graph.facebook.com/v26.0/$WABA_ID/subscribed_apps" -H "Authorization: Bearer $TOKEN"`
**🪟** `curl "https://graph.facebook.com/v26.0/%WABA_ID%/subscribed_apps" -H "Authorization: Bearer %TOKEN%"`

✅ **Expected:** your App inside `whatsapp_business_api_data`:

```json
{"data":[{"whatsapp_business_api_data":{
  "link":"https://www.facebook.com/games/?app_id=1xxxxxxxxxxxxxxx",
  "name":"Your-App-Name",
  "id":"1xxxxxxxxxxxxxxx"
}}]}
```

- `id` must equal your `APP_ID`.
- The `link` with `/games/` looks strange, but it's normal. Ignore it.
- `{"data":[]}` = the App is not connected → run the POST again.

---

## 7. n8n workflow

> 💡 **الغرض:** بنفتح **الباب** اللي Meta هتخبط عليه، ومعاه بواب بيتأكد من كلمة السر.

1. **Webhook node**
    - Allow multiple HTTP methods: **GET + POST**
    - **Path:** a unique value → `WEBHOOK_PATH`
    - Respond: **Using 'Respond to Webhook' Node**
2. **GET** → **IF node** (Check Verify Token)
    - `{{ $json.query['hub.mode'] }}` equals `subscribe`
    - `{{ $json.query['hub.verify_token'] }}` equals your `VERIFY_TOKEN`
    - true → **Respond to Webhook node**: Text = `{{ $('Webhook').item.json.query['hub.challenge'] }}`, code 200
    - false → **Respond to Webhook node**: No data, code 403
3. **POST** → **Respond to Webhook node**: No data, code 200 (respond **first**, process after)
4. Save + **Activate / Publish** (after **every** edit)

Where things live:

- **Path** = the last part of the URL
- **Verify token** = IF node, 2nd condition, right field

---

## 8. Test n8n (pretend to be Meta)

> 💡 **الغرض:** بنعمل **نفسنا Meta** ونخبط على الباب، عشان نتأكد إنه بيفتح لصاحبه **وبيقفل في وش الغريب**.

**Correct token:**

**🍎 Mac / Linux**
```bash
curl -i "https://$DOMAIN/webhook/$WEBHOOK_PATH?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=12345"
```

**🪟 Windows CMD**
```cmd
curl -i "https://%DOMAIN%/webhook/%WEBHOOK_PATH%?hub.mode=subscribe&hub.verify_token=%VERIFY_TOKEN%&hub.challenge=12345"
```

✅ **Expected:** first line `HTTP/2 200` (🍎) or `HTTP/1.1 200 OK` (🪟), and the **last line** is the body `12345`:

```
HTTP/1.1 200 OK
Content-Length: 5
Content-Type: text/html; charset=utf-8
...

12345
```

- `Content-Length: 5` = exactly 5 characters → `12345`.
- 🍎 shows `12345%`: the `%` is zsh, not part of the body (see Step 1).
- The other header lines (`Content-Security-Policy`, `Etag`, `Date`...) come from n8n. Ignore them.

**Wrong token:**

**🍎** `curl -i "https://$DOMAIN/webhook/$WEBHOOK_PATH?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=12345"`
**🪟** `curl -i "https://%DOMAIN%/webhook/%WEBHOOK_PATH%?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=12345"`

✅ **Expected:** first line `403` (`HTTP/2 403` or `HTTP/1.1 403 Forbidden`), and **no body** (nothing after the headers):

```
HTTP/1.1 403 Forbidden
Content-Type: application/json; charset=utf-8
...

```

| Result | Meaning |
| --- | --- |
| `404` | Workflow not active/published, or wrong Path |
| `200` but empty body | Return Challenge expression is wrong |
| `200` + `12345` with the **wrong** token | IF node is not checking the token → fix before going on |
| `403` with the correct token | Verify token in the IF node doesn't match |
| Hangs / timeout | The IF node's false branch is not connected to a Respond to Webhook node |

---

## 9. Register the webhook with Meta

> 💡 **الغرض:** بنروح لمكتب البريد (Meta) وندّيله **عنوان الباب**، عشان أي رسالة جديدة تيجي عليه.

**🍎 Mac / Linux**
```bash
curl -X POST "https://graph.facebook.com/v26.0/$APP_ID/subscriptions" -d "object=whatsapp_business_account" -d "callback_url=https://$DOMAIN/webhook/$WEBHOOK_PATH" -d "verify_token=$VERIFY_TOKEN" -d "fields=messages" -d "access_token=$APP_ID|$APP_SECRET"
```

**🪟 Windows CMD**
```cmd
curl -X POST "https://graph.facebook.com/v26.0/%APP_ID%/subscriptions" -d "object=whatsapp_business_account" -d "callback_url=https://%DOMAIN%/webhook/%WEBHOOK_PATH%" -d "verify_token=%VERIFY_TOKEN%" -d "fields=messages" -d "access_token=%APP_ID%|%APP_SECRET%"
```

✅ **Expected:** `{"success":true}`

At this moment Meta sends the same GET request you tested in Step 8. This is the **only** time Meta checks the verify token. Messages later come as POST without it.

**Check:**

**🍎** `curl "https://graph.facebook.com/v26.0/$APP_ID/subscriptions?access_token=$APP_ID|$APP_SECRET"`
**🪟** `curl "https://graph.facebook.com/v26.0/%APP_ID%/subscriptions?access_token=%APP_ID%|%APP_SECRET%"`

✅ **Expected:**

```json
{"data":[{
  "object":"whatsapp_business_account",
  "callback_url":"https://your-n8n-domain.com/webhook/your-webhook-path",
  "active":true,
  "fields":[{"name":"messages","version":"v26.0"}]
}]}
```

- `callback_url` = exactly your n8n URL
- `"active":true`
- `messages` inside `fields`, with the same version you use in the HTTP Request nodes

**Live test:** send a WhatsApp message to your business number → a new execution appears in n8n **Executions**.

Nothing arrives?

- App not **Published** → Meta only sends dashboard test webhooks, no real messages (yellow banner in App → Use cases → Customize → Step 2).
- Workflow not **Active / Published**.
- `messages` missing from `fields` in the check above.

---

## 10. Production checklist

- [ ] Verify `x-hub-signature-256` on every POST using the **App Secret** (blocks fake requests to your webhook URL)
- [ ] One Graph API version across all nodes (currently `v26.0`)
- [ ] Phone Number ID / WABA ID not hardcoded in every node; read from the webhook `metadata` or kept in one Config node per environment
- [ ] Verify token not typed inside the IF node in production; different per environment
- [ ] Replies sent to the sender from the incoming message (never a hardcoded `"to"`)
- [ ] Separate credentials + database for dev / demo / production
- [ ] Token stored only in n8n credentials (Header Auth: `Authorization: Bearer <token>`)
- [ ] If a token, App Secret or PIN was ever pasted in a chat or screenshot → **regenerate / reset it now**

---

## Appendix: the same command in all three Windows shells

Only if you need it. Pick ONE shell and stay in it.

| | CMD ✅ (this guide) | Git Bash | PowerShell (not recommended) |
| --- | --- | --- | --- |
| Set a variable | `set TOKEN=abc` | `export TOKEN="abc"` | `$env:TOKEN = "abc"` |
| Use it | `%TOKEN%` | `$TOKEN` | `$env:TOKEN` |
| curl command | `curl` | `curl` | `curl.exe` (plain `curl` is a different command) |
| Line continuation | none, one line | `\` | `` ` `` |
| JSON in `-d` | `"{\"a\":\"b\"}"` | `'{"a":"b"}'` | `'{\"a\":\"b\"}'` |
