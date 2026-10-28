import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import ts from 'typescript';
import YAML from 'yaml';

const root = path.resolve(import.meta.dirname, '..');
const failures = [];
const counts = {documents: 0, localLinks: 0, fences: 0, json: 0, yaml: 0, typescript: 0, powershell: 0};
async function walk(dir) {
  const result = [];
  for (const item of await readdir(dir, {withFileTypes: true})) {
    if (['node_modules', '.git', 'lab', '.validation'].includes(item.name)) continue;
    const full = path.join(dir, item.name);
    if (item.isDirectory()) result.push(...await walk(full));
    else if (item.name.endsWith('.md')) result.push(full);
  }
  return result;
}
function fail(file, line, message) { failures.push(`${path.relative(root, file)}:${line}: ${message}`); }
const documents = await walk(root);
const chapters = documents.filter(p => p.includes(`${path.sep}chapters${path.sep}`));
const chapterNumbers = chapters.map(p => Number(path.basename(p).slice(0,2))).sort((a,b)=>a-b);
if (JSON.stringify(chapterNumbers) !== JSON.stringify(Array.from({length:20},(_,i)=>i+1))) {
  failures.push('Expected exactly chapters 01–20 with unique numbers');
}
for (const file of documents) {
  counts.documents++;
  const raw = await readFile(file, 'utf8');
  if (raw.includes('\uFFFD')) fail(file, 1, 'Unicode replacement character');
  const lines = raw.split(/\r?\n/);
  let fence = null;
  let outside = '';
  for (let i=0;i<lines.length;i++) {
    const line = lines[i];
    const marker = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
    if (marker && !fence) {
      fence = {marker:marker[2], language:marker[3].trim().split(/\s+/)[0]?.toLowerCase(), line:i+1, body:[]};
      counts.fences++;
    } else if (marker && fence && marker[2][0]===fence.marker[0] && marker[2].length>=fence.marker.length && !marker[3].trim()) {
      const body = fence.body.join('\n');
      try {
        if (fence.language==='json') { JSON.parse(body); counts.json++; }
        if (['yaml','yml'].includes(fence.language) && !body.includes('{{')) {
          const parsed = YAML.parseAllDocuments(body, {uniqueKeys:true});
          const errors = parsed.flatMap(document => document.errors);
          if (errors.length) throw new Error(errors.map(error => error.message).join('; '));
          counts.yaml++;
        }
        if (['ts','typescript'].includes(fence.language)) {
          const src = ts.createSourceFile('snippet.ts', body, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
          for (const diagnostic of src.parseDiagnostics) {
            const pos = src.getLineAndCharacterOfPosition(diagnostic.start ?? 0);
            fail(file, fence.line+1+pos.line, `TypeScript syntax: ${ts.flattenDiagnosticMessageText(diagnostic.messageText,' ')}`);
          }
          counts.typescript++;
        }
        if (['powershell','ps1'].includes(fence.language)) counts.powershell++;
      } catch (error) { fail(file, fence.line, `${fence.language} parse: ${error.message}`); }
      fence=null;
    } else if (fence) fence.body.push(line);
    else outside += `${line}\n`;
  }
  if (fence) fail(file, fence.line, 'Unclosed code fence');
  const links = [...outside.matchAll(/\[[^\]]*\]\((<[^>]+>|[^)\s]+)(?:\s+"[^"]*")?\)/g)];
  for (const match of links) {
    let href = match[1].replace(/^<|>$/g,'');
    if (/^(?:https?:|mailto:|data:|#)/i.test(href)) continue;
    href = decodeURIComponent(href.split('#')[0]);
    if (!href) continue;
    counts.localLinks++;
    const target = path.resolve(path.dirname(file), href);
    if (target!==root && !target.startsWith(root+path.sep)) { fail(file,1,`Link escapes curriculum: ${href}`); continue; }
    try { await stat(target); } catch { fail(file,1,`Missing local link: ${href}`); }
  }
  if (file.includes(`${path.sep}chapters${path.sep}`)) {
    const sections = [
      ['entry/prerequisites', /điều kiện|prerequisite|đầu vào/i],
      ['commands/code', /(?:```|~~~)(?:powershell|ps1|typescript|ts|sql|javascript|bash|yaml|json|text)/],
      ['failure exercise', /failure|sự cố|lỗi có chủ đích|thực hành lỗi/i],
      ['troubleshooting', /troubleshooting|khắc phục|chẩn đoán/i],
      ['completion criteria', /definition of done|nghiệm thu|hoàn thành|checkpoint/i],
      ['sources', /https:\/\//]
    ];
    for (const [label, pattern] of sections) if (!pattern.test(raw)) fail(file,1,`Missing chapter element: ${label}`);
  }
}
console.log(JSON.stringify({node:process.version,counts, failures},null,2));
process.exitCode = failures.length ? 1 : 0;
