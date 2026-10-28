# Event envelope, outbox và audit

Đọc [chương 12](../chapters/12-messaging-audit.md). Đây là transport contract của lab; JSON Schema/TypeScript types đặt trong `lab/packages/contracts` khi bạn tự code. Không gọi event bus là nguồn xác nhận quyền hiện tại.

## Envelope v1

```json
{
  "id": "60000000-0000-4000-8000-000000000001",
  "source": "authorization",
  "type": "iam.role-assignment.created",
  "schema_version": 1,
  "occurred_at": "2026-10-28T08:00:00.000Z",
  "org_id": "10000000-0000-4000-8000-000000000001",
  "aggregate": {"type":"organization-policy","id":"10000000-0000-4000-8000-000000000001","version":"2"},
  "correlation_id": "60000000-0000-4000-8000-000000000002",
  "causation_id": null,
  "actor_id": "client:governance",
  "subject_id": "00000000-0000-4000-8000-000000000001",
  "action": "role.assign",
  "target": {"type":"role-assignment","id":"30000000-0000-4000-8000-000000000001"},
  "outcome": "success",
  "reason_code": null,
  "data": {"role_id":"20000000-0000-4000-8000-000000000001"}
}
```

UUIDs, timestamp RFC3339 UTC, version dạng decimal string. `org_id` null chỉ cho platform-wide event. `actor_id` do service xác thực tạo ra, không tin client body. `source` được bind với producer credential/broker ACL. Service không thể publish dưới tên nguồn khác. `data` có allowlist theo event type; giới hạn toàn envelope 32 KiB. Các producers phát schema mới theo additive-compatible change; thay semantics/required shape thì tăng `schema_version` và support hai version trong migration window.

| Event | Producer | Data tối thiểu |
|---|---|---|
| `iam.user.suspended` | identity | reason category, không ghi lý do tự do có PII |
| `iam.membership.status-changed` | identity | membership status, operation ID |
| `iam.session.revoked` | identity | session ID, revoke reason |
| `iam.role-assignment.created` / `.revoked` | authorization | role/assignment ID, expiry |
| `iam.policy.updated` | authorization | policy version, change category |
| `iam.federation.login-failed` | identity | connection ID, sanitized reason |
| `iam.provisioning.operation-completed` | governance | operation ID, target reference |

Events có thể hỗ trợ dashboard, email, audit, phát hiện bất thường và reconciliation. Không để event consumer duy trì `is_active` rồi dùng giá trị đó thay online introspection/live policy.

## Delivery và deduplication

Ghi event vào outbox cùng transaction nghiệp vụ. Publisher lease batch bằng `FOR UPDATE SKIP LOCKED`, publish với publisher confirm, chỉ đánh dấu `published_at` sau broker confirm. Crash sau publish/trước mark tạo duplicate hợp lệ. Consumer transaction ghi inbox và audit; chỉ ACK sau commit. Khoá dedup là `(source,event_id)`. Cùng khoá nhưng payload hash khác là lỗi integrity, đưa DLQ và cảnh báo; không bỏ qua im lặng.

Không phụ thuộc thứ tự toàn cục. `aggregate.version` chỉ giúp phát hiện gap/order trong cùng aggregate, không cấp quyền và không chứng minh đồng hồ đúng. Audit lưu cả `occurred_at` và `received_at`; event đến trễ vẫn lưu. Với projection cần thứ tự, buffer/gap retry hoặc đọc lại owner; audit thuần không cần sắp xếp lại trước khi append.

Retries dùng exponential backoff có jitter, cap 60 giây; sau 10 lần chuyển DLQ. Các con số này là defaults lab, không phải chuẩn bắt buộc. DLQ có metric, alarm, runbook và controlled replay. Publisher confirm chưa phải consumer commit; consumer ACK chưa phải “exactly once” toàn hệ thống. Thiết kế đạt at-least-once delivery cộng idempotent effects.

## Transport của bài lab

Chương 12 triển khai RabbitMQ ngay trên local: exchange durable riêng từng source, persistent publish với confirms/mandatory, durable quorum queue, manual ACK sau inbox+audit commit và DLQ. Publisher polling outbox 500 ms là default lab. Kubernetes giữ nguyên envelope/outbox/inbox và đổi topology HA phù hợp. Không nhúng broker message format vào domain service. Có thể thêm HTTP ingestion làm bài tập adapter sau này, nhưng nó không thay broker worker bắt buộc của chương 12.

Broker publishers có credentials/ACL riêng, chỉ write exchange của đúng service; consumer kiểm tra envelope.source khớp exchange đáng tin từ broker delivery. Không dùng bootstrap credential trong runtime. Nếu thêm HTTP ingestion sau này, mỗi publisher cần confidential client riêng scope audit:append/audience audit-api; protected HTTP endpoint vẫn online introspect và live-check quyền. Những clients mở rộng này không cần cho transport AMQP baseline.

## Bảo vệ dữ liệu và retention

Không ghi access/refresh token, authorization code, password/reset code, MFA seed, private key, client secret, cookie, SAMLResponse, ID token hoặc full upstream assertion. Hash token cũng không cần xuất audit. Không log raw request body trên token/introspection/federation endpoints. Lưu ID tham chiếu và reason code.

Audit runtime có INSERT/SELECT, không UPDATE/DELETE. DBA vẫn có khả năng sửa; cần WORM/object lock, ký manifest export và separation of duties nếu yêu cầu chống can thiệp. Không claim append-only SQL đã tạo compliance certification. Retention: lab 30 ngày; production phải chọn theo yêu cầu tổ chức và privacy, có maintenance role riêng và audit cho thao tác retention. Export luôn scope theo org từ principal, có TTL, không dùng URL dài hạn công khai.

Nguồn: [PostgreSQL locking](https://www.postgresql.org/docs/current/explicit-locking.html), [RabbitMQ confirms](https://www.rabbitmq.com/docs/confirms), [OWASP Logging](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html).

## Wire validator và mapper để copy vào contracts package

Tạo lab/packages/contracts/src/events.ts. Không dùng type assertion thay validator tại boundary. Đây là profile ban đầu; thêm event type cùng schema/tests vào manifest trước khi producer phát type mới. Trường hợp chưa support vào DLQ với reason schema, không silently discard.

~~~ts
export type EventV1={
  id:string;source:"identity"|"authorization"|"governance";type:string;
  schema_version:1;occurred_at:string;org_id:string|null;
  aggregate:{type:string;id:string;version:string};
  correlation_id:string;causation_id:string|null;actor_id:string;subject_id:string|null;
  action:string;target:{type:string;id:string};
  outcome:"success"|"denied"|"failure";reason_code:string|null;
  data:Record<string,unknown>;
};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const record=(v:unknown):v is Record<string,unknown> =>
  typeof v==="object" && v!==null && !Array.isArray(v);
const text=(v:unknown,max=200):v is string =>
  typeof v==="string" && v.length>0 && v.length<=max;
const fields=new Map<string,string[]>([
  ["iam.user.suspended",["reason_category"]],
  ["iam.membership.status-changed",["status","operation_id"]],
  ["iam.session.revoked",["session_id","revoke_reason"]],
  ["iam.role-assignment.created",["role_id","valid_until"]],
  ["iam.role-assignment.revoked",["role_id"]],
  ["iam.policy.updated",["policy_version","change_category"]],
  ["iam.federation.login-failed",["connection_id","sanitized_reason"]],
  ["iam.provisioning.operation-completed",["operation_id","target_reference"]],
  ["iam.group-membership.changed",["group_id","user_id","operation_id"]]
]);
const envelopeKeys=new Set([
  "id","source","type","schema_version","occurred_at","org_id","aggregate",
  "correlation_id","causation_id","actor_id","subject_id","action","target",
  "outcome","reason_code","data"
]);
export function parseEvent(bytes:Buffer,exchange:string):EventV1 {
  if (bytes.length>32768) throw new Error("event_too_large");
  const e:unknown=JSON.parse(bytes.toString("utf8"));
  if (!record(e) || !text(e.id) || !uuid.test(e.id) ||
      !["identity","authorization","governance"].includes(String(e.source)) ||
      exchange!=="iam."+String(e.source)+".events" ||
      typeof e.type!=="string" || !fields.has(e.type) || e.schema_version!==1 ||
      !text(e.occurred_at) || !Number.isFinite(Date.parse(e.occurred_at)) ||
      !(e.org_id===null || (text(e.org_id) && uuid.test(e.org_id))) ||
      !text(e.correlation_id) || !uuid.test(e.correlation_id) ||
      !(e.causation_id===null || (text(e.causation_id) && uuid.test(e.causation_id))) ||
      !text(e.actor_id) || !(e.subject_id===null || text(e.subject_id)) ||
      !text(e.action) || !["success","denied","failure"].includes(String(e.outcome)) ||
      !(e.reason_code===null || text(e.reason_code)) ||
      !record(e.aggregate) || !text(e.aggregate.type) || !text(e.aggregate.id) ||
      !text(e.aggregate.version) || !/^[1-9]\d*$/.test(e.aggregate.version) ||
      !record(e.target) || !text(e.target.type) || !text(e.target.id) ||
      !record(e.data) || Object.keys(e).some(k=>!envelopeKeys.has(k)))
    throw new Error("event_schema_invalid");
  const allowed=fields.get(e.type)!;
  if (Object.keys(e.data).some(k=>!allowed.includes(k))) throw new Error("event_data_not_allowlisted");
  for (const [key,value] of Object.entries(e.data)) {
    if (!text(value,512)) throw new Error("event_data_invalid");
    if (key.endsWith("_id") && !uuid.test(value)) throw new Error("event_data_invalid");
  }
  if ((e.type==="iam.role-assignment.created" || e.type==="iam.role-assignment.revoked") &&
      (e.source!=="authorization" || !text(e.data.role_id) || !uuid.test(e.data.role_id) ||
       e.target.type!=="role-assignment")) throw new Error("event_role_schema_invalid");
  return e as EventV1;
}
export type OutboxRow={
  id:string;type:string;version:number;aggregate_id:string;aggregate_version:string;
  org_id:string|null;actor:{id:string};correlation_id:string;data:Record<string,unknown>;
  created_at:Date;
};
export function eventFromRow(row:OutboxRow,source:EventV1["source"]):EventV1 {
  const {subject_id,action,target,outcome,reason_code,causation_id,...details}=row.data;
  const event={
    id:row.id,source,type:row.type,schema_version:row.version,
    occurred_at:row.created_at.toISOString(),org_id:row.org_id,
    aggregate:{type:source==="authorization"?"organization-policy":source+"-aggregate",
      id:row.aggregate_id,version:String(row.aggregate_version)},
    correlation_id:row.correlation_id,causation_id:causation_id??null,
    actor_id:row.actor.id,subject_id:subject_id??null,action,target,outcome,
    reason_code:reason_code??null,data:details
  };
  return parseEvent(Buffer.from(JSON.stringify(event)),"iam."+source+".events");
}
~~~

Manifest không phải nơi suy ra actor/action từ tên event khi producer thiếu dữ liệu. Producer ghi outbox.data gồm action/target/outcome/subject_id và allowlisted details. Additive schema thay đổi cần adapter tương thích; nếu replay event cũ, mapper không được đổi action/target/occurred_at.

## Store và consumer hoàn chỉnh

Đặt canonicalJson từ chương12 vào contracts/src/json.ts rồi export qua package entry. Tạo lab/services/audit/src/store.ts; imports package @iam/contracts/events và @iam/contracts/json tương ứng exports bạn khai báo trong package.json:

~~~ts
import {Pool} from "pg";
import {createHash,randomUUID} from "node:crypto";
import type {EventV1} from "@iam/contracts/events";
import {canonicalJson} from "@iam/contracts/json";
const pool=new Pool({connectionString:process.env.AUDIT_DATABASE_URL});
export async function appendEvent(event:EventV1):Promise<void> {
  const hash=createHash("sha256").update(canonicalJson(event)).digest();
  const c=await pool.connect();
  try {
    await c.query("BEGIN");
    const inserted=await c.query(
      "INSERT INTO inbox(source,event_id,payload_hash) VALUES($1,$2,$3)" +
      " ON CONFLICT DO NOTHING RETURNING event_id",[event.source,event.id,hash]
    );
    if (inserted.rowCount===0) {
      const old=await c.query<{payload_hash:Buffer}>(
        "SELECT payload_hash FROM inbox WHERE source=$1 AND event_id=$2",[event.source,event.id]
      );
      if (!old.rows[0]?.payload_hash.equals(hash)) throw new Error("event_integrity_conflict");
    } else await c.query(
      "INSERT INTO audit_events(id,source,event_id,event_type,schema_version,occurred_at," +
      "org_id,actor_id,subject_id,action,target_type,target_id,outcome,reason_code," +
      "correlation_id,causation_id,aggregate_id,aggregate_version,details)" +
      " VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)",
      [randomUUID(),event.source,event.id,event.type,event.schema_version,event.occurred_at,
       event.org_id,event.actor_id,event.subject_id,event.action,event.target.type,event.target.id,
       event.outcome,event.reason_code,event.correlation_id,event.causation_id,
       event.aggregate.id,event.aggregate.version,event.data]
    );
    await c.query("COMMIT");
  } catch(error){await c.query("ROLLBACK");throw error;} finally{c.release();}
}
~~~

Tạo audit/src/consumer.ts; topology bootstrap phải chạy trước. Consumer không tự assert queue bằng bootstrap credential:

~~~ts
import amqp from "amqplib";
import type {ConsumeMessage} from "amqplib";
import {setTimeout as delay} from "node:timers/promises";
import {parseEvent} from "@iam/contracts/events";
import {appendEvent} from "./store.js";
const connection=await amqp.connect(process.env.AMQP_AUDIT_URL!);
const channel=await connection.createChannel();
connection.on("error",()=>{process.exitCode=1;});
channel.on("error",()=>{process.exitCode=1;});
await channel.prefetch(8);
async function processMessage(message:ConsumeMessage):Promise<void> {
  let event;
  try {event=parseEvent(message.content,message.fields.exchange);}
  catch {channel.nack(message,false,false);return;}
  try {
    await appendEvent(event);
    channel.ack(message);
  } catch(error) {
    if (error instanceof Error && error.message==="event_integrity_conflict") {
      channel.nack(message,false,false);return;
    }
    const delivery=Number(message.properties.headers?.["x-delivery-count"]??0);
    await delay(Math.min(5000,250*2**Math.min(delivery,4))+Math.random()*250);
    channel.nack(message,false,true);
  }
}
await channel.consume("iam.audit.events",message=>{
  if (message) void processMessage(message).catch(async()=>{
    // Channel đóng khi đang ACK/NACK: reconnect qua supervisor; broker redeliver unacked.
    await connection.close().catch(()=>undefined);
    process.exitCode=1;
  });
},{noAck:false});
~~~

Production dùng structured redacted logs/metrics ở các catch, restart policy và graceful shutdown; không process.exit trước khi drain đang làm transaction. Consumer không ghi token/body vào error logs. Kiểm tra DLQ chứa envelope đã allowlist hoặc apply access restriction/redaction khi triage raw malformed message.
