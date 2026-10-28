# 06 — Tự xây OAuth Authorization Code và PKCE

[Trước: account lifecycle](05-account-lifecycle.md) · [Mục lục](../../README.md) · [Tiếp: OpenID Connect](07-openid-connect.md)

Điều kiện vào bài: đã có TLS local, PostgreSQL Identity, password/session của chương 05 và schema [identity.sql](../reference/sql/identity.sql). Đọc [implementation map](../reference/implementation-map.md) trước khi viết. Trong chương này, bạn tạo file **trong `lab/services/identity/src/`**; các đoạn code là phần triển khai cần tự gõ và kiểm tra, không phải server đã có sẵn trong repository giáo trình.

Mục tiêu là hoàn thành một state machine có thể giải thích được: browser được đưa tới IAM, IAM xác thực người dùng, xác nhận organization và consent, phát code dùng một lần, rồi BFF đổi code ở back channel. Password chỉ đi vào IAM. API khác không thu password để gửi hộ user. OAuth cấp quyền sử dụng API; chương sau mới thêm bằng chứng danh tính OIDC.

## 1. Các ranh giới cần giữ

```mermaid
sequenceDiagram
  participant B as Browser
  participant W as Web A BFF
  participant I as Identity
  participant D as Identity primary DB
  B->>W: GET /login
  W->>W: Tạo state, verifier, nonce; lưu transaction
  W-->>B: 302 /oauth2/authorize + challenge
  B->>I: Authorization request
  I->>D: Validate client và lưu request bất biến
  I-->>B: Login / chọn org / consent
  B->>I: POST consent + CSRF
  I->>D: Transaction: request used + grant + code hash
  I-->>B: 303 callback?code=...&state=...&iss=...
  B->>W: Callback
  W->>I: POST token + client auth + verifier
  I->>D: Lock grant/code; validate; consume; insert token hashes
  I-->>W: Opaque access token; refresh nếu được cấp
```

Code là credential ngắn hạn, không phải ID người dùng; `client_id` là identifier công khai, không phải secret. PKCE liên kết code với một verifier chỉ BFF biết. Client authentication xác nhận client confidential; nó không thay PKCE. Trong profile này mọi code flow đều dùng `S256`, exact redirect matching, state và nonce. Không triển khai password/implicit grant. Đây là lựa chọn profile dựa trên [OAuth Security BCP](https://www.rfc-editor.org/rfc/rfc9700.html); [PKCE RFC](https://www.rfc-editor.org/rfc/rfc7636.html) mô tả phép biến đổi verifier/challenge.

Không dùng `startsWith`, regex domain hoặc decode/normalize redirect rồi so sánh. So chuỗi được đăng ký nguyên vẹn. Nếu client hoặc redirect không hợp lệ, trả lỗi tại IAM; không redirect lỗi đến URI chưa tin cậy. Nếu redirect đã xác minh, lỗi authorization mới được đưa về callback cùng `state` và issuer. Không dùng giá trị `Host` làm issuer.

## 2. Tạo parser và client authentication

Chạy từ root giáo trình:

```powershell
New-Item -ItemType Directory -Force lab/services/identity/src/oauth | Out-Null
```

Seed chương 04 chưa có client secret. Trước request đầu tiên, tạo `scripts/bootstrap-client-secrets.ts` để sinh credential **chỉ cho fixture local**:

```ts
import { Pool } from 'pg';
import { randomBytes,createHash } from 'node:crypto';
import { writeFile,unlink } from 'node:fs/promises';
const url=process.env.MIGRATION_DATABASE_URL,output=process.env.CLIENT_SECRET_OUTPUT;
if(process.env.NODE_ENV!=='development'||!url||!output||
 !['127.0.0.1','localhost'].includes(new URL(url).hostname))throw new Error('Local fixture bootstrap only');
const ids=['web-a','web-b','invoice-api','iam-policy-api'];
const secrets=Object.fromEntries(ids.map(id=>[id,randomBytes(32).toString('base64url')]));
await writeFile(output,JSON.stringify(secrets),{flag:'wx',mode:0o600});
const pool=new Pool({connectionString:url,max:1});const db=await pool.connect();
try {
 await db.query('BEGIN');
 for(const id of ids) {
  const hash=createHash('sha256').update(secrets[id]!).digest();
  const r=await db.query('UPDATE clients SET secret_hash=$2 WHERE id=$1 AND kind=\'confidential\'',[id,hash]);
  if(r.rowCount!==1)throw new Error('Missing fixture client');
 }
 await db.query('COMMIT');console.log('Fixture client hashes initialized; secret values were not printed.');
} catch(error) {await db.query('ROLLBACK');await unlink(output);throw error;}
finally {db.release();await pool.end();}
```

```powershell
New-Item -ItemType Directory -Force lab/services/identity/scripts | Out-Null
$env:CLIENT_SECRET_OUTPUT=Join-Path (Resolve-Path lab/.secrets).Path 'client-secrets.json'
pnpm -C lab --filter @iam/identity exec node --env-file=.env --import tsx scripts/bootstrap-client-secrets.ts
$clientSecrets=Get-Content -Raw -Encoding utf8 $env:CLIENT_SECRET_OUTPUT | ConvertFrom-Json
$env:WEB_A_CLIENT_SECRET=$clientSecrets.'web-a'
$env:WEB_B_CLIENT_SECRET=$clientSecrets.'web-b'
$env:INVOICE_API_CLIENT_SECRET=$clientSecrets.'invoice-api'
$env:IAM_POLICY_API_CLIENT_SECRET=$clientSecrets.'iam-policy-api'
```

Output file đã tồn tại thì script dừng thay vì rotate credential ngầm. Nếu muốn chạy lại có chủ đích, dùng output filename mới và cập nhật mọi caller; không dùng bootstrap này làm production client management. Giữ các biến secret trong process hoặc `.env` riêng của từng service, không in `$clientSecrets` vào evidence. Nếu pool.connect thất bại trước transaction, có thể còn file secret chưa được áp dụng: xác minh DB và loại bỏ file local đó trước khi tạo lần mới, không suy đoán credential đã commit.

Tạo `oauth/common.ts`. File này dùng `pool` ở chương 04 và `hashToken` ở chương 05. Client secret của lab là 256 bit ngẫu nhiên nên có thể so hash SHA-256; password người dùng vẫn dùng Argon2id.

```ts
import { timingSafeEqual } from 'node:crypto';
import type { Request, Response, NextFunction } from 'express';
import type { PoolClient } from 'pg';
import { pool } from '../db.js';
import { hashToken } from '../security.js';
import { config } from '../config.js';

export const ISSUER = config.issuer;
export class ProtocolError extends Error {
  constructor(public error: string, public status = 400) { super(error); }
}
export function fields(raw: string): URLSearchParams {
  if (raw.length > 8192 || /%(?![\da-f]{2})/i.test(raw)) {
    throw new ProtocolError('invalid_request');
  }
  const p = new URLSearchParams(raw);
  const seen = new Set<string>();
  for (const [key, value] of p) {
    if (seen.has(key) || value.includes('\uFFFD')) throw new ProtocolError('invalid_request');
    seen.add(key);
  }
  return p;
}
export function required(p: URLSearchParams, key: string): string {
  const value = p.get(key);
  if (!value) throw new ProtocolError('invalid_request');
  return value;
}
export function scopes(raw: string): string[] {
  if (!raw || !/^[\x21\x23-\x5B\x5D-\x7E]+(?: [\x21\x23-\x5B\x5D-\x7E]+)*$/.test(raw)) {
    throw new ProtocolError('invalid_scope');
  }
  return [...new Set(raw.split(' '))];
}
export interface OAuthClient {
  id: string; kind: 'public' | 'confidential'; status: string;
  secret_hash: Buffer | null; token_endpoint_auth_method: string;
  redirect_uris: string[]; grant_types: string[]; allowed_scopes: string[];
  allowed_audiences: string[]; introspection_audiences: string[];
  service_org_id: string | null;
}
export async function authenticateClient(req: Request, p: URLSearchParams): Promise<OAuthClient> {
  let id = p.get('client_id') ?? ''; let secret: string | undefined;
  const header = req.get('authorization');
  if (header) {
    if (!/^Basic [A-Za-z0-9+/]+={0,2}$/.test(header) || p.has('client_secret')) {
      throw new ProtocolError('invalid_client', 401);
    }
    const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
    const colon = decoded.indexOf(':');
    if (colon < 0) throw new ProtocolError('invalid_client', 401);
    try {
      const unform = (v: string) => decodeURIComponent(v.replace(/\+/g, ' '));
      const basicId = unform(decoded.slice(0, colon));
      if (id && id !== basicId) throw new Error('mismatch');
      id = basicId; secret = unform(decoded.slice(colon + 1));
    } catch { throw new ProtocolError('invalid_client', 401); }
  } else if (p.has('client_secret')) {
    throw new ProtocolError('invalid_client', 401); // profile chưa hỗ trợ secret_post
  }
  const { rows } = await pool.query<OAuthClient>('SELECT * FROM clients WHERE id=$1', [id]);
  const c = rows[0];
  if (!c || c.status !== 'active') throw new ProtocolError('invalid_client', 401);
  if (c.kind === 'public' && c.token_endpoint_auth_method === 'none' && !header) return c;
  if (c.token_endpoint_auth_method !== 'client_secret_basic' || !secret || !c.secret_hash) {
    throw new ProtocolError('invalid_client', 401);
  }
  const presented = hashToken(secret);
  if (presented.length !== c.secret_hash.length || !timingSafeEqual(presented, c.secret_hash)) {
    throw new ProtocolError('invalid_client', 401);
  }
  return c;
}
export interface UserContext {
  user_id: string; org_id: string; session_id: string; client_id: string;
}
export async function liveUser(db: PoolClient, c: UserContext): Promise<boolean> {
  const r = await db.query(`SELECT 1 FROM users u
    JOIN sessions s ON s.user_id=u.id
    JOIN memberships m ON m.user_id=u.id AND m.org_id=$2
    JOIN organizations o ON o.id=m.org_id
    JOIN clients cl ON cl.id=$4
    JOIN app_assignments a ON a.client_id=cl.id AND a.org_id=o.id
    WHERE u.id=$1 AND s.id=$3 AND u.status='active' AND cl.status='active'
      AND m.status='active' AND o.status='active' AND a.status='active'
      AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp()`,
    [c.user_id, c.org_id, c.session_id, c.client_id]);
  return r.rowCount === 1;
}
export async function browserSession(req: Request) {
  // Cookie value của profile là base64url 32 byte, không cần URL-decode.
  const values = (req.headers.cookie ?? '').split(';').map(v=>v.trim())
    .filter(v=>v.startsWith(config.cookie.name+'='))
    .map(v=>v.slice(config.cookie.name.length+1));
  if (values.length!==1 || !/^[A-Za-z0-9_-]{43}$/.test(values[0]!)) return undefined;
  const raw = values[0]!;
  const r = await pool.query<{ id: string; user_id: string; authenticated_at: Date }>(
    `SELECT s.id,s.user_id,s.authenticated_at FROM sessions s JOIN users u ON u.id=s.user_id
     WHERE s.cookie_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp()
       AND u.status='active'`, [hashToken(raw)]);
  return r.rows[0];
}
export function protocolErrors(err: unknown, _req: Request, res: Response, next: NextFunction) {
  const pgCode = typeof err==='object' && err!==null && 'code' in err ? String(err.code) : '';
  const unavailable = ['ECONNREFUSED','ECONNRESET','ETIMEDOUT','57P01','57P02','57P03','28P01'].includes(pgCode)
    || pgCode.startsWith('08');
  if (unavailable) { res.set('Cache-Control','no-store').status(503).json({error:'temporarily_unavailable'}); return; }
  if (!(err instanceof ProtocolError)) return next(err);
  res.set('Cache-Control', 'no-store').set('Pragma', 'no-cache');
  if (err.error === 'invalid_client' && err.status === 401) res.set('WWW-Authenticate', 'Basic realm="iam"');
  res.status(err.status).json({ error: err.error });
}
```

`fields` giữ được duplicate detection; nếu dùng `Object.fromEntries` trước, thông tin duplicate đã mất. Áp dụng cùng parser cho query authorize và form token. Giới hạn kích thước cả ở proxy lẫn Express; lỗi body quá lớn phải đi qua error handler trả `413`, không stack trace.

Scope parser trong mọi router: parser form của chương 05 chỉ gắn trên `/login`/các POST browser thực sự cần nó. `router.use(urlencoded(...))` rồi mount router tại root sẽ parse cả `/oauth2/token` đi xuyên qua router; cần sửa thành route-specific parser trước khi test OAuth.

Connection pool acquire timeout không phải lúc nào cũng có `code`; wrapper `withTransaction`/pool query ở chương 04 phải chuyển timeout đã biết sang `AppError(503,'dependency_unavailable')`. Constraint/syntax/programming error vẫn là `500` và alert, không che mọi lỗi thành outage. Gọi `protocolErrors` trước generic handler chương 03; bổ sung test outage để chứng minh mapping thực tế của phiên bản `pg` đã pin.

## 3. Nhận request, login, chọn organization và consent

Handler `GET /oauth2/authorize` phải thực hiện theo thứ tự sau. Viết trong `oauth/authorize.ts`, dùng bảng `oauth_authorization_requests` đã có; không tạo thêm bảng khác tên.

1. Parse `req.originalUrl.split('?')[1] ?? ''` bằng `fields`; load client active. `response_type` phải là `code`; `response_mode` nếu có chỉ nhận `query`.
2. Xác minh `redirect_uri` nằm trong `client.redirect_uris`; `authorization_code` nằm trong `grant_types`. Scope là tập con `allowed_scopes`.
3. Bắt buộc challenge match `^[A-Za-z0-9_-]{43}$` và `code_challenge_method=S256`. Nếu request có `openid`, yêu cầu nonce không rỗng, tối đa 512 ký tự trong profile này. Giới hạn state 512 ký tự; không diễn giải nội dung state.
4. Audience chọn từ client registration: BFF lab chỉ cho `invoice-api`. Không thêm body parameter tùy ý ghi đè audience. Nếu hỗ trợ wire `resource`, chỉ chấp nhận đúng giá trị đã đăng ký; chưa quảng bá hỗ trợ RFC 8707 tổng quát.
5. Parse `prompt`/`max_age` theo chương 07; unknown scope trả `invalid_scope`. Unknown extension parameter có thể bỏ qua nhưng duplicate vẫn từ chối.
6. Sinh request handle bằng `newOpaqueToken()`, lưu `hashToken(handle)`, các field đã validate và expiry 5 phút. Set cookie `__Host-iam-interaction` bằng một handle đó, `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, không `Domain`. Cookie binding cộng form CSRF bảo vệ việc hoàn thành interaction; handle không được log.
7. Nếu session chưa có, đưa browser tới màn login chương 05. Login thành công chỉ cho phép tiếp tục request handle trong cookie; không nhận `returnTo=https://...` tùy ý. Sau login quay về `GET /oauth2/consent`.
8. Trang consent load request bằng cookie, kiểm tra TTL/used, load các membership active và app assignment active của user. Nếu request yêu cầu `org_id`, tổ chức đó phải thuộc tập này. Dùng HTML escaping cho tên tổ chức/client/scope trước khi render.

Ở consent, dùng một form POST gồm `org_id`, `decision=allow|deny` và CSRF token. CSRF token là 32 byte ngẫu nhiên lưu trong challenge server-side **hoặc** HMAC của `request_hash + session_id` với CSRF key riêng. Nếu dùng HMAC, tạo `oauth/csrf.ts` có `createHmac('sha256', key).update(requestHash).update(sessionId).digest('base64url')`; verify bằng constant-time; key từ secret file, không dùng signing key OIDC. `Origin` phải bằng issuer cho POST browser. Từ chối form không cookie, CSRF sai, origin sai hoặc session khác.

Không cho hidden field `user_id`, `scope`, `client_id`, `redirect_uri` quyết định dữ liệu phát code. Những field đó lấy từ session/request đã persist. `org_id` duy nhất do form chọn vẫn cần kiểm tra membership. Consent là ủy quyền scope cho ứng dụng; app assignment là tổ chức cho phép dùng ứng dụng; cả hai phải đúng.

Phần transaction khi user bấm Allow:

```ts
// Trong oauth/authorize.ts; db là PoolClient của withTransaction.
// pending là row đã SELECT ... FOR UPDATE bằng request_hash.
// session lấy từ browserSession, orgId là lựa chọn đã xác minh của user.
import { newOpaqueToken, hashToken } from '../security.js';
import { liveUser, ProtocolError, ISSUER } from './common.js';

// Đây là lõi cần đặt trong handler, không phải một file runnable độc lập.
if (!(await liveUser(db, { user_id: session.user_id, session_id: session.id,
  org_id: orgId, client_id: pending.client_id }))) throw new ProtocolError('access_denied');
await db.query(`INSERT INTO consents(user_id,org_id,client_id,scope)
 VALUES($1,$2,$3,$4) ON CONFLICT(user_id,org_id,client_id)
 DO UPDATE SET scope=EXCLUDED.scope,updated_at=clock_timestamp()`,
 [session.user_id, orgId, pending.client_id, pending.scope]);
const g = await db.query<{ id: string }>(`INSERT INTO oauth_grants
 (client_id,user_id,org_id,session_id,scope,audience,absolute_expires_at)
 VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+interval '30 days') RETURNING id`,
 [pending.client_id,session.user_id,orgId,session.id,pending.scope,pending.audience]);
const rawCode = newOpaqueToken();
await db.query(`INSERT INTO oauth_codes(code_hash,grant_id,client_id,user_id,org_id,
 session_id,redirect_uri,code_challenge,scope,audience,nonce,auth_time,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,clock_timestamp()+interval '60 seconds')`,
 [hashToken(rawCode),g.rows[0]!.id,pending.client_id,session.user_id,orgId,session.id,
  pending.redirect_uri,pending.code_challenge,pending.scope,pending.audience,
  pending.nonce,session.authenticated_at]);
await db.query('UPDATE oauth_authorization_requests SET used_at=clock_timestamp(),session_id=$2,org_id=$3 WHERE request_hash=$1',
 [pending.request_hash,session.id,orgId]);
const callback = new URL(pending.redirect_uri);
callback.searchParams.set('code', rawCode);
if (pending.state !== null) callback.searchParams.set('state', pending.state);
callback.searchParams.set('iss', ISSUER);
// Trả callback.href RA KHỎI withTransaction rồi res.redirect(303,...); chỉ redirect SAU commit.
```

Pending row được lock trước khi kiểm tra `used_at` và `expires_at`; request đồng thời không tạo hai grant. Deny cũng consume request, rồi redirect `error=access_denied`, state, iss. Nếu DB commit thất bại, không gửi code. Không giữ transaction mở trong thời gian user gõ password hoặc đọc consent.

## 4. Đổi code bằng transaction

Tạo `oauth/code.ts`. Đây là hàm triển khai hoàn chỉnh của phần exchange; handler gọi nó sau `authenticateClient`. Khi sang chương 07, bổ sung ID token vào **cùng kết quả transaction** trước commit.

```ts
import { createHash } from 'node:crypto';
import { withTransaction } from '../db.js';
import { hashToken, newOpaqueToken } from '../security.js';
import { liveUser, required, ProtocolError, type OAuthClient } from './common.js';

export async function exchangeCode(client: OAuthClient, p: URLSearchParams) {
  const raw = required(p, 'code');
  const verifier = required(p, 'code_verifier');
  const redirect = required(p, 'redirect_uri');
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) throw new ProtocolError('invalid_grant');
  const challenge = createHash('sha256').update(verifier, 'ascii').digest('base64url');
  const result = await withTransaction(async db => {
    // Lock grant TRƯỚC artifact: thống nhất với refresh/revoke, giảm deadlock.
    const found = await db.query('SELECT grant_id FROM oauth_codes WHERE code_hash=$1', [hashToken(raw)]);
    if (!found.rows[0]) return { error: 'invalid_grant' } as const;
    const grants = await db.query(`SELECT *,absolute_expires_at>clock_timestamp() AS fresh
      FROM oauth_grants WHERE id=$1 FOR UPDATE`, [found.rows[0].grant_id]);
    const rows = await db.query(`SELECT *,expires_at>clock_timestamp() AS fresh
      FROM oauth_codes WHERE code_hash=$1 FOR UPDATE`, [hashToken(raw)]);
    const c = rows.rows[0]; const g = grants.rows[0];
    if (!c || !g || c.client_id !== client.id || c.redirect_uri !== redirect || c.code_challenge !== challenge) {
      return { error: 'invalid_grant' } as const;
    }
    if (c.consumed_at) {
      await db.query('UPDATE oauth_grants SET revoked_at=clock_timestamp() WHERE id=$1', [g.id]);
      return { error: 'invalid_grant' } as const; // commit revoke rồi mới throw ngoài transaction
    }
    if (!c.fresh || !g.fresh || g.revoked_at || !(await liveUser(db, c)) ||
        !g.scope.every((scope:string)=>client.allowed_scopes.includes(scope)) ||
        !client.allowed_audiences.includes(g.audience)) return { error: 'invalid_grant' } as const;
    await db.query('UPDATE oauth_codes SET consumed_at=clock_timestamp() WHERE code_hash=$1', [hashToken(raw)]);
    const access = newOpaqueToken();
    const a = await db.query(`INSERT INTO oauth_tokens(token_hash,kind,grant_id,expires_at)
      VALUES($1,'access',$2,LEAST(clock_timestamp()+interval '5 minutes',$3))
      RETURNING EXTRACT(EPOCH FROM expires_at-issued_at)::integer AS ttl`,
      [hashToken(access),g.id,g.absolute_expires_at]);
    let refresh: string | undefined;
    if (g.scope.includes('offline_access') && client.grant_types.includes('refresh_token')) {
      refresh = newOpaqueToken();
      await db.query(`INSERT INTO oauth_tokens(token_hash,kind,grant_id,expires_at)
        VALUES($1,'refresh',$2,$3)`, [hashToken(refresh),g.id,g.absolute_expires_at]);
    }
    return { access_token: access, token_type: 'Bearer', expires_in: a.rows[0]!.ttl,
      scope: g.scope.join(' '), ...(refresh ? { refresh_token: refresh } : {}) };
  });
  if ('error' in result) throw new ProtocolError(result.error);
  return result;
}
```

Predicate `g.fresh` kiểm tra absolute expiry; code mới thông thường chưa chạm giới hạn, nhưng test cần sửa giờ expiry để bắt trường hợp đó. Không để constraint `expires_at > issued_at` trở thành cách xử lý lỗi credential. Current client scope/audience cũng được kiểm tra để registration bị thu hẹp có hiệu lực.

Wiring vào Express 5, trước error handler chung:

```ts
import express from 'express';
import { authenticateClient, fields, required, ProtocolError, protocolErrors } from './oauth/common.js';
import { exchangeCode } from './oauth/code.js';
// app là Express instance đã tạo ở chương 03; thêm routes trước app.use(errorHandler).
app.post('/oauth2/token', express.text({ type: 'application/x-www-form-urlencoded', limit: '8kb' }),
  async (req, res) => {
    if (!req.is('application/x-www-form-urlencoded') || typeof req.body !== 'string') throw new ProtocolError('invalid_request');
    const p = fields(req.body); const c = await authenticateClient(req, p);
    const grantType = required(p, 'grant_type');
    if (!c.grant_types.includes(grantType)) throw new ProtocolError('unauthorized_client');
    if (grantType !== 'authorization_code') throw new ProtocolError('unsupported_grant_type');
    res.set('Cache-Control','no-store').set('Pragma','no-cache').json(await exchangeCode(c,p));
  });
app.use(protocolErrors);
```

Nếu chương 03 đã có parser form toàn cục, exclude `/oauth2/*` trước khi dùng `express.text`; nếu không duplicate detection sẽ không làm việc. Chương 08 thêm refresh/client credentials vào **dispatcher này**, không mount ba handler token cạnh tranh nhau.

## 5. Tự gửi request và hiểu kết quả

Sinh verifier/challenge ở PowerShell, không ghi secret thật vào lịch sử lệnh:

```powershell
$verifier = node --input-type=module -e "import{randomBytes}from'node:crypto';process.stdout.write(randomBytes(32).toString('base64url'))"
$env:PKCE_VERIFIER = $verifier
$challenge = node --input-type=module -e "import{createHash}from'node:crypto';process.stdout.write(createHash('sha256').update(process.env.PKCE_VERIFIER).digest('base64url'))"
$state = [guid]::NewGuid().ToString('N')
$nonce = [guid]::NewGuid().ToString('N')
$authorize = 'https://iam.local.test:8443/oauth2/authorize?response_type=code&client_id=web-a&redirect_uri=https%3A%2F%2Fapp-a.local.test%3A8444%2Fcallback&scope=openid%20profile%20invoice.read%20offline_access&code_challenge_method=S256&code_challenge=' + $challenge + '&state=' + $state + '&nonce=' + $nonce
Start-Process $authorize
```

Trước khi BFF chương 09 có callback handler, browser có thể hiện lỗi kết nối ở callback; code trong thanh địa chỉ vẫn cho phép kiểm tra exchange thủ công **chỉ ở lab**. Không gửi URL callback cho người khác. Sau khi lấy code vào `$code`, Basic header lấy secret từ biến môi trường do bạn cấu hình:

```powershell
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('web-a:' + $env:WEB_A_CLIENT_SECRET))
$body = @{grant_type='authorization_code';code=$code;redirect_uri='https://app-a.local.test:8444/callback';code_verifier=$verifier}
$tokens = Invoke-RestMethod -Method Post -Uri 'https://iam.local.test:8443/oauth2/token' -Headers @{Authorization="Basic $basic"} -ContentType 'application/x-www-form-urlencoded' -Body $body
$tokens | Select-Object token_type,expires_in,scope
```

Kết quả **minh họa**, chưa phải output đã chạy: `Bearer`, khoảng `300`, scope được cấp. Không print `$tokens` toàn bộ hoặc bật verbose HTTP trong transcript. Đổi code lần hai phải thất bại; code của web-a đưa cho web-b phải thất bại. Nếu refresh được phát, hãy giữ trong memory của session PowerShell tới chương 08, không commit file token.

## 6. Negative, concurrency và failure lab

Tạo test DB thật trong `lab/services/identity/test/oauth-code.test.ts`. Fixture tạo một grant/code hợp lệ rồi gọi exchange function. Dùng `Promise.allSettled(Array.from({length:20},()=>exchangeCode(client,p)))`; đếm đúng một response thành công, phần còn lại `invalid_grant`. Sau đó kiểm tra grant đã revoke do replay và access token winner không còn active khi introspection hoàn thành ở chương 08. Đây là bảo vệ nghiêm: retry mạng có thể buộc đăng nhập lại; BFF không tự retry code exchange vô hạn.

Các test độc lập phải tạo code mới cho mỗi case: verifier sai, thiếu verifier, `plain`, duplicate `code`, client sai, redirect khác, expired code, revoked session, membership bị suspend, app assignment disabled, organization suspended, client disabled. Các case binding sai không được phát token hoặc tiết lộ code thuộc ai. Test `state` của client thuộc chương 09; IAM chỉ round-trip, không thay thế validation của BFF.

Failure lab: đặt breakpoint sau consume và trước commit, kill process. Transaction rollback; code có thể đổi lại vì chưa commit. Kill sau commit và trước HTTP response: retry code sẽ là reuse; không thể hứa exactly-once HTTP delivery. Ghi rõ kết quả này vào evidence. Tắt DB primary rồi gọi token endpoint: trả `503`, không sinh token memory fallback. Sau phục hồi, chạy lại invariant count và bảo đảm không có raw token trong application logs.

Troubleshooting: `invalid_client` thường do Basic bị base64 hai lần hoặc secret seed/hash không khớp; `invalid_grant` thường do verifier mới được sinh ở callback hoặc redirect có dấu `/` khác. Cookie mất thường vì gọi `http://localhost` trong khi issuer HTTPS host khác. `req.body` không phải string thường do parser toàn cục chạy trước. Không “sửa” bằng bỏ PKCE, dùng wildcard redirect hoặc tắt TLS validation.

## Definition of Done

- Authorize → login → chọn org → consent → code → token hoạt động qua TLS và client đã đăng ký.
- Request/code/grant/token binding được lưu server-side; form không ghi đè dữ liệu đã validate.
- Parser từ chối duplicate, token form dùng chuẩn, callback luôn exact và có state/iss.
- Negative/concurrency/fault tests có evidence thật; revoke do replay commit trước error response.
- Bạn giải thích được sự khác nhau giữa cookie IAM, code, access token, refresh token và client secret mà không gọi tất cả là JWT.

Đọc thêm phần error/redirect/code grant của [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749.html), [issuer identifier RFC 9207](https://www.rfc-editor.org/rfc/rfc9207.html). Chương này mới có OAuth; chỉ sau [chương 07](07-openid-connect.md) và [conformance gate](../reference/oidc-conformance.md) mới đánh giá được OIDC interoperability.
