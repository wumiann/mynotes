// 行级 diff（LCS 动态规划 + 折叠未变化段）：对齐 Web lib/diff.ts
class DiffLine {
  DiffLine(this.type, this.text); // add | del | same
  final String type;
  final String text;
}

/// LCS 行级 diff
List<DiffLine> lineDiff(String a, String b) {
  final la = a.split('\n');
  final lb = b.split('\n');
  final n = la.length, m = lb.length;
  // dp[i][j] = la[i..] 与 lb[j..] 的最长公共子序列长度
  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = la[i] == lb[j] ? dp[i + 1][j + 1] + 1 : dp[i][j + 1] > dp[i + 1][j] ? dp[i][j + 1] : dp[i + 1][j];
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (la[i] == lb[j]) {
      out.add(DiffLine('same', la[i]));
      i++; j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine('del', la[i]));
      i++;
    } else {
      out.add(DiffLine('add', lb[j]));
      j++;
    }
  }
  while (i < n) { out.add(DiffLine('del', la[i])); i++; }
  while (j < m) { out.add(DiffLine('add', lb[j])); j++; }
  return out;
}

/// 折叠连续未变化段（≥3 行折为 1 行摘要）
List<DiffLine> collapseSame(List<DiffLine> lines, {int threshold = 3}) {
  final out = <DiffLine>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].type == 'same') {
      var j = i;
      while (j < lines.length && lines[j].type == 'same') j++;
      final run = j - i;
      if (run >= threshold) {
        // 保留首尾一行，中间折叠
        out.add(lines[i]);
        out.add(DiffLine('fold', '…未变化 ${run - 2} 行…'));
        if (run >= 2) out.add(lines[j - 1]);
      } else {
        out.addAll(lines.sublist(i, j));
      }
      i = j;
    } else {
      out.add(lines[i]);
      i++;
    }
  }
  return out;
}
