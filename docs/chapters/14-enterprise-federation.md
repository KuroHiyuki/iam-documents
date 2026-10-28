# 14. Enterprise federation: tự làm OIDC broker và tích hợp SAML an toàn

[Mục lục](../../README.md) · [Trước: policy nâng cao](13-advanced-authorization.md) · [Tiếp: SCIM](15-scim-provisioning.md)

**Điều kiện đầu vào:** Identity local đã cấp code/token đúng, session/MFA hoạt động, bạn đã đọc chương 06–10. Các đoạn code thuộc lab/services/identity/src/federation. Ta tự triển khai OAuth/OIDC của platform; thư viện SAML chỉ xử lý XML signature/protocol phía SP. Nó không thay Identity Core bằng một sản phẩm IdP dựng sẵn.

## 14.1. Trust model: đăng nhập thành công chưa tạo membership

Customer Acme có corporate IdP. Platform của bạn là OIDC provider đối với Web A/B, đồng thời là OIDC client hoặc SAML service provider đối với IdP Acme. Browser không được gửi upstream token thẳng vào Invoice API; sau federation thành công, Identity kiểm tra user/membership/app assignment rồi tạo session/grant của chính platform.

Một external identity được xác định bởi connection và stable upstream subject. Không merge account theo email; email có thể đổi, được tái sử dụng hoặc không được upstream xác minh. Mapping tới global user được admin tạo trước hoặc user tự link sau khi chứng minh cả hai identities. Default chương này tắt JIT provisioning; chương SCIM sẽ tạo membership theo workflow rõ ràng.

Connection thuộc một organization, có enabled state, issuer/entity ID, pinned keys/certificates, allowlisted endpoints và policy mapping. Tenant hint chỉ chọn connection đã được admin đăng ký; không lấy một issuer URL bất kỳ từ query rồi fetch discovery vì sẽ tạo SSRF/trust confusion. Corporate SSO của Acme không tự đủ để vào Beta nếu Beta yêu cầu một nguồn xác thực khác.

## 14.2. Migration giữ state và replay protection

Tạo migration tiếp theo trong Identity, không chạy vào database Governance. Foreign keys dưới đây cùng database Identity:

```sql
CREATE TABLE federation_connections (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL REFERENCES organizations(id),
  protocol text NOT NULL CHECK(protocol IN ('oidc','saml')),
  issuer text NOT NULL,
  config jsonb NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  version bigint NOT NULL DEFAULT 1,
  UNIQUE(org_id,id)
);
CREATE TABLE linked_identities (
  connection_id uuid NOT NULL REFERENCES federation_connections(id),
  upstream_subject text NOT NULL,
  user_id uuid NOT NULL REFERENCES users(id),
  PRIMARY KEY(connection_id,upstream_subject)
);
CREATE TABLE federation_transactions (
  state_hash bytea PRIMARY KEY,
  connection_id uuid NOT NULL REFERENCES federation_connections(id),
  oauth_request_hash bytea NOT NULL REFERENCES oauth_authorization_requests(request_hash),
  browser_hash bytea NOT NULL,
  nonce_hash bytea,
  verifier_box bytea,
  connection_version bigint NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz
);
CREATE TABLE federation_replays (
  connection_id uuid NOT NULL REFERENCES federation_connections(id),
  assertion_id text NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(connection_id,assertion_id)
);
CREATE TABLE federation_saml_cache (
  connection_id uuid NOT NULL,
  key text NOT NULL,
  value text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(connection_id,key)
);
```

Transaction state TTL 5 phút, một lần, bind original OAuth interaction, connection version và browser cookie. Cookie __Host-fed dùng Secure/HttpOnly/Path=/ và SameSite=None vì SAML ACS là cross-site POST; cookie phiên login chính vẫn giữ policy cũ. Không nới cookie session toàn platform chỉ để SAML hoạt động. Rate limit start/ACS, body limit 128 KiB, reject duplicate parameters.

PKCE verifier phải đọc lại khi token exchange, nên không chỉ hash nó. Tạo box.ts với key riêng 32 byte từ secret manager, khác signing key:

```ts
import {createCipheriv,createDecipheriv,randomBytes} from "node:crypto";
function key(): Buffer {
  const value = Buffer.from(process.env.FEDERATION_BOX_KEY ?? "","base64");
  if (value.length!==32) throw new Error("FEDERATION_BOX_KEY must hold 32 bytes");
  return value;
}
export function seal(text:string, connectionId:string): Buffer {
  const iv=randomBytes(12), cipher=createCipheriv("aes-256-gcm",key(),iv);
  cipher.setAAD(Buffer.from(connectionId));
  const ciphertext=Buffer.concat([cipher.update(text,"utf8"),cipher.final()]);
  return Buffer.concat([iv,cipher.getAuthTag(),ciphertext]);
}
export function open(box:Buffer, connectionId:string): string {
  if (box.length<28) throw new Error("invalid_box");
  const decipher=createDecipheriv("aes-256-gcm",key(),box.subarray(0,12));
  decipher.setAAD(Buffer.from(connectionId));
  decipher.setAuthTag(box.subarray(12,28));
  return Buffer.concat([decipher.update(box.subarray(28)),decipher.final()]).toString("utf8");
}
```

Production ghi key version bên cạnh box để rotation đọc được dữ liệu cũ; bài local giữ một key trong file secret ignored. Không print nó vào evidence.

## 14.3. OIDC federation theo Authorization Code + PKCE

Tạo một instance Identity fixture độc lập ở issuer/port khác hoặc dùng corporate test tenant do bạn kiểm soát. Instance fixture có database/signing keys riêng; chỉ làm upstream test, không thay implementation chính. Đăng ký client iam-federation với redirect URI cố định https://iam.local.test:8443/federation/oidc/callback. Discovery của connection được admin fetch có URL allowlist, HTTPS, bounded response và redirect disabled; persist issuer, authorization_endpoint, token_endpoint, jwks_uri sau khi đối chiếu issuer chính xác.

Start endpoint đọc original interaction cookie từ chương 06, kiểm tra oauth_authorization_requests còn sống và organization khớp connection; tạo state, nonce, verifier, browser secret bằng newOpaqueToken. Lưu hashes/box rồi redirect:

```ts
import {createHash} from "node:crypto";
import {newOpaqueToken,hashToken} from "../security.js";
import {seal} from "./box.js";
// db=PoolClient transaction; connection/config lấy từ database, không từ querystring.
const state=newOpaqueToken(), nonce=newOpaqueToken(), verifier=newOpaqueToken();
const browser=newOpaqueToken();
await db.query(
  "INSERT INTO federation_transactions(state_hash,connection_id,oauth_request_hash," +
  "browser_hash,nonce_hash,verifier_box,connection_version,expires_at)" +
  " VALUES($1,$2,$3,$4,$5,$6,$7,now()+interval '5 minutes')",
  [hashToken(state),connection.id,pending.request_hash,hashToken(browser),
   hashToken(nonce),seal(verifier,connection.id),connection.version]
);
const upstream=new URL(config.authorization_endpoint);
upstream.search=new URLSearchParams({
  response_type:"code",client_id:config.client_id,
  redirect_uri:"https://iam.local.test:8443/federation/oidc/callback",
  scope:"openid profile email",state,nonce,max_age:"300",code_challenge_method:"S256",
  code_challenge:createHash("sha256").update(verifier).digest("base64url")
}).toString();
// Commit transaction trước set cookie/redirect; dùng serialize cookie đã học ở chương 05.
```

Callback không dựa vào cookie session hiện có để bỏ state validation. Reject error response không có state hợp lệ. Đọc transaction còn sống, browser hash khớp cookie, connection enabled/version không đổi, rồi exchange code qua backend HTTPS với timeout/redirect:error, client authentication đã đăng ký và PKCE verifier đã decrypt. Không mở transaction SQL suốt network call.

```ts
export async function exchangeUpstream(config:{
  token_endpoint:string;client_id:string;client_secret:string;
},code:string,verifier:string):Promise<string> {
  const basic=Buffer.from(encodeURIComponent(config.client_id)+":"+
    encodeURIComponent(config.client_secret)).toString("base64");
  const r=await fetch(config.token_endpoint,{
    method:"POST",redirect:"error",signal:AbortSignal.timeout(2000),
    headers:{Authorization:"Basic "+basic,"Content-Type":"application/x-www-form-urlencoded"},
    body:new URLSearchParams({
      grant_type:"authorization_code",code,code_verifier:verifier,
      redirect_uri:"https://iam.local.test:8443/federation/oidc/callback"
    })
  });
  if (!r.ok) throw new Error("upstream_token_failed");
  const body=await r.json() as {id_token?:unknown};
  if (typeof body.id_token!=="string" || body.id_token.length>16384)
    throw new Error("upstream_token_contract_invalid");
  return body.id_token;
}
```

Dùng jose chỉ để verify JWT, không để triển khai thay protocol:

```ts
import {createRemoteJWKSet,jwtVerify} from "jose";
import {timingSafeEqual} from "node:crypto";
import {hashToken} from "../security.js";
const keys=createRemoteJWKSet(new URL(config.jwks_uri),{
  timeoutDuration:1500,cooldownDuration:30000
});
const result=await jwtVerify(upstreamIdToken,keys,{
  issuer:connection.issuer,audience:config.client_id,
  algorithms:["RS256"],clockTolerance:30,requiredClaims:["sub","iat","exp","nonce","auth_time"]
});
const p=result.payload;
if (typeof p.sub!=="string" || typeof p.nonce!=="string" ||
    !timingSafeEqual(hashToken(p.nonce),transaction.nonce_hash)) throw new Error("upstream_nonce_mismatch");
if (Array.isArray(p.aud) && p.aud.length>1 && p.azp!==config.client_id) throw new Error("upstream_azp_mismatch");
if (p.azp!==undefined && p.azp!==config.client_id) throw new Error("upstream_azp_mismatch");
if (typeof p.auth_time!=="number" || p.auth_time>Date.now()/1000+30 ||
    p.auth_time<Date.now()/1000-300) throw new Error("upstream_authentication_too_old");
```

JWKS key cache phục vụ signature keys, không phải cache allow/membership. Pin issuer và jwks_uri theo connection; network policy chặn private metadata endpoints ngoại trừ fixture local explicit. Không dùng token header jku/x5u do upstream token tự chọn để tải key.

Sau verify, khoá transaction state bằng SELECT FOR UPDATE và kiểm tra lại chưa consumed; code exchange network có thể diễn ra hai lần trong race nhưng chỉ một callback được tạo session. Persist consumed state và session atomically. Refresh tokens upstream nếu nhận được phải được mã hoá, có lifecycle riêng; baseline không xin offline_access nên không cần lưu upstream refresh.

## 14.4. SAML fixture thật và SP configuration

Cài dependency của module Identity:

```powershell
pnpm -C lab --filter @iam/identity add @node-saml/node-saml@5.2.0 @xmldom/xmldom
docker pull ghcr.io/pfrest/mock-saml2-idp:latest
docker run --detach --name iam-test-saml-idp --publish 127.0.0.1:8081:8080 --env SP_ENTITY_ID=https://iam.local.test:8443/federation/saml/acme/metadata --env SP_ACS_LOCATION=https://iam.local.test:8443/federation/saml/acme/acs --env IDP_ENTITY_ID=urn:iam:test:acme --env IDP_AUTH_MODE=auto --env IDP_USER_UID=alice-upstream --env IDP_USER_EMAIL=alice@example.test ghcr.io/pfrest/mock-saml2-idp:latest
$fixture = Invoke-RestMethod http://127.0.0.1:8081/api/settings.php
$fixture.idp_cert | Set-Content -Encoding utf8 lab/.secrets/acme-idp-cert.pem
docker image inspect ghcr.io/pfrest/mock-saml2-idp:latest --format '{{index .RepoDigests 0}}'
```

Ghi image digest vào evidence/Compose để lần sau tái lập; latest chỉ dùng bootstrap khám phá fixture, không production pinning. Không publish port HTTP fixture ra LAN. Fixture auto login không kiểm tra danh tính thật, chỉ dùng data example.test. Base URL SSO là http://127.0.0.1:8081 cộng idp_sso_url từ settings; production connection bắt buộc HTTPS.

Tạo SAML instance per connection, không dùng một singleton thay cert theo request. issuer ở đây là SP entity ID; idpIssuer là IdP entity ID. Dùng certificate đã pin, không tin certificate nhúng trong assertion:

```ts
import {SAML,ValidateInResponseTo} from "@node-saml/node-saml";
import {readFileSync} from "node:fs";
const acs="https://iam.local.test:8443/federation/saml/acme/acs";
const saml=new SAML({
  issuer:"https://iam.local.test:8443/federation/saml/acme/metadata",
  callbackUrl:acs,
  entryPoint:"http://127.0.0.1:8081/sso/module.php/saml/idp/singleSignOnService",
  idpIssuer:"urn:iam:test:acme",
  idpCert:readFileSync("lab/.secrets/acme-idp-cert.pem","utf8"),
  wantAssertionsSigned:true,wantAuthnResponseSigned:true,
  validateInResponseTo:ValidateInResponseTo.always,requestIdExpirationPeriodMs:300000,
  acceptedClockSkewMs:30000,maxAssertionAgeMs:300000,
  rejectReplayedAssertions:true,
  forceAuthn:true,
  signatureAlgorithm:"sha256",digestAlgorithm:"sha256",
  identifierFormat:"urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
  cacheProvider:postgresSamlCache
});
```

Tạo cache.ts và gán postgresSamlCache=createSamlCache(connection.id). Phiên bản 5.2.0 yêu cầu saveIfAbsentAsync khi bật rejectReplayedAssertions; consumeAsync làm request-ID consumption atomic. Không dùng in-memory cache ở multi-replica:

```ts
import type {CacheProvider} from "@node-saml/node-saml";
import {pool} from "../db.js";
export function createSamlCache(connectionId:string):CacheProvider {
  async function remove(key:string|null) {
    if (key===null) return null;
    const r=await pool.query<{value:string}>(
      "DELETE FROM federation_saml_cache WHERE connection_id=$1 AND key=$2" +
      " AND expires_at>clock_timestamp() RETURNING value",[connectionId,key]
    );
    return r.rows[0]?.value??null;
  }
  return {
    async saveAsync(key,value) {
      const createdAt=Date.now();
      const r=await pool.query(
        "INSERT INTO federation_saml_cache(connection_id,key,value,created_at,expires_at)" +
        " VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING RETURNING key",
        [connectionId,key,value,new Date(createdAt),new Date(createdAt+300000)]
      );
      return r.rowCount===1 ? {value,createdAt} : null;
    },
    async getAsync(key) {
      const r=await pool.query<{value:string}>(
        "SELECT value FROM federation_saml_cache WHERE connection_id=$1 AND key=$2" +
        " AND expires_at>clock_timestamp()",[connectionId,key]
      );
      return r.rows[0]?.value??null;
    },
    removeAsync:remove,consumeAsync:remove,
    async saveIfAbsentAsync(key,value,expiresAtMs) {
      const r=await pool.query(
        "INSERT INTO federation_saml_cache(connection_id,key,value,expires_at)" +
        " VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING RETURNING key",
        [connectionId,key,value,new Date(expiresAtMs)]
      );
      return r.rowCount===1;
    }
  };
}
```

Cleanup xoá expired cache rows; không overwrite một unexpired assertion marker. Application transaction replay guard bên dưới vẫn cần để ràng buộc browser/interaction, ngay cả khi library chống duplicate assertion.

SP-initiated start tạo transaction state/browser binding giống OIDC, gọi saml.getAuthorizeUrlAsync(state,{}) rồi redirect. Metadata endpoint trả saml.generateServiceProviderMetadata(null,null), content type application/samlmetadata+xml. Nếu ký AuthnRequest, thêm privateKey/publicCert quản lý riêng và trao đổi public certificate với IdP; không tái dùng signing key OIDC. Fixture mặc định không bắt signed request; response/assertion luôn cần signature.

## 14.5. ACS: kiểm tra XML và ràng buộc người nhận

Route ACS dùng express.urlencoded({extended:false,limit:"128kb",parameterLimit:4}); chỉ nhận một SAMLResponse và RelayState kiểu string, không arrays. Base64 decode có giới hạn, reject DOCTYPE/ENTITY, parser errors, nhiều Response/Assertion, encrypted assertions chưa hỗ trợ trong profile này. Không tự viết XML signature verifier.

Phiên bản thư viện phải được kiểm tra bằng negative tests, không giả mọi security check đều bật theo mặc định. Với 5.2.0, bổ sung kiểm tra Recipient/Destination ứng dụng vì tài liệu phiên bản ghi enforcement của chúng thay đổi ở major tiếp theo. Dùng namespace, không regex XML:

```ts
import {DOMParser} from "@xmldom/xmldom";
function xmlDocument(xml:string) {
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) throw new Error("xml_dtd_forbidden");
  return new DOMParser({
    onError:() => {throw new Error("invalid_xml");}
  }).parseFromString(xml,"text/xml");
}
const raw=Buffer.from(req.body.SAMLResponse,"base64").toString("utf8");
const outer=xmlDocument(raw);
const protocol="urn:oasis:names:tc:SAML:2.0:protocol";
const assertionNs="urn:oasis:names:tc:SAML:2.0:assertion";
if (outer.documentElement.localName!=="Response" ||
    outer.documentElement.namespaceURI!==protocol ||
    outer.getElementsByTagNameNS(protocol,"Response").length!==1 ||
    outer.getElementsByTagNameNS(assertionNs,"Assertion").length!==1) throw new Error("invalid_saml_shape");
const ds="http://www.w3.org/2000/09/xmldsig#";
const methods=outer.getElementsByTagNameNS(ds,"SignatureMethod");
const digests=outer.getElementsByTagNameNS(ds,"DigestMethod");
if (methods.length!==2 || digests.length!==2) throw new Error("signature_profile_mismatch");
for (let i=0;i<methods.length;i++)
  if (methods.item(i)?.getAttribute("Algorithm")!=="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256")
    throw new Error("signature_algorithm_forbidden");
for (let i=0;i<digests.length;i++)
  if (digests.item(i)?.getAttribute("Algorithm")!=="http://www.w3.org/2001/04/xmlenc#sha256")
    throw new Error("digest_algorithm_forbidden");
const verified=await saml.validatePostResponseAsync({SAMLResponse:req.body.SAMLResponse});
if (!verified.profile || verified.loggedOut) throw new Error("unexpected_saml_message");
const profile=verified.profile;
// Cấu hình yêu cầu signed Response và signed Assertion; dữ liệu user chỉ đọc từ verified profile.
if (outer.documentElement.getAttribute("Destination")!==acs) throw new Error("wrong_destination");
if (typeof profile.getAssertionXml!=="function") throw new Error("missing_verified_assertion");
const trusted=xmlDocument(profile.getAssertionXml());
const confirmations=trusted.getElementsByTagNameNS(assertionNs,"SubjectConfirmationData");
if (confirmations.length!==1 || confirmations.item(0)?.getAttribute("Recipient")!==acs)
  throw new Error("wrong_recipient");
if (typeof profile.nameID!=="string" || !profile.nameID ||
    profile.nameIDFormat!=="urn:oasis:names:tc:SAML:2.0:nameid-format:persistent")
  throw new Error("unstable_subject");
const assertionId=trusted.documentElement.getAttribute("ID");
if (!assertionId) throw new Error("missing_assertion_id");
const statements=trusted.getElementsByTagNameNS(assertionNs,"AuthnStatement");
const instant=statements.item(0)?.getAttribute("AuthnInstant");
const verifiedAuthAt=Date.parse(instant??"");
if (statements.length!==1 || !Number.isFinite(verifiedAuthAt) ||
    verifiedAuthAt>Date.now()+30000 || verifiedAuthAt<Date.now()-300000)
  throw new Error("upstream_authentication_too_old");
```

Không đọc một Assertion khác từ raw XML sau khi library verify xong. Cần test signature wrapping bằng duplicate IDs/elements. Pin acceptable algorithms; reject SHA1 test fixtures và external references nếu library configuration/version không chứng minh được tính an toàn. Hai signed elements là profile cố ý nghiêm của lab; customer chỉ ký assertion cần một profile riêng được review, không tắt kiểm tra để hết lỗi.

## 14.6. Hoàn tất session chung cho cả hai protocols

Trong một Identity transaction: lock federation transaction, kiểm tra cookie hash/TTL/connection version; INSERT federation_replays cho SAML assertion ID; lookup linked_identities; JOIN users/organizations/memberships bảo đảm active và org đúng. Thiếu mapping trả account_not_linked, không tự tạo user theo email. Tạo cookie secret/session bằng helper security chương 05, lưu hash. Đánh dấu transaction consumed và ghi outbox login success cùng commit.

Đây là session-completion module dùng cho cả hai callbacks; function chỉ nhận dữ kiện đã được protocol validator xác minh, không export thành public JSON endpoint:

```ts
import {withTransaction} from "../db.js";
import {hashToken,newOpaqueToken} from "../security.js";
export async function completeFederation(input:{
  state:string;browserCookie:string;connectionId:string;subject:string;
  authenticatedAt:Date;assertionId?:string;
}) {
  return withTransaction(async db=>{
    const t=await db.query(
      "SELECT t.*,c.org_id,c.issuer,c.enabled,c.version AS current_version" +
      " FROM federation_transactions t JOIN federation_connections c ON c.id=t.connection_id" +
      " WHERE t.state_hash=$1 FOR UPDATE OF t",[hashToken(input.state)]
    );
    const row=t.rows[0];
    if (!row || row.connection_id!==input.connectionId || !row.enabled ||
        row.consumed_at || new Date(row.expires_at)<=new Date() ||
        String(row.connection_version)!==String(row.current_version) ||
        !row.browser_hash.equals(hashToken(input.browserCookie))) throw new Error("invalid_federation_state");
    const mapped=await db.query<{user_id:string}>(
      "SELECT l.user_id FROM linked_identities l JOIN users u ON u.id=l.user_id" +
      " JOIN memberships m ON m.user_id=l.user_id AND m.org_id=$3" +
      " JOIN organizations o ON o.id=m.org_id" +
      " WHERE l.connection_id=$1 AND l.upstream_subject=$2 AND u.status='active'" +
      " AND m.status='active' AND o.status='active'",
      [input.connectionId,input.subject,row.org_id]
    );
    const user=mapped.rows[0]?.user_id;
    if (!user) throw new Error("account_not_linked");
    if (input.assertionId) await db.query(
      "INSERT INTO federation_replays(connection_id,assertion_id,expires_at)" +
      " VALUES($1,$2,clock_timestamp()+interval '10 minutes')",
      [input.connectionId,input.assertionId]
    );
    const cookie=newOpaqueToken();
    const s=await db.query<{id:string}>(
      "INSERT INTO sessions(user_id,cookie_hash,authenticated_at,amr,acr,upstream_issuer,expires_at)" +
      " VALUES($1,$2,$3,'{federated}','urn:iam:aal:1',$4,clock_timestamp()+interval '12 hours') RETURNING id",
      [user,hashToken(cookie),input.authenticatedAt,row.issuer]
    );
    await db.query("UPDATE federation_transactions SET consumed_at=clock_timestamp() WHERE state_hash=$1",
      [hashToken(input.state)]);
    // Login audit event insert dùng cùng outbox mapper/contract chương12.
    return {cookie,sessionId:s.rows[0]!.id,orgId:row.org_id};
  });
}
```

Set __Host-iam-session qua serialize sau commit, xoá __Host-fed và redirect cố định /oauth2/consent của chương 06. Original interaction cookie vẫn ràng buộc client/redirect/PKCE; callback không nhận returnTo tuỳ ý. Consent/liveUser tiếp tục kiểm tra app assignment, membership và org authentication policy trước cấp code. Session lưu upstream_issuer, amr hợp lệ và authentication evidence; không tự gắn mfa vì SAML attribute roles chứa chữ admin. Dùng upstream auth_time/AuthnInstant đã kiểm chứng, không đặt “vừa MFA” theo thời điểm callback nhận response.

Connection disabled hoặc certificate changed phải chặn refresh/introspection theo login policy hiện hành, không chỉ chặn start mới. Rotation cert hỗ trợ overlap có expiry và kiểm thử old/new; không fetch metadata rồi tin key mới tự động mà không trust policy.

Để biến yêu cầu này thành code, thêm session binding và một local policy predicate trong Identity migration. Khi tạo session federation, ghi upstream_connection_id bằng connection ID đã verify. Organization security_policy có required_connection_id (optional), require_mfa (boolean) và max_mfa_age_seconds (optional, admin validator giới hạn); không lấy policy từ browser:

```sql
ALTER TABLE sessions ADD COLUMN upstream_connection_id uuid REFERENCES federation_connections(id);
CREATE FUNCTION current_authn_policy_ok(p_session uuid,p_org uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
 SELECT COALESCE((
  SELECT
    (s.upstream_connection_id IS NULL OR fc.enabled IS TRUE)
    AND (o.security_policy->>'required_connection_id' IS NULL OR
      o.security_policy->>'required_connection_id'=s.upstream_connection_id::text)
    AND (COALESCE((o.security_policy->>'require_mfa')::boolean,false)=false OR
      (s.amr @> ARRAY['mfa']::text[] AND s.mfa_at IS NOT NULL))
    AND (o.security_policy->>'max_mfa_age_seconds' IS NULL OR
      s.mfa_at>=statement_timestamp()-
        make_interval(secs=>(o.security_policy->>'max_mfa_age_seconds')::integer))
  FROM sessions s JOIN organizations o ON o.id=p_org
  LEFT JOIN federation_connections fc ON fc.id=s.upstream_connection_id
  WHERE s.id=p_session
 ),false);
$$;
```

Sửa INSERT sessions ở completeFederation để thêm upstream_connection_id. Thêm AND current_authn_policy_ok(g.session_id,g.org_id) vào nhánh user của inspectAccessToken chương08; thêm cùng predicate theo session/org vào liveUser chương06, được refresh sử dụng. Machine branch giữ policy riêng, không gọi human-session predicate. Chạy regression test local session khi required_connection_id set: inactive; federation session đúng connection: active; disable connection rồi request mới: inactive. Đây là local authentication policy, khác business resource Policy service nên không có dependency cycle.

## 14.7. Negative tests, failure lab và DoD

Chạy browser login Web A → Identity → mock IdP → ACS → consent → Web A; sau đó Web B SSO khi org policy cho phép. Expected có session và opaque token của platform; Invoice API không nhận raw SAMLResponse/upstream ID token.

Test OIDC: wrong issuer/aud/azp/nonce, replay state, đổi connection giữa callback, PKCE sai, token endpoint timeout, SSRF discovery URL, email trùng Bob nhưng sub khác. Test SAML: unsigned response/assertion, wrong cert/audience/recipient/destination, expired/future assertion, missing InResponseTo, unsolicited IdP-initiated response, replay assertion, XML wrapping, DTD/entity, array parameters. Không log full assertions trong report; dùng fixture IDs/reason codes.

Gửi hai callback đồng thời với cùng state/assertion: chỉ một session được tạo. Dừng Identity giữa verify upstream và transaction commit: retry không được tạo hai sessions; token/code có thể đã consumed upstream, user cần bắt đầu flow mới. Dừng upstream: login federation fail có kiểm soát, local accounts không được âm thầm bypass enterprise-only policy.

Troubleshooting theo thứ tự issuer/entity ID, exact ACS URL, pinned cert, signatures, clock, InResponseTo cache và browser binding cookie. Nếu ACS thiếu cookie, kiểm tra SameSite=None/Secure và HTTPS thật; không bỏ state để chữa. Nếu signature fail sau restart mock container, cert fixture đã đổi; pin/mount test cert và cập nhật connection có kiểm soát.

**DoD:** OIDC broker code/state binding hoạt động; SAML SP có real signed fixture; mapping bằng stable subject; no email auto-link; multi-replica replay storage; session completion atomic; negative/concurrency/outage tests; secrets/assertions được redact; connection policy áp vào refresh/introspection; source/version/digest được ghi evidence. Chưa claim certification chỉ từ một happy path.

### Definition of Done

- [ ] Browser đi hết upstream OIDC và SAML vào hai app mà không bypass consent/membership.
- [ ] Wrong issuer/audience/nonce, signature wrapping, wrong Recipient/Destination, replay và stale authentication bị chặn.
- [ ] Hai callbacks đồng thời chỉ tạo một session; connection disabled chặn introspection/refresh mới.
- [ ] Linking theo stable subject, không merge theo email; test Acme/Beta không ảnh hưởng lẫn nhau.
- [ ] Library/image versions, pinned certificates và sanitized evidence được ghi lại.

Nguồn: [OIDC Core](https://openid.net/specs/openid-connect-core-1_0.html), [OAuth Security BCP](https://www.rfc-editor.org/rfc/rfc9700), [SAML Web Browser SSO profile](https://docs.oasis-open.org/security/saml/v2.0/saml-profiles-2.0-os.pdf), [Node-SAML 5.2.0 documentation](https://github.com/node-saml/node-saml/tree/v5.2.0), [test IdP source](https://github.com/pfrest/mock-saml2-idp), [SimpleSAMLphp signature settings](https://simplesamlphp.org/docs/2.4/simplesamlphp-reference-idp-hosted.html).
