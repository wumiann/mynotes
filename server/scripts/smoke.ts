// API 冒烟测试：临时数据目录里启动一份真实的 server（dist/index.js），
// 以客户端视角（PBKDF2 派生 authKey + cookie 会话）走完 M1 + 分组/标签/设置/备份全流程。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = 8323;
const BASE = `http://127.0.0.1:${PORT}`;
const serverJs = fileURLToPath(new URL('../dist/index.js', import.meta.url));

if (!fs.existsSync(serverJs)) {
  console.error('未找到 server/dist/index.js，请先执行 pnpm --filter server build');
  process.exit(1);
}

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mynotes-smoke-'));
const child = spawn(process.execPath, [serverJs], {
  env: { ...process.env, PORT: String(PORT), DATA_DIR: dataDir },
  stdio: 'ignore',
});

let cookie = '';
let cookie2 = '';
let passed = 0;
let failed = 0;

function ok(name: string, cond: boolean, extra = ''): void {
  if (cond) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} ${extra}`);
  }
}

async function call(
  method: string,
  url: string,
  body?: unknown,
  opts?: { secondCookie?: boolean },
): Promise<{ status: number; json: any }> {
  const headers: Record<string, string> = {};
  const ck = opts?.secondCookie ? cookie2 : cookie;
  if (ck) headers.cookie = ck;
  let reqBody: BodyInit | undefined;
  if (body instanceof FormData) reqBody = body;
  else if (body !== undefined) {
    headers['content-type'] = 'application/json';
    reqBody = JSON.stringify(body);
  }
  const res = await fetch(BASE + url, { method, headers, body: reqBody });
  const setCookies = res.headers.getSetCookie?.() ?? [];
  for (const c of setCookies) {
    const kv = c.split(';')[0];
    if (kv.startsWith('sid=')) {
      if (opts?.secondCookie) cookie2 = kv;
      else cookie = kv;
    }
  }
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

async function pbkdf2(password: string, saltHex: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: Buffer.from(saltHex, 'hex'), iterations: 600000 },
    key,
    256,
  );
  return Buffer.from(bits).toString('hex');
}

// 模拟客户端的卡片加解密（AES-256-GCM，base64(iv+密文)，与 web/src/lib/crypto.ts 一致）
async function cardEncrypt(fields: unknown, password: string, saltHex: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: Buffer.from(saltHex, 'hex'), iterations: 600000 },
    key,
    256,
  );
  const aes = await crypto.subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    aes,
    new TextEncoder().encode(JSON.stringify(fields)),
  );
  return Buffer.concat([Buffer.from(iv), Buffer.from(ct)]).toString('base64');
}

async function cardDecrypt(payload: string, password: string, saltHex: string): Promise<any> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: Buffer.from(saltHex, 'hex'), iterations: 600000 },
    key,
    256,
  );
  const aes = await crypto.subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, ['decrypt']);
  const raw = Buffer.from(payload, 'base64');
  const pt = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: raw.subarray(0, 12) },
    aes,
    raw.subarray(12),
  );
  return JSON.parse(new TextDecoder().decode(pt));
}

async function waitServer(): Promise<void> {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`${BASE}/api/health`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('server 未能在 10 秒内启动');
}

const PASSWORD = 'correct-horse-battery';
const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

async function main(): Promise<void> {
  await waitServer();
  console.log('server 已启动，开始冒烟测试…\n');

  // --- 认证 ---
  let r = await call('GET', '/api/auth/status');
  ok('初始状态需要初始化', r.status === 200 && r.json.setupNeeded === true);

  const salt1 = '11'.repeat(16);
  const salt2 = '22'.repeat(16);
  const authKey = await pbkdf2(PASSWORD, salt1);
  r = await call('POST', '/api/auth/setup', {
    username: 'tester',
    authKey,
    kdfSalt1: salt1,
    kdfSalt2: salt2,
  });
  ok('初始化账号并建立会话', r.status === 200 && r.json.ok === true && cookie.includes('sid='));

  r = await call('GET', '/api/auth/salts?username=tester');
  ok('拉取派生盐', r.status === 200 && r.json.kdfSalt1 === salt1 && r.json.kdfSalt2 === salt2);

  r = await call('POST', '/api/auth/login', { username: 'tester', authKey: '0'.repeat(64) });
  ok('错误密钥被拒绝', r.status === 401);

  // --- 分组 ---
  r = await call('POST', '/api/groups', { name: '文案', parentId: null });
  ok('创建一级分组', r.status === 201 && r.json.group?.name === '文案');
  const rootGroupId = r.json.group?.id;

  r = await call('POST', '/api/groups', { name: '灵感', parentId: rootGroupId });
  ok('创建子分组', r.status === 201);
  const childGroupId = r.json.group?.id;

  r = await call('PUT', `/api/groups/${childGroupId}`, { name: '灵感', parentId: rootGroupId });
  ok('分组可作为父分组的子级（无变化更新）', r.status === 200);

  r = await call('PUT', `/api/groups/${rootGroupId}`, { name: '文案', parentId: childGroupId });
  ok('阻止循环父级', r.status === 400);

  r = await call('GET', '/api/groups');
  ok('分组列表带计数', r.status === 200 && r.json.groups?.length === 2);

  // --- 笔记 + 分组归属 ---
  const noteBody = (over: Record<string, unknown> = {}) => ({
    title: '你好世界',
    content: JSON.stringify({ type: 'doc', content: [{ type: 'paragraph' }] }),
    plainText: '这是一段保存的文案，用于搜索测试',
    tags: ['文案', '测试'],
    pinned: true,
    ...over,
  });
  r = await call('POST', '/api/notes', noteBody({ groupId: childGroupId }));
  ok('创建笔记并归入子分组', r.status === 201 && r.json.note.groupId === childGroupId);
  const noteId = r.json.note?.id;

  r = await call('POST', '/api/notes', noteBody({ title: '无分组笔记', pinned: false, groupId: null }));
  ok('创建未分组笔记', r.status === 201 && r.json.note.groupId === null);

  r = await call('GET', `/api/notes?group=${rootGroupId}`);
  ok('父分组过滤包含子分组笔记', r.json.notes?.length === 1 && r.json.notes[0].id === noteId);

  r = await call('GET', '/api/notes?group=none');
  ok('未分组过滤', r.json.notes?.length === 1 && r.json.notes[0].groupId === null);

  r = await call('POST', `/api/notes/${noteId}/move`, { groupId: null });
  ok('移动笔记到未分组', r.status === 200 && r.json.note.groupId === null);
  r = await call('POST', `/api/notes/${noteId}/move`, { groupId: rootGroupId });
  ok('移动笔记到分组', r.status === 200 && r.json.note.groupId === rootGroupId);

  // --- 搜索 / 版本 ---
  r = await call('GET', '/api/notes?q=搜索测试');
  ok('中文搜索命中', r.json.notes?.length === 2);
  r = await call('PUT', `/api/notes/${noteId}`, noteBody({ expectedVersion: 99, groupId: rootGroupId }));
  ok('版本冲突返回 409', r.status === 409);
  r = await call('PUT', `/api/notes/${noteId}`, noteBody({ title: '你好世界2', pinned: false, expectedVersion: 1, groupId: rootGroupId }));
  ok('正确版本可更新', r.status === 200 && r.json.note.version === 2);

  // --- 版本历史 ---
  await call('PUT', `/api/notes/${noteId}`, noteBody({ title: '你好世界3', pinned: false, expectedVersion: 2, groupId: rootGroupId }));
  r = await call('GET', `/api/notes/${noteId}/versions`);
  ok('更新产生历史版本', r.status === 200 && r.json.versions?.length === 2);
  ok('版本列表含元数据', typeof r.json.versions?.[0]?.version === 'number' && typeof r.json.versions?.[0]?.updatedAt === 'string');
  const oldest = r.json.versions?.[r.json.versions.length - 1];
  r = await call('GET', `/api/notes/${noteId}/versions/${oldest.version}`);
  ok('单个版本内容可查', r.status === 200 && r.json.version?.title === '你好世界');
  r = await call('POST', `/api/notes/${noteId}/restore-version`, { version: oldest.version });
  ok('恢复旧版本', r.status === 200 && r.json.note?.title === '你好世界');
  r = await call('GET', `/api/notes/${noteId}`);
  ok('恢复后内容为旧版且版本号递增', r.json.note?.plainText === '这是一段保存的文案，用于搜索测试' && r.json.note?.version === 4);
  r = await call('GET', `/api/notes/${noteId}/versions`);
  ok('恢复前当前内容已自动留档', r.json.versions?.some((v: any) => v.title === '你好世界3'));
  r = await call('GET', `/api/notes/${noteId}/versions/999`);
  ok('不存在的版本返回 404', r.status === 404);
  // 把标题改回，衔接后续测试流程
  r = await call('PUT', `/api/notes/${noteId}`, noteBody({ title: '你好世界2', pinned: false, expectedVersion: 4, groupId: rootGroupId }));
  ok('测试衔接更新', r.status === 200 && r.json.note.version === 5);

  // --- 附件 ---
  const fd = new FormData();
  fd.append('file', new Blob([PNG_1X1], { type: 'image/png' }), 'tiny.png');
  r = await call('POST', '/api/attachments', fd);
  ok('上传图片', r.status === 201 && r.json.url?.startsWith('/a/'));
  const img = await fetch(BASE + r.json.url, { headers: { cookie } });
  ok('读取图片', img.status === 200 && img.headers.get('content-type') === 'image/png');

  // --- 标签管理 ---
  r = await call('PUT', '/api/tags/' + encodeURIComponent('文案'), { name: '文案收藏' });
  ok('标签重命名', r.status === 200 && r.json.changed >= 2);
  r = await call('GET', '/api/notes?q=你好世界2');
  ok('笔记中的标签已更新', JSON.stringify(r.json.notes?.[0]?.tags).includes('文案收藏'));
  r = await call('DELETE', '/api/tags/' + encodeURIComponent('测试'));
  ok('删除标签', r.status === 200 && r.json.changed >= 1);

  // --- 设置 / 统计 ---
  r = await call('GET', '/api/settings');
  ok('读取默认设置', r.json.theme === 'auto' && r.json.trashCleanDays === 30);
  r = await call('PUT', '/api/settings', { theme: 'dark', trashCleanDays: 7 });
  ok('更新设置', r.status === 200 && r.json.settings.theme === 'dark' && r.json.settings.trashCleanDays === 7);
  r = await call('PUT', '/api/settings', { theme: 'pink' });
  ok('非法主题被拒绝', r.status === 400);
  r = await call('PUT', '/api/settings', { cardLock: 'ask' });
  ok('卡片解锁设置可更新', r.status === 200 && r.json.settings.cardLock === 'ask');
  r = await call('PUT', '/api/settings', { cardLock: 'always' });
  ok('非法卡片解锁设置被拒绝', r.status === 400);
  r = await call('PUT', '/api/settings', { cardLock: 'session' });
  ok('卡片解锁设置可恢复默认', r.status === 200 && r.json.settings.cardLock === 'session');

  r = await call('GET', '/api/stats');
  ok('统计接口', r.status === 200 && r.json.noteCount === 2 && r.json.groupCount === 2 && r.json.attachmentCount === 1);

  // --- 回收站 ---
  r = await call('DELETE', `/api/notes/${noteId}`);
  ok('删除进回收站', r.status === 200);
  r = await call('GET', '/api/notes?trash=1');
  ok('回收站可见', r.json.notes?.length === 1);
  r = await call('POST', `/api/notes/${noteId}/restore`);
  ok('恢复笔记', r.status === 200 && r.json.note.deletedAt === null);

  // --- 修改密码（含卡片重加密） ---
  // 先建一张用真实加密的卡片（旧密码派生密钥）
  const realCardFields = {
    name: '重加密测试卡',
    url: 'https://example.com',
    notes: '',
    credentials: [{ label: '主号', username: 'user-a', password: 'pass-a' }],
  };
  const realCipher = await cardEncrypt(realCardFields, PASSWORD, salt2);
  r = await call('POST', '/api/notes', {
    type: 'card',
    content: realCipher,
    tags: [],
    pinned: false,
  });
  const realCardId = r.json.note?.id as string;
  ok('创建真实加密卡片', r.status === 201 && !!realCardId);

  const wrongKey = await pbkdf2('wrong-password', salt1);
  r = await call('POST', '/api/auth/password', {
    oldAuthKey: wrongKey,
    newAuthKey: 'a'.repeat(64),
    newKdfSalt1: '33'.repeat(16),
    newKdfSalt2: '44'.repeat(16),
  });
  ok('原密码错误被拒绝', r.status === 401);

  const newSalt1 = '33'.repeat(16);
  const newSalt2 = '44'.repeat(16);
  const newAuthKey = await pbkdf2('new-strong-pass-9', newSalt1);
  const reCipher = await cardEncrypt(realCardFields, 'new-strong-pass-9', newSalt2);
  r = await call('POST', '/api/auth/password', {
    oldAuthKey: authKey,
    newAuthKey,
    newKdfSalt1: newSalt1,
    newKdfSalt2: newSalt2,
    cards: [{ id: realCardId, content: reCipher }],
  });
  ok('修改密码并重加密卡片', r.status === 200 && r.json.cardsUpdated === 1);

  r = await call('GET', '/api/auth/salts?username=tester');
  ok('派生盐已更新', r.json.kdfSalt1 === newSalt1 && r.json.kdfSalt2 === newSalt2);

  // 验证卡片密文确实被服务端覆写，且能用新密钥解开
  r = await call('GET', `/api/notes/${realCardId}`);
  const storedCipher = r.json.note?.content as string;
  ok('卡片密文已被替换', storedCipher !== realCipher);
  const decrypted = await cardDecrypt(storedCipher, 'new-strong-pass-9', newSalt2);
  ok(
    '新密钥可解密且内容一致',
    decrypted?.credentials?.[0]?.username === 'user-a' &&
      decrypted?.credentials?.[0]?.password === 'pass-a',
  );

  // 旧密码登录失败 / 新密码在第二个会话登录成功
  const oldKeyRetry = await pbkdf2(PASSWORD, newSalt1);
  r = await call('POST', '/api/auth/login', { username: 'tester', authKey: oldKeyRetry });
  ok('旧密码登录失败', r.status === 401);
  r = await call('POST', '/api/auth/login', { username: 'tester', authKey: newAuthKey }, { secondCookie: true });
  ok('新密码可登录（第二个会话）', r.status === 200 && cookie2.includes('sid='));

  // --- 登出其他设备 ---
  r = await call('POST', '/api/auth/logout-others');
  ok('登出其他设备', r.status === 200);
  r = await call('GET', '/api/notes', undefined, { secondCookie: true });
  ok('第二个会话已失效', r.status === 401);
  r = await call('GET', '/api/notes');
  ok('当前会话仍有效', r.status === 200);

  // --- Bearer 令牌 + 全量同步 + CORS（安卓 App）---
  r = await call('POST', '/api/auth/login', { username: 'tester', authKey: newAuthKey });
  ok('登录返回 Bearer 令牌', r.status === 200 && typeof r.json.token === 'string' && r.json.token.length >= 32);
  const bearerToken = r.json.token as string;
  const bearerRes = await fetch(`${BASE}/api/notes/full`, {
    headers: { authorization: `Bearer ${bearerToken}` },
  });
  const bearerJson = (await bearerRes.json().catch(() => ({}))) as { notes?: any[] };
  ok(
    'Bearer 令牌可访问全量同步（含卡片密文）',
    bearerRes.status === 200 &&
      Array.isArray(bearerJson.notes) &&
      bearerJson.notes.length > 0 &&
      bearerJson.notes.every((n: any) => typeof n.content === 'string'),
  );
  const noAuth = await fetch(`${BASE}/api/notes/full`);
  ok('无凭证不可访问全量同步', noAuth.status === 401);
  const pre = await fetch(`${BASE}/api/notes`, {
    method: 'OPTIONS',
    headers: {
      origin: 'http://localhost',
      'access-control-request-method': 'GET',
      'access-control-request-headers': 'authorization',
    },
  });
  ok(
    'CORS 预检放行安卓壳',
    pre.status === 204 &&
      (pre.headers.get('access-control-allow-origin') ?? '') === 'http://localhost' &&
      (pre.headers.get('access-control-allow-headers') ?? '').includes('authorization'),
  );

  // --- 分组删除联动 ---
  r = await call('DELETE', `/api/groups/${rootGroupId}`);
  ok('删除分组', r.status === 200);
  r = await call('GET', '/api/notes?group=none');
  ok('组内笔记回到未分组', r.json.notes?.some((n: any) => n.id === noteId && n.groupId === null));
  r = await call('GET', '/api/groups');
  const childGroupRow = r.json.groups?.find((g: any) => g.id === childGroupId);
  ok('子分组升为一级', childGroupRow && childGroupRow.parentId === null);

  // --- 密码卡片（服务端视角：只见密文字符串） ---
  const cipher = Buffer.from('iv+cipher-like-blob').toString('base64');
  r = await call('POST', '/api/notes', {
    type: 'card',
    title: '不该被存储的标题',
    content: cipher,
    plainText: '不该被搜索的明文',
    tags: ['密码'],
    pinned: false,
  });
  ok('创建卡片笔记', r.status === 201 && r.json.note.type === 'card');
  const cardId = r.json.note?.id;
  ok('卡片标题与正文在服务端被清空', r.json.note.title === '' && r.json.note.plainText === '');
  r = await call('GET', '/api/notes');
  const cardSummary = r.json.notes?.find((n: any) => n.id === cardId);
  const textSummary = r.json.notes?.find((n: any) => n.type === 'text');
  ok(
    '摘要对卡片附带密文、对文本不带 content',
    cardSummary?.content === cipher && textSummary?.content === undefined,
  );
  r = await call('GET', '/api/notes?q=不该被搜索的明文');
  ok('卡片内容不参与服务端搜索', (r.json.notes ?? []).length === 0);
  r = await call('PUT', `/api/notes/${cardId}`, {
    type: 'card',
    content: cipher + 'x',
    expectedVersion: 1,
  });
  ok('卡片可更新', r.status === 200 && r.json.note.version === 2);

  // --- 明文卡片（enc=false）：标题可搜索、不加密 ---
  r = await call('POST', '/api/notes', {
    type: 'card',
    title: '明文卡片',
    content: JSON.stringify({ name: '明文卡片', url: '', notes: '', credentials: [{ label: '', username: 'plain-user', password: 'plain-pw' }] }),
    plainText: '明文卡片\nplain-user',
    tags: ['明文'],
    pinned: false,
    enc: false,
  });
  const plainCardId = r.json.note?.id;
  ok('创建明文卡片（标题保留）', r.status === 201 && r.json.note.enc === false && r.json.note.title === '明文卡片');
  r = await call('GET', '/api/notes?q=plain-user');
  ok('明文卡片可被服务端搜索', (r.json.notes ?? []).some((n: any) => n.id === plainCardId));

  // --- DS Note (.nsx) 导入 ---
  const mkZip = async (files: Record<string, Buffer>) => {
    const { zipSync } = await import('fflate');
    const obj: Record<string, Uint8Array> = {};
    for (const [k, v] of Object.entries(files)) obj[k] = new Uint8Array(v);
    return Buffer.from(zipSync(obj));
  };
  const nsxBytes = await mkZip({
    'config.json': Buffer.from(
      JSON.stringify({ note: ['n1', 'n2', 'n3'], notebook: ['nb1'], tag: ['tg1'] }),
    ),
    nb1: Buffer.from(JSON.stringify({ category: 'notebook', title: 'DS笔记本', stack: '' })),
    tg1: Buffer.from(JSON.stringify({ category: 'tag', title: 'DS标签' })),
    n1: Buffer.from(
      JSON.stringify({
        title: 'DS导入笔记',
        brief: '这是导入的正文摘要',
        content: '<div><p>第一段</p><p>第二段<b>加粗</b></p></div>',
        ctime: 1757000000,
        mtime: 1757000100,
        parent_id: 'nb1',
        tags: ['tg1'],
        encrypt: false,
      }),
    ),
    n2: Buffer.from(JSON.stringify({ title: '加密笔记', content: '<p>x</p>', encrypt: true })),
    n3: Buffer.from(JSON.stringify({ title: '无内容笔记', parent_id: '' })),
  });
  const nsxFd = new FormData();
  nsxFd.append('file', new Blob([nsxBytes], { type: 'application/octet-stream' }), 'test.nsx');
  r = await call('POST', '/api/import/nsx', nsxFd);
  ok('DS Note 导入成功', r.status === 200 && r.json.imported === 2 && r.json.skippedEncrypted === 1);
  const dsGroup = ((await call('GET', '/api/groups')).json.groups ?? []).find(
    (g: any) => g.name === 'DS笔记本',
  );
  ok('笔记本已建为分组', !!dsGroup);
  r = await call('GET', '/api/notes?q=导入的正文摘要');
  const dsNote = r.json.notes?.find((n: any) => n.title === 'DS导入笔记');
  ok('导入笔记可搜索且带标签', !!dsNote && JSON.stringify(dsNote.tags).includes('DS标签'));
  ok('导入笔记归入分组', dsNote?.groupId === dsGroup?.id);
  const dsFull = await call('GET', `/api/notes/${dsNote.id}`);
  const dsContent = JSON.stringify(dsFull.json.note?.content);
  ok('HTML 已转为 Tiptap JSON', dsContent.includes('paragraph') && dsContent.includes('加粗'));
  ok('原时间戳保留', dsFull.json.note?.createdAt?.startsWith('2025-09-'));

  const badNsx = new FormData();
  badNsx.append('file', new Blob([Buffer.from('garbage')]), 'bad.nsx');
  r = await call('POST', '/api/import/nsx', badNsx);
  ok('损坏的 nsx 被拒绝', r.status === 400);

  // --- 收尾 ---
  r = await call('POST', '/api/trash/empty');
  ok('清空回收站接口', r.status === 200);

  // --- 备份还原全流程（放在最后：成功后服务进程会退出重启） ---
  const bk = await fetch(BASE + '/api/backup', { headers: { cookie } });
  const zipBytes = Buffer.from(await bk.arrayBuffer());
  ok(
    '备份导出 zip',
    bk.status === 200 &&
      (bk.headers.get('content-type') ?? '').includes('zip') &&
      zipBytes.length > 100 &&
      zipBytes[0] === 0x50 &&
      zipBytes[1] === 0x4b,
  );

  const badFd = new FormData();
  badFd.append('file', new Blob([Buffer.from('this is not a zip')], { type: 'application/zip' }), 'bad.zip');
  const badRes = await fetch(BASE + '/api/restore', { method: 'POST', body: badFd, headers: { cookie } });
  ok('损坏的备份被拒绝', badRes.status === 400);

  const noteCountBefore = ((await call('GET', '/api/notes')).json.notes ?? []).length;
  r = await call('POST', '/api/notes', noteBody({ title: '还原后应该消失的笔记', pinned: false }));
  const extraId = r.json.note?.id;
  ok('追加一条将被还原抹掉的笔记', r.status === 201 && !!extraId);

  const goodFd = new FormData();
  goodFd.append('file', new Blob([zipBytes], { type: 'application/zip' }), 'backup.zip');
  const restoreRes = await fetch(BASE + '/api/restore', {
    method: 'POST',
    body: goodFd,
    headers: { cookie },
  });
  const restoreJson = (await restoreRes.json().catch(() => ({}))) as { ok?: boolean };
  ok('还原请求成功', restoreRes.status === 200 && restoreJson.ok === true);

  // 等旧进程退出，重启新进程验证数据回到备份时点
  await new Promise((res) => setTimeout(res, 2000));
  child.kill();
  await new Promise((res) => setTimeout(res, 1000));
  const child2 = spawn(process.execPath, [serverJs], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR: dataDir },
    stdio: 'ignore',
  });
  await waitServer();
  const after = await fetch(BASE + '/api/notes', { headers: { cookie } });
  const afterJson = (await after.json().catch(() => ({}))) as { notes?: any[] };
  ok('重启后原会话仍有效（会话随备份恢复）', after.status === 200);
  ok(
    '数据回到备份时点',
    afterJson.notes?.length === noteCountBefore && !afterJson.notes?.some((n: any) => n.id === extraId),
  );
  child2.kill();

  console.log(`\n结果: ${passed} 通过, ${failed} 失败`);
}

main()
  .catch((e) => {
    failed++;
    console.error('冒烟测试异常:', e);
  })
  .finally(() => {
    child.kill();
    setTimeout(() => fs.rmSync(dataDir, { recursive: true, force: true }), 500);
    process.exit(failed > 0 ? 1 : 0);
  });
