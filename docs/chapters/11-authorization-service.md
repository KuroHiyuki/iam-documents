# 11. Xây Authorization service và gắn quyền vào Invoice API

[Mục lục](../../README.md) · [Trước: chương 10](10-mfa-key-management.md) · [Tiếp: messaging và audit](12-messaging-audit.md)

**Điều kiện đầu vào:** bạn đã tự code Identity, hai web clients và opaque access-token introspection. Alice đăng nhập Acme, Bob có fixture riêng, Invoice API chạy cổng 3200. Đọc [implementation map](../reference/implementation-map.md), [authorization contract](../reference/authorization-contract.md) trước khi đặt tên endpoint. Repo này cung cấp giáo trình; những đường dẫn lab/ bên dưới là file **bạn tạo**, chưa có một server chạy sẵn.

## 11.1. Kết quả cần đạt và ranh giới

Cuối chương, Alice có quyền đọc invoice Acme, không tự nhiên có quyền approve; token Acme không dùng được cho invoice Beta. Thu hồi membership trong Identity hoặc role trong Authorization làm request kế tiếp bị chặn, kể cả Audit đang dừng. Không cache kết quả allow. Đây là một lựa chọn nhất quán mạnh ở đầu mỗi request, đổi lại Identity và PDP trở thành dependencies trực tuyến cần vận hành HA.

Identity trả lời “principal/session/membership này còn hoạt động không?”. Authorization trả lời “principal được phép làm action nào lên resource trong context này?”. Invoice API trả lời “invoice hiện thuộc ai, trạng thái gì và mutation có hợp lệ không?”. Không chuyển ownership invoice vào IAM. Gateway có thể kiểm tra trước, nhưng Invoice API vẫn kiểm tra bởi request có thể đi từ internal service hoặc một ingress khác.

Tạo các module bên trong lab/services/authorization/src: config, introspection, parse-decision, evaluate, server. Dùng một database authorization với credential riêng, không GRANT đọc database identity. Local có thể dùng chung PostgreSQL instance; isolation logic không đòi mỗi service phải có một VM ngay từ đầu.

```powershell
New-Item -ItemType Directory -Force lab/services/authorization/src | Out-Null
Copy-Item docs/reference/sql/authorization.sql lab/services/authorization/001-initial.sql
$env:PGPASSWORD = $env:AUTHZ_MIGRATION_PASSWORD
psql -h localhost -U authorization_migrator -d authorization -v ON_ERROR_STOP=1 -f lab/services/authorization/001-initial.sql
Remove-Item Env:PGPASSWORD
```

Các role/database được tạo ở chương nền tảng; thay tên credential tại một chỗ trong cấu hình nếu bạn đã chọn tên khác. Migration chứa fixture Alice ở Acme với InvoiceReader. Kết quả mong đợi là CREATE TABLE/INSERT/COMMIT, không phải một ảnh chụp output giả. Chạy lần hai phải đi qua migration runner/version table, không chạy lại SQL seed một cách mù quáng.

## 11.2. Xác thực service caller và subject độc lập

Invoice API cần service access token audience iam-policy-api, scope authz:check. Token này khác bearer token của Alice audience invoice-api. PDP kiểm chứng cả hai: caller không có quyền khai báo resource types tuỳ ý; subject không được thay bằng user_id trong JSON.

Trong lab/services/authorization/src/introspection.ts, viết helper sau. Không thêm Map cache vào helper. TLS CA của lab được Node tin qua NODE_EXTRA_CA_CERTS như chương local TLS; không dùng NODE_TLS_REJECT_UNAUTHORIZED=0.

```ts
export type LivePrincipal = {
  active: true; sub: string; org_id: string; client_id: string;
  scope: string; aud: string; sid?: string;
  groups: string[]; iat: number; exp: number;
  amr?: string[]; acr?: string; auth_time?: number; mfa_time?: number;
};

function setting(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error("Missing setting: " + name);
  return value;
}

export async function introspect(token: string): Promise<LivePrincipal | null> {
  const id = setting("INTROSPECTION_CLIENT_ID");
  const secret = setting("INTROSPECTION_CLIENT_SECRET");
  const basic = Buffer.from(
    encodeURIComponent(id) + ":" + encodeURIComponent(secret)
  ).toString("base64");
  const response = await fetch(
    "https://iam.local.test:8443/oauth2/introspect",
    {
      method: "POST",
      headers: {
        Authorization: "Basic " + basic,
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: new URLSearchParams({token}),
      signal: AbortSignal.timeout(1500),
      redirect: "error"
    }
  );
  if (!response.ok) throw new Error("introspection_dependency_failed");
  const data = await response.json() as Record<string, unknown>;
  if (data.active !== true) return null;
  if (
    typeof data.sub !== "string" || typeof data.org_id !== "string" ||
    typeof data.client_id !== "string" || typeof data.aud !== "string" ||
    typeof data.scope !== "string" || typeof data.exp !== "number" ||
    typeof data.iat !== "number" || !Array.isArray(data.groups) ||
    !data.groups.every(g => typeof g === "string")
  ) throw new Error("invalid_introspection_contract");
  if (data.amr !== undefined && (!Array.isArray(data.amr) || !data.amr.every(x=>typeof x==='string')))
    throw new Error("invalid_introspection_contract");
  if (data.auth_time !== undefined && typeof data.auth_time !== 'number')
    throw new Error("invalid_introspection_contract");
  if (data.exp * 1000 <= Date.now()) return null;
  return data as LivePrincipal;
}
```

Đăng ký confidential client iam-policy-api trong Identity, chỉ cho introspect audiences invoice-api và iam-policy-api. Credentials của client này được Identity kiểm tra trực tiếp; introspection không gọi PDP. Không tạo vòng phụ thuộc Identity → Authorization → Identity. Route quản trị Identity dùng local control-plane guard, kiểm tra scope, organization và membership sống.

Schema ActivePrincipal có thể được chuyển sang lab/packages/contracts sau khi cả hai service đã thống nhất. TypeScript cast không thay validation runtime; ở production dùng JSON Schema hoặc validator có test cho từng field, giới hạn chuỗi/token/body. Các lỗi fetch/timeout phải lên 503, không biến thành active=true hay coi group rỗng là dữ liệu đã xác thực.

## 11.3. Parser nhỏ nhưng đóng trust boundary

Trong parse-decision.ts, chỉ nhận action chính xác và resource attributes có kiểu. UUID validator ở đây kiểm tra định dạng phục vụ fixture; query parameterization mới chống SQL injection. Không dùng regex validator thay logic authorization.

```ts
export type DecisionInput = {
  subject_token: string; action: string;
  resource: {
    type: "invoice"; id: string; org_id: string;
    attributes: {owner_id: string; amount_cents: number; status: string};
  };
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const record = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

export function parseDecision(value: unknown): DecisionInput {
  if (!record(value) || !record(value.resource)) throw new Error("invalid_request");
  const r = value.resource;
  if (!record(r.attributes)) throw new Error("invalid_request");
  const a = r.attributes;
  if (
    typeof value.subject_token !== "string" || value.subject_token.length > 512 ||
    !["invoice.read", "invoice.approve"].includes(String(value.action)) ||
    r.type !== "invoice" || typeof r.id !== "string" || !uuid.test(r.id) ||
    typeof r.org_id !== "string" || !uuid.test(r.org_id) ||
    typeof a.owner_id !== "string" || !uuid.test(a.owner_id) ||
    !Number.isSafeInteger(a.amount_cents) || Number(a.amount_cents) < 0 ||
    typeof a.status !== "string" || !["pending","approved","paid"].includes(a.status)
  ) throw new Error("invalid_request");
  if (Object.keys(value).some(k => !["subject_token","action","resource"].includes(k)) ||
      Object.keys(r).some(k => !["type","id","org_id","attributes"].includes(k)) ||
      Object.keys(a).some(k => !["owner_id","amount_cents","status"].includes(k))) {
    throw new Error("invalid_request");
  }
  return value as DecisionInput;
}
```

Khi thêm resource type mới, đăng ký ownership, permissions và attributes schema bằng migration hoặc control-plane API được bảo vệ; không tự chấp nhận type bất kỳ từ browser. Sai schema trả 400, không lặng lẽ bỏ trường rồi allow.

## 11.4. Evaluator RBAC đọc một snapshot

Tạo evaluate.ts, dùng connection riêng từ Pool và release trong finally. REPEATABLE READ đảm bảo version, role và assignment cùng snapshot. Scope organization chỉ có ý nghĩa bên trong org đã xác minh; không có wildcard platform xuyên tenant.

```ts
import {Pool} from "pg";
import type {LivePrincipal} from "./introspection.js";
import type {DecisionInput} from "./parse-decision.js";

export const pool = new Pool({connectionString: process.env.AUTHORIZATION_DATABASE_URL});

export async function evaluate(subject: LivePrincipal, input: DecisionInput) {
  const c = await pool.connect();
  try {
    await c.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
    const version = await c.query<{version: string}>(
      "SELECT version::text FROM policy_versions WHERE org_id=$1",
      [input.resource.org_id]
    );
    if (version.rowCount !== 1) throw new Error("unknown_policy_organization");
    if (subject.org_id !== input.resource.org_id) {
      await c.query("COMMIT");
      return {allow:false, reason_code:"TENANT_BOUNDARY", policy_version:version.rows[0]!.version};
    }
    // Chương 13 thay block này bằng deny -> constraints -> conditional allow.
    const advanced = await c.query<{n: string}>(
      "SELECT (SELECT count(*) FROM policy_rules WHERE org_id=$1 AND enabled)" +
      " + (SELECT count(*) FROM policy_constraints WHERE org_id=$1 AND enabled) AS n",
      [subject.org_id]
    );
    if (advanced.rows[0]!.n !== "0") throw new Error("advanced_policy_not_implemented");
    if (!subject.scope.split(" ").includes(input.action)) {
      await c.query("COMMIT");
      return {allow:false,reason_code:"CONSTRAINT_FAILED",policy_version:version.rows[0]!.version};
    }
    const result = await c.query(
      "SELECT 1 FROM role_assignments a JOIN role_permissions p" +
      " ON p.org_id=a.org_id AND p.role_id=a.role_id" +
      " WHERE a.org_id=$1 AND a.status='active'" +
      " AND a.valid_from<=transaction_timestamp()" +
      " AND (a.valid_until IS NULL OR a.valid_until>transaction_timestamp())" +
      " AND p.permission_key=$2 AND a.resource_type=$3" +
      " AND (a.scope_type='organization' OR a.resource_id=$4)" +
      " AND ((a.subject_type='user' AND a.subject_id=$5)" +
      " OR (a.subject_type='group' AND a.subject_id=ANY($6::text[]))" +
      " OR (a.subject_type='client' AND a.subject_id=$7)) LIMIT 1",
      [subject.org_id,input.action,input.resource.type,input.resource.id,
       subject.sub.startsWith("client:") ? "" : subject.sub,subject.groups,
       subject.sub.startsWith("client:") ? subject.sub.slice(7) : ""]
    );
    await c.query("COMMIT");
    const allow = result.rowCount === 1;
    return {allow,reason_code:allow ? "RBAC_ALLOW" : "DEFAULT_DENY",
      policy_version:version.rows[0]!.version};
  } catch (e) {
    await c.query("ROLLBACK");
    throw e;
  } finally {c.release();}
}
```

Block advanced-policy deliberately fail closed để bạn không seed deny rồi vẫn chạy evaluator bỏ qua deny. Chương 13 thay block, không đặt evaluator RBAC trước deny. Nếu permission có nhiều roles thì chỉ cần một allow sau khi mọi guardrail đã qua.

Server route trong server.ts:

```ts
import express from "express";
import {randomUUID} from "node:crypto";
import {introspect} from "./introspection.js";
import {parseDecision} from "./parse-decision.js";
import {evaluate,pool} from "./evaluate.js";

const app = express();
app.use(express.json({limit:"16kb"}));
app.post("/v1/decisions", async (req,res) => {
  res.setHeader("Cache-Control","no-store");
  try {
    const match = /^Bearer ([A-Za-z0-9_-]+)$/.exec(req.get("authorization") ?? "");
    if (!match) {res.status(401).json({error:"invalid_token"}); return;}
    const caller = await introspect(match[1]!);
    if (!caller) {res.status(401).json({error:"invalid_token"}); return;}
    if (caller.aud !== "iam-policy-api" ||
        !caller.scope.split(" ").includes("authz:check")) {
      res.status(403).json({error:"caller_forbidden"}); return;
    }
    const input = parseDecision(req.body as unknown);
    const owner = await pool.query<{subject_audience:string}>(
      "SELECT subject_audience FROM resource_owners WHERE resource_type=$1 AND org_id=$2 AND client_id=$3",
      [input.resource.type,input.resource.org_id,caller.client_id]
    );
    if (owner.rowCount !== 1 || caller.org_id !== input.resource.org_id ||
        caller.sub !== "client:" + caller.client_id) {
      res.status(403).json({error:"resource_owner_required"}); return;
    }
    const subject = await introspect(input.subject_token);
    if (!subject) {res.status(401).json({error:"subject_inactive"}); return;}
    if (subject.aud !== owner.rows[0]!.subject_audience) {
      res.status(403).json({error:"subject_audience_mismatch"}); return;
    }
    const decision = await evaluate(subject,input);
    res.json({...decision,decision_id:randomUUID()});
  } catch (e) {
    const invalid = e instanceof Error && e.message === "invalid_request";
    res.status(invalid ? 400 : 503).json({error:invalid ? "invalid_request" : "dependency_unavailable"});
  }
});
app.listen(3300,"127.0.0.1");
```

Trong bài lab bind localhost; trên Kubernetes bind container interface và dùng NetworkPolicy/TLS. Thêm body-parser error middleware để malformed JSON trả 400 và body quá lớn trả 413. Không log subject_token khi ghi error. Log correlation/decision ID đủ để nối với audit ở chương sau.

## 11.5. Invoice API vừa là PEP vừa bảo vệ concurrency

Không cho browser POST trực tiếp attributes vào PDP. Invoice API lấy ID từ route, query invoice với org từ online introspection rồi tạo decision request từ row. Ví dụ route read gọi helper introspect tương tự nhưng credential invoice-api chỉ được introspect audience invoice-api. Helper getPolicyServiceToken thực hiện client_credentials theo chương token, dùng client invoice-api, yêu cầu audience iam-policy-api và scope authz:check; chỉ giữ token tới exp, không cache quyền của Alice.

Với approve, bắt đầu transaction Invoice DB, SELECT invoice FOR UPDATE, lấy attributes, gọi PDP với timeout rồi kiểm tra status pending và UPDATE. Không retry một approve vô điều kiện sau timeout. Nếu không muốn giữ lock qua network, đọc version trước, UPDATE WHERE version=$expected; khi conflict load lại và authorization lại. Chọn một cách và viết concurrency test. PDP allow không phải giấy phép vĩnh viễn cho một mutation sau hàng phút.

Response policy hợp lệ allow=false chuyển 403; subject inactive chuyển 401; dependency lỗi chuyển 503. Resource ngoài org có thể trả 404 để không lộ tồn tại. Đừng biến mọi lỗi thành 401 vì browser sẽ tạo vòng redirect login.

## 11.6. Chạy request và kiểm chứng

Lấy token Alice từ OAuth flow đã code ở các chương trước; không thêm password grant để tiện chạy lệnh. Gán token vào biến môi trường bằng clipboard/local console; không commit chúng.

```powershell
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("invoice-api:" + $env:INVOICE_CLIENT_SECRET))
$machine = Invoke-RestMethod https://iam.local.test:8443/oauth2/token -Method Post -Headers @{Authorization="Basic $basic"} -Body @{grant_type="client_credentials";scope="authz:check";audience="iam-policy-api"}
$request = @{
  subject_token=$env:ALICE_ACCESS_TOKEN
  action="invoice.read"
  resource=@{
    type="invoice";id="40000000-0000-4000-8000-000000000001"
    org_id="10000000-0000-4000-8000-000000000001"
    attributes=@{owner_id="00000000-0000-4000-8000-000000000001";amount_cents=150000;status="pending"}
  }
} | ConvertTo-Json -Depth 6
Invoke-RestMethod http://127.0.0.1:3300/v1/decisions -Method Post -Headers @{Authorization="Bearer $($machine.access_token)"} -ContentType application/json -Body $request
```

Expected với fixture reader: allow=true, reason_code=RBAC_ALLOW, policy_version=1; decision_id thay mỗi request. Đổi action sang invoice.approve phải deny: CONSTRAINT_FAILED nếu token chỉ được delegate read; khi fixture token có cả approve scope nhưng chỉ Reader role thì DEFAULT_DENY. Machine credential Acme khai resource Beta bị caller-forbidden. Muốn test TENANT_BOUNDARY, dùng machine credential Beta hợp lệ và subject token Acme như phần mở rộng dưới. Direct PDP request bằng token web-a phải bị caller forbidden, không phải một quyết định allow cho user.

Test tự động bằng node:test hoặc test runner đã chọn: revoke assignment rồi gọi lại; thu hồi group membership trong Identity rồi gọi lại; user suspended vẫn có token chưa hết hạn nhưng introspection inactive; scope substring authz:check-all không khớp authz:check. Fixture grant bằng migration chỉ dùng local. Tự tạo module grants.ts và Identity target verifier theo [owner implementation](../reference/authorization-contract.md#module-owner-hoàn-chỉnh-cho-grantrevoke); gọi chúng từ Governance, không expose SQL fixture như admin API không guard.

### B2B thật: service principal riêng cho Beta

Một machine client bind Acme không được khai Beta trong body token request. Thêm hai clients sau bằng migration Identity, dùng hash secrets ngẫu nhiên của chính máy bạn:

```sql
INSERT INTO clients(id,name,kind,secret_hash,grant_types,allowed_scopes,
  allowed_audiences,introspection_audiences,service_org_id)
VALUES
 ('invoice-api-beta','Invoice API Beta','confidential',decode(:'invoice_beta_hash','hex'),
  '{client_credentials}','{authz:check}','{iam-policy-api}','{invoice-api}',
  '10000000-0000-4000-8000-000000000002'),
 ('iam-policy-api-beta','Directory verifier Beta','confidential',decode(:'policy_beta_hash','hex'),
  '{client_credentials}','{directory:read}','{identity-internal-api}','{}',
  '10000000-0000-4000-8000-000000000002');
-- Mở rộng iam-policy-api Acme: allowed scope directory:read, audience identity-internal-api.
UPDATE clients SET allowed_scopes=array_append(allowed_scopes,'directory:read'),
  allowed_audiences=array_append(allowed_audiences,'identity-internal-api')
WHERE id='iam-policy-api';
```

Trong Authorization migration extension:

```sql
INSERT INTO resource_owners(resource_type,org_id,client_id,subject_audience)
VALUES('invoice','10000000-0000-4000-8000-000000000002','invoice-api-beta','invoice-api');
INSERT INTO roles(org_id,id,name)
VALUES('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000101','InvoiceReader');
INSERT INTO role_permissions(org_id,role_id,permission_key)
VALUES('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000101','invoice.read');
```

Sinh hai secrets bằng CSPRNG 32 byte như chương05; lưu INVOICE_BETA_CLIENT_SECRET và BETA_DIRECTORY_CLIENT_SECRET trong secret files. Tính SHA256 hex rồi truyền psql -v invoice_beta_hash=... -v policy_beta_hash=... cho migration; không đặt plaintext secret trong SQL. Root seed chỉ Acme, nên bước này là migration mở rộng cần chạy, không là client ngầm đã tồn tại.

Invoice API chọn credential từ map server-side sau introspection subject, ví dụ:

```ts
const serviceCredentials=new Map([
  ["10000000-0000-4000-8000-000000000001",
   {id:"invoice-api",secret:process.env.INVOICE_CLIENT_SECRET}],
  ["10000000-0000-4000-8000-000000000002",
   {id:"invoice-api-beta",secret:process.env.INVOICE_BETA_CLIENT_SECRET}]
]);
// live.org_id lấy từ introspection, không từ header/body.
const credentials=serviceCredentials.get(live.org_id);
if (!credentials?.secret) throw new Error("organization_not_configured");
// Dùng credentials với client_credentials audience iam-policy-api scope authz:check.
```

User audience vẫn invoice-api cho cả hai org; resource_owners lưu subject_audience riêng, không so audience user với machine client ID invoice-api-beta. PDP introspection credential có quyền inspect hai audiences invoice-api/iam-policy-api; target verifier khi cấp role chọn iam-policy-api-beta cho Beta theo map cấu hình. Kiểm thử Alice login lần lượt Acme/Beta, mỗi token chỉ thấy org của nó; machine Acme không dùng resource Beta; machine Beta + subject Acme trả TENANT_BOUNDARY. Bob/Beta không có Reader assignment vẫn deny. Thêm role bằng đúng owner command và chứng minh request kế tiếp mới allow.

## 11.7. Failure lab, xử lý lỗi và hoàn tất

Dừng Identity trong terminal riêng, gửi protected request mới: phải 503 trong timeout ngân sách, không chờ 30 giây và không dùng last allow. Khởi động lại, revoke role rồi dừng audit worker: request vẫn deny. Chạy hai approve đồng thời: chỉ một đổi pending→approved; request còn lại trả conflict theo nghiệp vụ. Một DB snapshot cũ không được tái sử dụng cho request sau.

Nếu mọi request deny, kiểm tra aud của hai loại token, client_id của machine token và resource owner registry trước khi sửa policy. Nếu groups rỗng, kiểm tra Identity query membership theo đúng org; đừng chữa bằng copy groups từ JWT/audit projection. Nếu policy_version chưa tăng sau grant, mutation route đang thiếu version transaction. Nếu PostgreSQL báo permission denied, sửa GRANT trong chính database Authorization, không cấp superuser.

### Troubleshooting

| Triệu chứng | Bằng chứng cần xem | Cách sửa |
|---|---|---|
| Mọi check trả caller forbidden | aud/scope/client_id của machine, resource_owners theo org | Cấp đúng principal và registry; không bỏ owner gate |
| Reader vẫn deny | Scope user, assignment expiry, org và live groups | Sửa đúng owner data; không thêm wildcard allow |
| Revoke không có hiệu lực | Primary query, cache metrics, transaction commit | Bỏ positive cache và stale replica path |
| Approve hai lần thành công | Invoice row version/lock và transaction evidence | Dùng FOR UPDATE hoặc compare-and-set, re-authorize khi conflict |

**Definition of Done:** policy DB credential riêng; live introspection cả caller/subject; tenant boundary trước allow; role fixture cho đúng một org; safe request parsing; online group/revoke tests; lỗi dependency fail closed; Invoice API lấy attrs từ database và chống TOCTOU; không log tokens; reader mô tả được request nào bắt đầu trước/sau revoke. Lưu test output, migration version và sơ đồ request flow trong learning journal của bạn.

Nguồn chính thức để đối chiếu: [RFC 7662 token introspection](https://www.rfc-editor.org/rfc/rfc7662), [PostgreSQL transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html), [OWASP authorization](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html), [AWS policy evaluation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html). Contract lab cố ý nhỏ hơn cloud và không claim tương thích evaluation semantics của AWS.
