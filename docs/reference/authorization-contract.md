# Contract phân quyền dùng chung

Đọc cùng [implementation map](implementation-map.md), [chương 11](../chapters/11-authorization-service.md) và [chương 13](../chapters/13-advanced-authorization.md). Đây là contract của bài lab, không phải API tương thích AWS, Azure hay Google.

## Nguồn sự thật và thứ tự quyết định

Identity sở hữu user, organization, membership, group membership, session, application assignment và opaque tokens. Authorization sở hữu policy hiện hành. Invoice API sở hữu invoice và thuộc tính invoice. Audit/event projections phục vụ lịch sử, tìm kiếm, reconciliation; **không dùng để xác nhận quyền hiện tại**.

Mọi protected request thực hiện online introspection và đọc live policy. Không positive cache introspection, memberships, groups hoặc quyết định allow. Không fallback allow khi Identity/PDP lỗi. PDP gọi Identity; Identity introspection xác thực confidential client trực tiếp trong Identity và không gọi lại PDP. Identity administration dùng local control-plane guard kiểm tra dữ liệu sống; tránh vòng Identity → Policy → Identity.

Thứ tự evaluator cố định: **tenant boundary → explicit deny → mandatory constraints → allow → default deny**. RBAC và ReBAC là các nguồn allow; chúng không vượt deny hoặc tenant boundary. Với condition malformed/unknown attribute, trả lỗi policy và fail closed; không biến condition của deny thành false để vô hiệu guardrail.

OAuth scope giới hạn quyền delegated: action phải có trong subject.scope bằng so sánh token space-delimited chính xác. Scope không tự tạo allow; vẫn cần role/conditional policy/relation sau constraints. Rule allow không được mở rộng scope đã consent. Khi cần scope tổng quát khác tên action, thêm mapping rõ ràng và test, không bỏ guard.

## Request

`POST http://127.0.0.1:3300/v1/decisions`, chỉ qua internal network/TLS khi ra khỏi localhost. Header `Authorization: Bearer <service-access-token>` là token của `invoice-api`, audience `iam-policy-api`, scope `authz:check`. Body tối đa 16 KiB:

```json
{
  "subject_token": "opaque-access-token-cua-user",
  "action": "invoice.read",
  "resource": {
    "type": "invoice",
    "id": "40000000-0000-4000-8000-000000000001",
    "org_id": "10000000-0000-4000-8000-000000000001",
    "attributes": {
      "owner_id": "00000000-0000-4000-8000-000000000001",
      "amount_cents": 150000,
      "status": "pending"
    }
  }
}
```

`subject_token` lấy từ bearer header request gốc. Không nhận `sub`, `groups`, `amr` do client tự khai thay token. PDP introspect service token và subject token bằng confidential credential `iam-policy-api`. Response introspection đang active có `sub`, `org_id`, `client_id`, `scope` chuỗi cách nhau bằng space, `aud` chuỗi, `sid`, `groups` UUID[], `iat`, `exp`; machine subject dùng `client:invoice-api`. Identity trả groups hiện hành thuộc organization của token. Với ABAC cần `amr`, `auth_time` hoặc attributes khác, mở rộng chính introspection contract và truy vấn live owner; không lấy từ audit projections.

PDP kiểm tra caller có `authz:check`, `aud=iam-policy-api`, `sub=client:<client_id>` và org khớp resource. `resource_owners(resource_type,org_id,client_id,subject_audience)` là allowlist sống: Acme dùng invoice-api, Beta dùng invoice-api-beta; cả hai có subject_audience invoice-api. Subject token có audience theo registry và org trùng resource. Không hardcode subject audience bằng caller client ID vì chúng khác nhau khi thêm principal per tenant. Caller khác không được giả làm owner invoice. Header `X-User-Id`, tenant hint và JSON từ browser không tạo authority.

## Response và lỗi

```json
{
  "allow": false,
  "reason_code": "DEFAULT_DENY",
  "policy_version": "7",
  "decision_id": "50000000-0000-4000-8000-000000000001"
}
```

Quyết định allow/deny hợp lệ trả HTTP 200. Các reason ổn định: `TENANT_BOUNDARY`, `EXPLICIT_DENY`, `CONSTRAINT_FAILED`, `RBAC_ALLOW`, `ABAC_ALLOW`, `RELATION_ALLOW`, `DEFAULT_DENY`. `policy_version` là chuỗi bigint để không mất precision JavaScript. Không trả danh sách membership/role nhạy cảm cho caller không cần biết.

| Tình huống | PDP HTTP | Resource API xử lý |
|---|---|---|
| Caller thiếu token/inactive | 401 | 503 nếu credential nội bộ hỏng; không báo user login lại vô hạn |
| Caller không sở hữu type/scope | 403 | 503 và cảnh báo cấu hình/security |
| Subject inactive | 401 với `subject_inactive` | 401 cho user |
| Schema/action không hợp lệ | 400 | 400 nếu request nghiệp vụ sai; 500 nếu mapping service sai |
| Quyết định deny hợp lệ | 200, `allow:false` | 403 hoặc 404 theo quy tắc chống resource enumeration |
| Identity/DB/PDP timeout | 503 | 503, không thay bằng allow hoặc stale cache |

Decision linearizes ở snapshot policy đọc sau introspection; một mutation đã bắt đầu trước khi revoke commit có thể đang chạy. Không hứa huỷ một transaction nghiệp vụ đã commit. Request mới sau revoke commit phải đọc trạng thái mới. Với thay đổi resource attributes giữa check và write, owning service dùng row lock hoặc compare-and-set trên version và kiểm tra lại khi conflict.

## Policy administration

`POST /internal/v1/grants` nhận `{operation_id,org_id,subject_type,subject_id,role_id,scope:{type,resource_type,resource_id?},valid_until}`; scope.type là organization hoặc resource. Response có `id`, `revision` dạng chuỗi. `DELETE /internal/v1/grants/:id` nhận `{operation_id,expected_revision}` trong JSON body. Caller Governance phải có live service token scope `authz:grant`, được đăng ký cho org; workflow approval không tự cấp scope này cho browser. Ghi role assignment, tăng `policy_versions`, lưu idempotency result và outbox trong cùng transaction. Cùng operation ID/body trả cùng kết quả; cùng ID/body khác trả 409. Revoke tăng revision, đặt status=revoked và revoked_at cùng transaction; sai expected_revision trả 409 để access review không thu hồi nhầm assignment đã thay đổi.

Writer khoá `policy_versions` theo organization. PDP dùng `REPEATABLE READ READ ONLY` để role, assignments, rules và version cùng một snapshot. Bảng không có FK sang Identity; trước cấp quyền writer online xác minh target membership bằng Identity internal API. Không dùng role name làm khóa, không cho tenant admin cấp platform role.

## Kiểm chứng tối thiểu

Test toàn bộ ma trận user × organization × resource × action; stop Identity, stop PDP, revoke group trong Identity, revoke role trong Policy. Mỗi lần quyền bị thu hồi phải ảnh hưởng request kế tiếp mà không chờ event delivery. Thử caller web-a tự gọi PDP, resource attributes giả, action lạ, assignment tenant A dùng role tenant B, policy JSON sai và concurrency đổi version trong lúc check.

## Module owner hoàn chỉnh cho grant/revoke

Đặt module sau tại lab/services/authorization/src/grants.ts. Import introspect/evaluate pool từ chương 11; canonicalJson là implementation chương 12, chép vào src/json.ts trước khi dùng. Khai báo Router qua app.use(grantsRouter). Route dùng express.json 16 KiB của server; invalid JSON được error middleware xử lý. HttpError được catch trong module, không log body chứa token.

```ts
import {Router} from "express";
import {createHash,randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {pool} from "./evaluate.js";
import {introspect,type LivePrincipal} from "./introspection.js";
import {canonicalJson} from "./json.js";

class HttpError extends Error {
  constructor(readonly status:number,message:string){super(message);}
}
type Grant={
  operation_id:string;org_id:string;subject_type:"user"|"group"|"client";
  subject_id:string;role_id:string;
  scope:{type:"organization"|"resource";resource_type:string;resource_id?:string};
  valid_until:string;
};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const obj=(v:unknown):v is Record<string,unknown> =>
  v!==null && typeof v==="object" && !Array.isArray(v);
function parseGrant(v:unknown):Grant {
  if (!obj(v) || !obj(v.scope)) throw new HttpError(400,"invalid_request");
  for (const key of ["operation_id","org_id","role_id"])
    if (typeof v[key]!=="string" || !uuid.test(v[key])) throw new HttpError(400,"invalid_request");
  if (!["user","group","client"].includes(String(v.subject_type)) ||
      typeof v.subject_id!=="string" || v.subject_id.length>128 ||
      !v.subject_id || !["organization","resource"].includes(String(v.scope.type)) ||
      typeof v.scope.resource_type!=="string" ||
      !/^[a-z][a-z0-9_-]{0,63}$/.test(v.scope.resource_type) ||
      (v.scope.type==="organization" && v.scope.resource_id!==undefined) ||
      (v.scope.type==="resource" && (typeof v.scope.resource_id!=="string" ||
        v.scope.resource_id.length<1 || v.scope.resource_id.length>128)) ||
      typeof v.valid_until!=="string" ||
      !Number.isFinite(Date.parse(v.valid_until))) throw new HttpError(400,"invalid_request");
  if (v.subject_type!=="client" && !uuid.test(v.subject_id)) throw new HttpError(400,"invalid_subject");
  if (Object.keys(v).some(k=>!["operation_id","org_id","subject_type","subject_id","role_id","scope","valid_until"].includes(k)) ||
      Object.keys(v.scope).some(k=>!["type","resource_type","resource_id"].includes(k)))
    throw new HttpError(400,"invalid_request");
  return v as Grant;
}
async function caller(raw:string|undefined):Promise<LivePrincipal> {
  const token=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(raw??"")?.[1];
  if (!token) throw new HttpError(401,"invalid_token");
  const p=await introspect(token);
  if (!p) throw new HttpError(401,"invalid_token");
  if (p.aud!=="iam-policy-api" || p.sub!=="client:"+p.client_id ||
      !p.scope.split(" ").includes("authz:grant")) throw new HttpError(403,"forbidden");
  return p;
}
async function targetActive(g:Grant):Promise<boolean> {
  const beta=g.org_id==="10000000-0000-4000-8000-000000000002";
  if (!beta && g.org_id!=="10000000-0000-4000-8000-000000000001")
    throw new HttpError(403,"organization_not_configured");
  const id=beta ? "iam-policy-api-beta" : "iam-policy-api";
  const secret=process.env[beta ? "BETA_DIRECTORY_CLIENT_SECRET" : "INTROSPECTION_CLIENT_SECRET"];
  if (!secret) throw new Error("directory_credential_missing");
  const basic=Buffer.from(encodeURIComponent(id)+":"+encodeURIComponent(secret)).toString("base64");
  const t=await fetch("https://iam.local.test:8443/oauth2/token",{
    method:"POST",redirect:"error",signal:AbortSignal.timeout(1500),
    headers:{Authorization:"Basic "+basic,"Content-Type":"application/x-www-form-urlencoded"},
    body:new URLSearchParams({
      grant_type:"client_credentials",audience:"identity-internal-api",scope:"directory:read"
    })
  });
  if (!t.ok) throw new Error("directory_token_failed");
  const issued=await t.json() as {access_token?:unknown};
  if (typeof issued.access_token!=="string") throw new Error("invalid_token_response");
  const path="/internal/v1/orgs/"+g.org_id+"/subjects/"+g.subject_type+"/"+encodeURIComponent(g.subject_id);
  const r=await fetch("https://iam.local.test:8443"+path,{
    redirect:"error",signal:AbortSignal.timeout(1500),
    headers:{Authorization:"Bearer "+issued.access_token}
  });
  if (r.status===404) return false;
  if (!r.ok) throw new Error("directory_dependency_failed");
  const result=await r.json() as {active?:unknown};
  if (typeof result.active!=="boolean") throw new Error("directory_contract_invalid");
  return result.active;
}
type Mutation={
  result:Record<string,unknown>;eventType:string;subjectId:string;targetId:string;roleId:string;
};
async function transaction(
  principal:LivePrincipal,operationId:string,payload:unknown,
  change:(c:PoolClient)=>Promise<Mutation>
) {
  const hash=createHash("sha256").update(canonicalJson(payload)).digest();
  const c=await pool.connect();
  try {
    await c.query("BEGIN");
    const lock=await c.query("SELECT version FROM policy_versions WHERE org_id=$1 FOR UPDATE",[principal.org_id]);
    if (lock.rowCount!==1) throw new HttpError(404,"organization_not_found");
    const old=await c.query<{request_hash:Buffer;response:Record<string,unknown>}>(
      "SELECT request_hash,response FROM operation_results WHERE org_id=$1 AND operation_id=$2",
      [principal.org_id,operationId]
    );
    if (old.rowCount===1) {
      if (!old.rows[0]!.request_hash.equals(hash)) throw new HttpError(409,"operation_payload_conflict");
      await c.query("COMMIT");return old.rows[0]!.response;
    }
    const mutation=await change(c);
    const v=await c.query<{version:string}>(
      "UPDATE policy_versions SET version=version+1 WHERE org_id=$1 RETURNING version::text",
      [principal.org_id]
    );
    await c.query(
      "INSERT INTO outbox(id,type,aggregate_id,aggregate_version,org_id,actor,correlation_id,data)" +
      " VALUES($1,$2,$3::text,$4,$3::uuid,$5,$6,$7)",
      [randomUUID(),mutation.eventType,principal.org_id,v.rows[0]!.version,
       {id:principal.sub},operationId,
       {subject_id:mutation.subjectId,action:mutation.eventType.endsWith("created")?"role.assign":"role.revoke",
        target:{type:"role-assignment",id:mutation.targetId},outcome:"success",
        role_id:mutation.roleId}]
    );
    await c.query(
      "INSERT INTO operation_results(org_id,operation_id,request_hash,response) VALUES($1,$2,$3,$4)",
      [principal.org_id,operationId,hash,mutation.result]
    );
    await c.query("COMMIT");return mutation.result;
  } catch(e){await c.query("ROLLBACK");throw e;} finally{c.release();}
}
export const grantsRouter=Router();
grantsRouter.post("/internal/v1/grants",async(req,res)=>{
  res.setHeader("Cache-Control","no-store");
  try {
    const p=await caller(req.get("authorization")),g=parseGrant(req.body as unknown);
    if (p.org_id!==g.org_id) throw new HttpError(403,"tenant_boundary");
    // Target check không giữ DB transaction; PDP vẫn kiểm membership sống ở mỗi request.
    // Receipt retry được resolve trước expiry/target checks ở transaction callback dưới.
    const result=await transaction(p,g.operation_id,{method:"create",body:g},async c=>{
      const ttl=Date.parse(g.valid_until)-Date.now();
      if (ttl<=0 || ttl>86400000) throw new HttpError(400,"invalid_expiry");
      // Để không giữ lock qua network, production chuyển targetActive trước transaction,
      // giữ receipt preflight và kiểm receipt lại sau lock. Lab giữ correctness với timeout nhỏ.
      if (!(await targetActive(g))) throw new HttpError(400,"inactive_subject");
      const role=await c.query(
        "SELECT 1 FROM roles WHERE org_id=$1 AND id=$2 AND NOT system_managed",
        [g.org_id,g.role_id]
      );
      if (role.rowCount!==1) throw new HttpError(403,"role_not_grantable");
      const id=randomUUID();
      await c.query(
        "INSERT INTO role_assignments(id,org_id,subject_type,subject_id,role_id,scope_type," +
        "resource_type,resource_id,valid_until,created_by,operation_id)" +
        " VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
        [id,g.org_id,g.subject_type,g.subject_id,g.role_id,g.scope.type,g.scope.resource_type,
         g.scope.resource_id??null,g.valid_until,p.sub,g.operation_id]
      );
      return {result:{id,revision:"1",org_id:g.org_id,valid_until:g.valid_until},
        eventType:"iam.role-assignment.created",subjectId:g.subject_id,targetId:id,roleId:g.role_id};
    });
    res.status(201).json(result);
  } catch(e) {
    res.status(e instanceof HttpError?e.status:503).json({error:e instanceof HttpError?e.message:"dependency_unavailable"});
  }
});
grantsRouter.delete("/internal/v1/grants/:id",async(req,res)=>{
  res.setHeader("Cache-Control","no-store");
  try {
    const p=await caller(req.get("authorization"));
    const b=req.body as unknown;
    if (!uuid.test(String(req.params.id)) || !obj(b) ||
        typeof b.operation_id!=="string" || !uuid.test(b.operation_id) ||
        typeof b.expected_revision!=="string" || !/^[1-9]\d*$/.test(b.expected_revision))
      throw new HttpError(400,"invalid_request");
    const result=await transaction(p,b.operation_id,
      {method:"revoke",id:req.params.id,expected_revision:b.expected_revision},async c=>{
      const r=await c.query(
        "SELECT * FROM role_assignments WHERE org_id=$1 AND id=$2 FOR UPDATE",
        [p.org_id,req.params.id]
      );
      const row=r.rows[0];
      if (!row) throw new HttpError(404,"not_found");
      if (String(row.revision)!==b.expected_revision || row.status!=="active")
        throw new HttpError(409,"assignment_changed");
      const changed=await c.query<{revision:string}>(
        "UPDATE role_assignments SET status='revoked',revoked_at=clock_timestamp()," +
        "revision=revision+1 WHERE org_id=$1 AND id=$2 RETURNING revision::text",
        [p.org_id,req.params.id]
      );
      return {result:{id:row.id,revision:changed.rows[0]!.revision,status:"revoked"},
        eventType:"iam.role-assignment.revoked",subjectId:row.subject_id,
        targetId:row.id,roleId:row.role_id};
    });
    res.json(result);
  } catch(e) {
    res.status(e instanceof HttpError?e.status:503).json({error:e instanceof HttpError?e.message:"dependency_unavailable"});
  }
});
```

Bound network call trong transaction của baseline có tradeoff lock latency; timeout 1.5 giây và writer concurrency limit là bắt buộc. Nâng cấp triển khai: receipt preflight → live target check ngoài transaction → lock/recheck receipt → mutation. Khi membership bị suspend ngay sau check, một assignment có thể vẫn được tạo nhưng không cấp effective access vì PDP/introspection đọc membership sống. Không claim atomicity xuyên Identity/Authorization.

Identity thêm route target verifier tại internal-subjects.ts, dùng helper inspectAccessToken đã được định nghĩa ở chương 08. Đây là local introspection và local control-plane policy, không gọi HTTP lại chính Identity:

```ts
import {Router} from "express";
import {pool} from "./db.js";
import {inspectAccessToken} from "./oauth/introspection.js";
export const internalSubjectsRouter=Router();
internalSubjectsRouter.get("/internal/v1/orgs/:orgId/subjects/:kind/:id",async(req,res)=>{
  res.setHeader("Cache-Control","no-store");
  try {
    const raw=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.get("authorization")??"")?.[1];
    if (!raw){res.status(401).json({error:"invalid_token"});return;}
    const caller=await inspectAccessToken(raw,["identity-internal-api"]);
    if (!caller.active){res.status(401).json({error:"invalid_token"});return;}
    if (caller.sub!=="client:"+caller.client_id ||
        caller.org_id!==req.params.orgId || !caller.scope.split(" ").includes("directory:read")){
      res.status(403).json({error:"forbidden"});return;
    }
    const id=String(req.params.id),org=String(req.params.orgId);
    let active=false;
    if (req.params.kind==="user") {
      const r=await pool.query("SELECT 1 FROM memberships m JOIN users u ON u.id=m.user_id" +
        " JOIN organizations o ON o.id=m.org_id WHERE m.org_id=$1 AND m.user_id=$2" +
        " AND m.status='active' AND u.status='active' AND o.status='active'",[org,id]);
      active=r.rowCount===1;
    } else if(req.params.kind==="group") {
      const r=await pool.query("SELECT 1 FROM groups g JOIN organizations o ON o.id=g.org_id" +
        " WHERE g.org_id=$1 AND g.id=$2 AND o.status='active'",[org,id]);
      active=r.rowCount===1;
    } else if(req.params.kind==="client") {
      const r=await pool.query("SELECT 1 FROM clients c JOIN organizations o ON o.id=c.service_org_id" +
        " WHERE c.service_org_id=$1 AND c.id=$2 AND c.status='active' AND o.status='active'",[org,id]);
      active=r.rowCount===1;
    } else {res.status(400).json({error:"invalid_subject_kind"});return;}
    res.json({active});
  } catch {res.status(503).json({error:"dependency_unavailable"});}
});
```

Thêm UUID/type/length validation trước SQL để malformed ID trả 400 thay 503; UUID validator của chương 11 dùng lại. Không đọc groups/users của org khác kể cả caller có directory:read. Live client registration trong inspectAccessToken kiểm tra allowed scopes/audiences hiện hành, nên thu hồi scope machine có hiệu lực ngay.
