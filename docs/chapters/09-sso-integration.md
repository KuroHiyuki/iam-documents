# 09 — Hai ứng dụng dùng SSO qua OIDC client độc lập

[Trước: token lifecycle](08-token-lifecycle-introspection.md) · [Mục lục](../../README.md) · [Tiếp: MFA và key management](10-mfa-key-management.md)

Điều kiện: authorize/code/refresh/discovery/JWKS/UserInfo chạy đúng qua TLS; schema và helpers chương 06–08 đã được tạo. Bạn sẽ viết hai BFF trong `lab/apps/web-a` và `lab/apps/web-b`. Server IAM vẫn tự triển khai; `openid-client` được dùng **ở phía relying party** để một implementation độc lập kiểm tra protocol bạn viết.

Browser chỉ giữ session cookie của từng ứng dụng. Access/refresh token nằm phía BFF, mã hóa khi lưu. IAM cookie chỉ được gửi đến `iam.local.test`, không chia sẻ cookie domain cho app-a/app-b. SSO xuất hiện vì khi app-b redirect browser đến IAM, IAM nhận lại phiên của chính nó và có thể xác thực người dùng mà không hỏi password lần nữa. Mỗi ứng dụng vẫn có client, callback, grant và token riêng.

## 1. Thấy đúng luồng SSO

```mermaid
sequenceDiagram
  participant B as Browser
  participant A as BFF A
  participant I as IAM
  participant C as BFF B
  B->>A: /login
  A-->>B: Redirect tới IAM
  B->>I: Login, chọn Acme, consent A
  I-->>B: Code dành web-a
  B->>A: Callback
  A->>I: Exchange code + verifier
  A-->>B: Cookie phiên A
  B->>C: /login
  C-->>B: Redirect tới IAM
  B->>I: Cookie phiên IAM còn valid
  I-->>B: Chọn org / consent B nếu cần, không nhập password lại
  B->>C: Code dành web-b
  C->>I: Exchange với client web-b
  C-->>B: Cookie phiên B
```

State và nonce là transaction-specific, không phải giá trị cố định của user. Một tab login không được ghi đè verifier của tab khác. Code của A không dùng cho B; consent/organization của A không tự cấp mọi quyền cho B. Browser back button quay lại callback không phải một login transaction mới.

Kiến trúc BFF được phân tích trong [OAuth Browser Applications BCP, RFC 10017](https://www.rfc-editor.org/rfc/rfc10017.html). Nó giảm lộ token cho JavaScript nhưng XSS vẫn có thể thao tác với phiên; cần CSP, escaping, CSRF và dependency hygiene.

## 2. Chuẩn bị BFF storage và package

Chương 03 mới tạo package Identity. Tạo hai package BFF trước khi dùng filter; không giả định `@iam/web-a` đã tồn tại:

```powershell
foreach($appName in @('web-a','web-b')) {
  $appDir=Join-Path 'lab/apps' $appName
  New-Item -ItemType Directory -Force (Join-Path $appDir 'src') | Out-Null
  @{name="@iam/$appName";private=$true;version='0.1.0';type='module';scripts=@{
    dev='node --import tsx src/app.ts';build='tsc -p tsconfig.json';
    typecheck='tsc -p tsconfig.json --noEmit';test='vitest run'
  }} | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $appDir 'package.json')
  Copy-Item -LiteralPath lab/services/identity/tsconfig.json -Destination (Join-Path $appDir 'tsconfig.json')
}
pnpm -C lab --filter @iam/web-a add express express-session connect-pg-simple pg openid-client
pnpm -C lab --filter @iam/web-a add -D typescript@5.9.3 tsx vitest @types/node@24 @types/express @types/express-session @types/connect-pg-simple @types/pg
pnpm -C lab --filter @iam/web-b add express express-session connect-pg-simple pg openid-client
pnpm -C lab --filter @iam/web-b add -D typescript@5.9.3 tsx vitest @types/node@24 @types/express @types/express-session @types/connect-pg-simple @types/pg
$env:NODE_EXTRA_CA_CERTS = Join-Path (mkcert -CAROOT) 'rootCA.pem'
```

`NODE_EXTRA_CA_CERTS` phải có trước khi Node khởi động. Không dùng flag bỏ TLS validation. Chương 03 đã ánh xạ local host/TLS. Cấu hình secret BFF bằng environment/secret file, không đưa vào bundle frontend. `CLIENT_ID=web-a`, `APP_ORIGIN=https://app-a.local.test:8444`, `PORT=3101`; web-b dùng client web-b, origin port 8445, backend 3102. Callback đúng `/callback` và post-logout URI đúng origin cộng `/` đã đăng ký trong seed clients.

`.npmrc` save-exact ở chương 03 lưu phiên bản được chọn; đối chiếu [versions](../reference/versions.md), pin cả hai app và commit lockfile. Mỗi BFF dùng database riêng hoặc database application của chính nó; không cấp quyền đọc Identity DB. Sinh local secret một lần và giữ file ngoài Git:

```powershell
$bffSecretPath=Join-Path (Resolve-Path lab/.secrets).Path 'bff-secrets.json'
if(Test-Path $bffSecretPath){throw 'BFF secrets already exist; reuse the existing file.'}
$bffJson=node --input-type=module -e "import{randomBytes}from'node:crypto';const x={};for(const n of['web-a','web-b'])x[n]={dbPassword:randomBytes(24).toString('hex'),dataKey:randomBytes(32).toString('base64'),sessionSecret:randomBytes(32).toString('base64url')};process.stdout.write(JSON.stringify(x))"
[IO.File]::WriteAllText($bffSecretPath,$bffJson,[Text.UTF8Encoding]::new($false))
$bffSecrets=Get-Content -Raw -Encoding utf8 $bffSecretPath | ConvertFrom-Json
@"
CREATE ROLE web_a_app LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$($bffSecrets.'web-a'.dbPassword)';
CREATE ROLE web_b_app LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$($bffSecrets.'web-b'.dbPassword)';
CREATE DATABASE web_a OWNER iam_migrator;
CREATE DATABASE web_b OWNER iam_migrator;
GRANT CONNECT ON DATABASE web_a TO web_a_app;
GRANT CONNECT ON DATABASE web_b TO web_b_app;
"@ | Set-Content -Encoding utf8 lab/.secrets/bff-databases.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml cp lab/.secrets/bff-databases.sql postgres:/tmp/bff-databases.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml exec -T postgres psql -U iam_migrator -d identity -v ON_ERROR_STOP=1 -f /tmp/bff-databases.sql
```

Role/database bootstrap chạy một lần; nếu có lỗi giữa chừng, inspect `pg_roles`/`pg_database` và chạy phần còn thiếu, không drop database để retry. Áp dụng migration sau với DB owner trong **cả** `web_a` và `web_b`:

```sql
CREATE TABLE "session"(sid varchar PRIMARY KEY,sess json NOT NULL,expire timestamp NOT NULL);
CREATE INDEX bff_session_expire_idx ON "session"(expire);
CREATE TABLE login_transactions(
 state_hash bytea PRIMARY KEY, session_id_hash bytea NOT NULL,
 encrypted_verifier bytea NOT NULL, nonce text NOT NULL, expires_at timestamptz NOT NULL);
CREATE TABLE bff_credentials(
 session_id_hash bytea PRIMARY KEY, encrypted_payload bytea NOT NULL,
 expires_at timestamptz NOT NULL);
-- web_a: GRANT USAGE ON SCHEMA public TO web_a_app;
-- GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO web_a_app;
-- web_b dùng web_b_app tương ứng, không cấp CREATE/owner cho runtime.
```

Lưu block thành migration của từng BFF, copy vào postgres rồi `psql -d web_a`/`-d web_b` như chương 04; chạy hai GRANT đúng role sau tạo bảng. Credential owner dùng cho migration, `BFF_DATABASE_URL` runtime dùng `web_a_app` hoặc `web_b_app`. Khóa database/role naming này trong runbook để tránh connect nhầm Identity.

Verifier trong login_transactions là credential ngắn hạn: mã hóa bằng helper cùng chương và chỉ giữ tới 5 phút. Session store `sess` chỉ giữ account/profile metadata; không chứa raw OAuth tokens. Credentials có expiry không muộn hơn absolute BFF session 12 giờ. Cleanup job xóa login transactions hết hạn, session hết hạn và credentials mồ côi. Không sao chép DB credential của Identity để tiết kiệm setup.

## 3. Kho token mã hóa và refresh serialize

Tạo `src/credentials.ts` ở mỗi BFF. Hai ứng dụng có cùng mã nguồn helper nhưng key/storage riêng. `BFF_DATA_KEY` là base64 của 32 byte ngẫu nhiên, `BFF_DATABASE_URL` là database của app. Sinh secret một lần bằng Node `randomBytes(32).toString('base64')`, lưu secret store; không in trong CI log.

```ts
import { createHash,createCipheriv,createDecipheriv,randomBytes } from 'node:crypto';
import { Pool } from 'pg';
import * as oidc from 'openid-client';
export const db=new Pool({connectionString:process.env.BFF_DATABASE_URL,max:10,connectionTimeoutMillis:2000});
const key=Buffer.from(process.env.BFF_DATA_KEY??'','base64');
if(key.length!==32)throw new Error('BFF_DATA_KEY must contain 32 bytes');
export const sidHash=(s:string)=>createHash('sha256').update(s).digest();
export interface Credentials { access:string;refresh?:string|undefined;idToken:string;sub:string;accessExpiresAt:number }
function encryptJson(value:unknown,sid:string,purpose:string):Buffer {
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv);
 cipher.setAAD(Buffer.concat([Buffer.from(`bff:v1:${purpose}:`),sidHash(sid)]));
 const body=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()]);
 return Buffer.concat([iv,cipher.getAuthTag(),body]);
}
function decryptJson<T>(b:Buffer,sid:string,purpose:string):T {
 const d=createDecipheriv('aes-256-gcm',key,b.subarray(0,12));
 d.setAAD(Buffer.concat([Buffer.from(`bff:v1:${purpose}:`),sidHash(sid)]));d.setAuthTag(b.subarray(12,28));
 return JSON.parse(Buffer.concat([d.update(b.subarray(28)),d.final()]).toString('utf8')) as T;
}
export const protectVerifier=(v:string,sid:string)=>encryptJson({verifier:v},sid,'login-verifier');
export const readVerifier=(b:Buffer,sid:string)=>decryptJson<{verifier:string}>(b,sid,'login-verifier').verifier;
export async function putCredentials(sid:string,c:Credentials):Promise<void> {
 await db.query(`INSERT INTO bff_credentials(session_id_hash,encrypted_payload,expires_at)
  VALUES($1,$2,clock_timestamp()+interval '12 hours')
  ON CONFLICT(session_id_hash) DO UPDATE SET encrypted_payload=EXCLUDED.encrypted_payload`,[sidHash(sid),encryptJson(c,sid,'credentials')]);
}
export async function accessFor(sid:string,config:oidc.Configuration):Promise<Credentials> {
 const conn=await db.connect();let committed=false;
 try {
  await conn.query('BEGIN');
  const r=await conn.query(`SELECT encrypted_payload FROM bff_credentials
   WHERE session_id_hash=$1 AND expires_at>clock_timestamp() FOR UPDATE`,[sidHash(sid)]);
  if(!r.rows[0])throw new Error('reauthentication_required');
  let c=decryptJson<Credentials>(r.rows[0].encrypted_payload,sid,'credentials');
  if(c.accessExpiresAt<=Date.now()+30000) {
   if(!c.refresh)throw new Error('reauthentication_required');
   const tokens=await oidc.refreshTokenGrant(config,c.refresh);
   c={...c,access:tokens.access_token,refresh:tokens.refresh_token??c.refresh,
    accessExpiresAt:Date.now()+(tokens.expires_in??300)*1000};
   await conn.query('UPDATE bff_credentials SET encrypted_payload=$2 WHERE session_id_hash=$1',[sidHash(sid),encryptJson(c,sid,'credentials')]);
  }
  await conn.query('COMMIT');committed=true;return c;
 } catch(error) {if(!committed)await conn.query('ROLLBACK');throw error;}
 finally {conn.release();}
}
export async function clearCredentials(sid:string):Promise<void> {
 await db.query('DELETE FROM bff_credentials WHERE session_id_hash=$1',[sidHash(sid)]);
}
export async function readCredentials(sid:string):Promise<Credentials|undefined> {
 const r=await db.query('SELECT encrypted_payload FROM bff_credentials WHERE session_id_hash=$1',[sidHash(sid)]);
 return r.rows[0]?decryptJson<Credentials>(r.rows[0].encrypted_payload,sid,'credentials'):undefined;
}
```

Lock row serialize refresh qua các BFF replicas, không chỉ qua promises trong một process. Network call ở transaction này có timeout ngắn vì phải giữ lock; `openid-client` config timeout đặt 5 giây và pool queue có giới hạn. AAD bind version, purpose và session hash để ciphertext của user này không thể chuyển sang row user khác. Production cần key ID/envelope encryption để rotate data key, backup key và ACL. Crypto library làm AES; không dùng password làm AES key.

Nếu IAM đã rotate nhưng BFF crash trước khi lưu successor, BFF chỉ còn old refresh. Retry có thể revoke family: trả người dùng về login. Không auto-retry refresh khi không biết server đã commit hay chưa. Trong production phân biệt invalid_grant (reauth), dependency timeout (503, có recovery path) và local decryption failure (503 + alert); không trả nội dung lỗi secret cho browser.

## 4. Login và callback dùng openid-client

Tạo `src/app.ts`. Đây là BFF skeleton có đầy đủ transaction login, không phải SPA lưu token localStorage. App không tự validate ID token bằng regex; client library thực hiện discovery, signature và claim checks.

```ts
import express from 'express';
import session from 'express-session';
import connectPgSimple from 'connect-pg-simple';
import * as oidc from 'openid-client';
import { db,sidHash,putCredentials,accessFor,clearCredentials,protectVerifier,readVerifier } from './credentials.js';
declare module 'express-session' { interface SessionData { user?:{sub:string;createdAt:number};csrf?:string } }
const origin=process.env.APP_ORIGIN!;const clientId=process.env.CLIENT_ID!;
const callback=`${origin}/callback`;const issuer='https://iam.local.test:8443';
if(!origin||!clientId||!process.env.CLIENT_SECRET||!process.env.BFF_SESSION_SECRET)throw new Error('Missing BFF configuration');
const config=await oidc.discovery(new URL(issuer),clientId,
 {token_endpoint_auth_method:'client_secret_basic'},oidc.ClientSecretBasic(process.env.CLIENT_SECRET));
config.timeout=5;
const app=express();app.set('trust proxy','loopback');
app.use(session({store:new (connectPgSimple(session))({pool:db,createTableIfMissing:false}),
 name:'__Host-bff-session',secret:process.env.BFF_SESSION_SECRET,resave:false,saveUninitialized:false,
 rolling:true,cookie:{secure:true,httpOnly:true,sameSite:'lax',path:'/',maxAge:30*60*1000}}));
app.use(express.urlencoded({extended:false,limit:'8kb'}));
const save=(req:express.Request)=>new Promise<void>((resolve,reject)=>req.session.save(e=>e?reject(e):resolve()));
const regenerate=(req:express.Request)=>new Promise<void>((resolve,reject)=>req.session.regenerate(e=>e?reject(e):resolve()));
const destroy=(req:express.Request)=>new Promise<void>((resolve,reject)=>req.session.destroy(e=>e?reject(e):resolve()));
app.get('/login',async(req,res)=>{
 const state=oidc.randomState(),nonce=oidc.randomNonce(),verifier=oidc.randomPKCECodeVerifier();
 req.session.csrf??=oidc.randomState();await save(req);
 await db.query(`INSERT INTO login_transactions(state_hash,session_id_hash,encrypted_verifier,nonce,expires_at)
  VALUES($1,$2,$3,$4,clock_timestamp()+interval '5 minutes')`,[sidHash(state),sidHash(req.sessionID),protectVerifier(verifier,req.sessionID),nonce]);
 const target=oidc.buildAuthorizationUrl(config,{redirect_uri:callback,response_type:'code',
  scope:'openid profile email invoice.read offline_access',state,nonce,
  code_challenge:await oidc.calculatePKCECodeChallenge(verifier),code_challenge_method:'S256'});
 res.redirect(302,target.href);
});
app.get('/callback',async(req,res)=>{
 const url=new URL(req.originalUrl,origin);const states=url.searchParams.getAll('state');
 if(states.length!==1) return res.status(400).send('Login transaction invalid');
 const state=states[0]!;
 const tx=await db.query(`DELETE FROM login_transactions WHERE state_hash=$1
  AND session_id_hash=$2 AND expires_at>clock_timestamp() RETURNING encrypted_verifier,nonce`,[sidHash(state),sidHash(req.sessionID)]);
 const pending=tx.rows[0];if(!pending)return res.status(400).send('Login transaction missing or already used');
 const tokens=await oidc.authorizationCodeGrant(config,url,{pkceCodeVerifier:readVerifier(pending.encrypted_verifier,req.sessionID),
  expectedState:state,expectedNonce:pending.nonce,idTokenExpected:true});
 const claims=tokens.claims();if(!claims||!tokens.id_token)throw new Error('ID token required');
 const user=await oidc.fetchUserInfo(config,tokens.access_token,claims.sub);
 if(user.sub!==claims.sub)throw new Error('UserInfo subject mismatch');
 await regenerate(req); // session fixation defense, sau xác thực và trước gắn identity
 req.session.user={sub:claims.sub,createdAt:Date.now()};req.session.csrf=oidc.randomState();
 await putCredentials(req.sessionID,{access:tokens.access_token,refresh:tokens.refresh_token,
  idToken:tokens.id_token,sub:claims.sub,accessExpiresAt:Date.now()+(tokens.expires_in??300)*1000});
 await save(req);res.redirect(303,'/me');
});
app.get('/me',async(req,res)=>{
 if(!req.session.user||Date.now()-req.session.user.createdAt>=12*60*60*1000)return res.sendStatus(401);
 const c=await accessFor(req.sessionID,config);
 // Mỗi protected request của chính BFF vẫn kiểm tra online qua UserInfo.
 const user=await oidc.fetchUserInfo(config,c.access,c.sub);
 res.set('Cache-Control','no-store').json({sub:user.sub,email:user.email,csrf:req.session.csrf});
});
app.get('/invoices',async(req,res)=>{
 if(!req.session.user||Date.now()-req.session.user.createdAt>=12*60*60*1000)return res.sendStatus(401);
 const c=await accessFor(req.sessionID,config);
 const response=await fetch('https://api.local.test:8446/v1/invoices',{
  headers:{authorization:`Bearer ${c.access}`},signal:AbortSignal.timeout(5000)});
 res.set('Cache-Control','no-store').status(response.status).type('application/json').send(await response.text());
});
// Chèn logout routes ở mục tiếp theo trước error handler và listen.
app.use(async(error:unknown,req:express.Request,res:express.Response,_next:express.NextFunction)=>{
 // Log request ID/reason code qua logger chung; không log error có token response.
 const reauth=(error instanceof Error&&error.message==='reauthentication_required')
  ||(error instanceof oidc.ResponseBodyError&&error.error==='invalid_grant')
  ||(error instanceof oidc.WWWAuthenticateChallengeError&&error.status===401);
 if(reauth) {
  try {await clearCredentials(req.sessionID);await destroy(req);}
  catch {res.status(503).json({error:'dependency_unavailable'});return;}
  res.clearCookie('__Host-bff-session',{secure:true,httpOnly:true,sameSite:'lax',path:'/'});
 }
 res.status(reauth?401:503).json({error:reauth?'login_required':'dependency_unavailable'});
});
app.listen(Number(process.env.PORT), '127.0.0.1');
```

Callback dùng atomic `DELETE ... RETURNING`: hai request không claim cùng state; state còn bị bind với pre-login session cookie. Đã claim nhưng exchange lỗi thì transaction mất hiệu lực và user bắt đầu login mới. Đó là an toàn hơn cho phép callback retry vô hạn. Nhiều tab có nhiều rows nên không overwrite verifier. Regenerate session sau login, không trước khi lookup state. Không dựng callback base URL từ untrusted host header.

Error mapper phân biệt invalid_grant và UserInfo Bearer challenge `401` với dependency/configuration failures. Bổ sung JSON error `401` của UserInfo nếu server đã chọn wire response đó; handler UserInfo chương 07 trả Bearer challenge. Policy deny từ API giữ `403`. Thêm wrapper log redaction theo chương observability trước kết nối nguồn dữ liệu thật.

## 5. Logout có nghĩa gì

Logout riêng BFF xóa cookie/credentials A; cookie IAM và phiên B còn. Logout IAM revoke session và grants gắn với nó; BFF B có thể vẫn hiển thị shell UI nhưng protected request tiếp theo phải thất bại online. Muốn chủ động xóa session B ngay lập tức cần back-channel logout, là milestone bổ sung, không được tuyên bố đã có chỉ vì A logout.

Để local logout và RP-initiated logout, thêm `timingSafeEqual` từ node:crypto và `readCredentials` từ credentials vào imports của `app.ts`, rồi đặt các routes sau trước error handler:

```ts
function validBrowserPost(req:express.Request):boolean {
 const actual=Buffer.from(req.get('x-csrf-token')??String(req.body?.csrf??''));
 const expected=Buffer.from(req.session.csrf??'');
 return req.get('origin')===origin&&expected.length>0&&actual.length===expected.length
  &&timingSafeEqual(actual,expected);
}
async function clearLocal(req:express.Request,res:express.Response):Promise<void> {
 await clearCredentials(req.sessionID);await destroy(req);
 res.clearCookie('__Host-bff-session',{secure:true,httpOnly:true,sameSite:'lax',path:'/'});
}
app.get('/',(_req,res)=>res.type('html').send('<a href="/login">Đăng nhập</a>'));
app.post('/logout-local',async(req,res)=>{
 if(!validBrowserPost(req))return res.sendStatus(403);
 await clearLocal(req,res);res.redirect(303,'/');
});
app.post('/logout',async(req,res)=>{
 if(!validBrowserPost(req))return res.sendStatus(403);
 const c=await readCredentials(req.sessionID); // không refresh chỉ để logout
 const target=c?oidc.buildEndSessionUrl(config,{id_token_hint:c.idToken,
  post_logout_redirect_uri:origin+'/'}).href:'/';
 await clearLocal(req,res);res.redirect(303,target);
});
```

Route GET `/` là public, không thay đổi authentication state. CSRF lấy từ `/me` và gửi qua form/header; không nhận CSRF trong URL. Đăng ký logout endpoint của IAM và cập nhật discovery **trước** khi restart BFF dùng `buildEndSessionUrl`.

Landing `/` chỉ hiển thị signed-out nên profile không cần logout state để tạo mutation tiếp theo. Nếu thêm callback hậu logout có side effect, lưu và kiểm logout state một lần riêng; không tái sử dụng login state table mà không phân loại transaction. Logout không cần refresh token còn dùng được.

Phía IAM triển khai GET/POST `/oauth2/logout` theo [RP-Initiated Logout](https://openid.net/specs/openid-connect-rpinitiated-1_0.html): validate hint signature, issuer và client audience; `post_logout_redirect_uri` phải exact match registration. **Expired ID token vẫn có thể là hint hợp lệ cho session hiện tại/gần đây**; không dùng validator authentication buộc exp còn hạn rồi chặn mọi logout. Dùng signature verification và kiểm tra claims/logout-specific policy riêng. JWT hint không tự tạo một phiên mới.

GET render trang xác nhận; POST cần cookie IAM, CSRF và confirmation. Khi thiếu hint hoặc hint không thuộc session hiện tại, bắt buộc hỏi user trước khi logout. Không có bằng chứng hợp lệ cho redirect target thì hiển thị trang signed-out local IAM, không redirect. Transaction POST lock session, set `sessions.revoked_at`, revoke các grant `session_id` tương ứng, commit rồi clear cookie và redirect target đã đăng ký. Không nhận `sid` của account khác từ form. Add `end_session_endpoint` vào discovery sau khi đã làm.

## 6. Thử hai ứng dụng và tấn công callback

Chạy mỗi app trong terminal riêng với env tương ứng:

```powershell
$env:CLIENT_ID='web-a'
$env:APP_ORIGIN='https://app-a.local.test:8444'
$env:PORT='3101'
$env:CLIENT_SECRET=$env:WEB_A_CLIENT_SECRET
$bffSecrets=Get-Content -Raw -Encoding utf8 lab/.secrets/bff-secrets.json | ConvertFrom-Json
$env:BFF_DATABASE_URL='postgresql://web_a_app:'+$bffSecrets.'web-a'.dbPassword+'@127.0.0.1:5432/web_a'
$env:BFF_DATA_KEY=$bffSecrets.'web-a'.dataKey
$env:BFF_SESSION_SECRET=$bffSecrets.'web-a'.sessionSecret
pnpm -C lab --filter @iam/web-a dev
```

Terminal web-b thay tất cả `web-a`/web_a/web_a_app bằng `web-b`/web_b/web_b_app và port/origin theo bảng. Mỗi terminal mới cần đọc client-secrets chương 06 và đặt Node CA trước khởi động; không tạo key mới chỉ vì mở terminal khác.

Mở browser A login Alice vào Acme; sau đó mở app-b cùng browser. Kỳ vọng không nhập lại password IAM khi session còn hạn; consent B và chọn org vẫn có thể xuất hiện. Mở private window để xác nhận không có IAM cookie thì phải login. Bob chỉ thuộc Beta theo fixtures, nên chọn Acme không thành công. Không dùng cookie A gửi app B để “test SSO”; hai cookie có boundary riêng.

Negative cases: sửa state trong callback, callback không pre-login cookie, duplicate state parameter, nonce mismatch, code từ client khác, UserInfo subject mismatch, issuer đổi, JWKS sai key. Tất cả đều dừng trước khi gắn `req.session.user`. Hai callback đồng thời cùng state chỉ một row được claim. Hai protected requests lúc access gần expiry trên hai BFF replicas chỉ có một refresh network call; request thứ hai đọc successor đã persist.

Failure lab: dừng Identity rồi gọi `/me` hoặc API; không trả profile cache làm authorization success, mà trả `503`. Revoke IAM session rồi gọi `/me`; trả `401` sau phân loại UserInfo inactive. Dừng BFF DB trước callback; không tạo memory session fallback. Kill BFF sau IAM rotation nhưng trước local persist; tái đăng nhập khi old refresh bị reuse. Ghi bằng chứng expected/actual riêng, không khẳng định test pass trước khi chạy.

Troubleshooting: `state missing` có thể vì SameSite/domain/TLS cookie; `issuer mismatch` do issuer có dấu `/` khác; `invalid_client` do client library mặc định auth method khác Basic — ví dụ đã cấu hình Basic tường minh. Nhiều tab lỗi thường do chỉ lưu một verifier trong session. Missing ID token thường do scope không có `openid` hoặc server chưa thêm signing vào transaction. Không sửa bằng `skipStateCheck` hay bỏ expectedNonce.

## Definition of Done

- Hai BFF dùng discovery/client library độc lập, state/nonce/PKCE đúng, session fixation bị chặn.
- Raw OAuth tokens không tới browser, session metadata không chứa token, encrypted token store có key riêng.
- Callback one-use và refresh serialize qua replica; dependency lỗi không dùng cached allow.
- Local logout, IAM logout và hạn chế của single logout được kiểm chứng bằng hai app.
- Artifacts được redact; chạy tiếp [conformance gate](../reference/oidc-conformance.md), dùng [openid-client examples](https://github.com/panva/openid-client/tree/main/examples) để so API khi pin phiên bản.
