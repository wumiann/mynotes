// 行级文本 diff（LCS），用于版本历史展示每次保存的改动
export interface DiffLine {
  type: 'add' | 'del' | 'same';
  text: string;
}

const MAX_LINES = 500;

export function lineDiff(aText: string, bText: string): DiffLine[] {
  const a = aText ? aText.split('\n').slice(0, MAX_LINES) : [];
  const b = bText ? bText.split('\n').slice(0, MAX_LINES) : [];
  const n = a.length;
  const m = b.length;

  // LCS 动态规划表
  const dp: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ type: 'same', text: a[i] });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ type: 'del', text: a[i] });
      i++;
    } else {
      out.push({ type: 'add', text: b[j] });
      j++;
    }
  }
  while (i < n) {
    out.push({ type: 'del', text: a[i] });
    i++;
  }
  while (j < m) {
    out.push({ type: 'add', text: b[j] });
    j++;
  }
  return out;
}

// 折叠长段未变化内容，便于阅读
export function collapseSame(lines: DiffLine[], keep = 2): (DiffLine | { type: 'gap'; text: string })[] {
  const out: (DiffLine | { type: 'gap'; text: string })[] = [];
  let run = 0;
  for (let idx = 0; idx <= lines.length; idx++) {
    const line = lines[idx];
    if (line && line.type === 'same') {
      run++;
      continue;
    }
    if (run > 0) {
      const start = idx - run;
      const sameLines = lines.slice(start, idx);
      if (run <= keep * 2) {
        out.push(...sameLines);
      } else {
        out.push(...sameLines.slice(0, keep));
        out.push({ type: 'gap', text: `…… 未变化 ${run - keep * 2} 行 ……` });
        out.push(...sameLines.slice(run - keep));
      }
      run = 0;
    }
    if (line) out.push(line);
  }
  return out;
}
