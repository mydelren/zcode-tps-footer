#!/usr/bin/env node
// 从 asar 包头直读单个文件并写到 stdout（Windows 移植专用）。
// 用途：打补丁前后检查 out/renderer/index.html 是否已含注入标记。
// 背景：@electron/asar 的 extractFile 在 Windows 打包（路径含反斜杠）的归档上报
// "not found"（listPackage 可见但 extractFile 取不到），故按 asar 格式手工解析：
//   [4B header_size][pickle: 4B json_size + JSON 目录] + 各文件内容（offset 相对内容区）
// 用法：node asar-peek.mjs <app.asar> <包内路径，如 out/renderer/index.html>
import fs from "node:fs";

const [asarPath, innerPath] = process.argv.slice(2);
if (!asarPath || !innerPath) {
  console.error("usage: node asar-peek.mjs <app.asar> <inner/path>");
  process.exit(2);
}
const fd = fs.openSync(asarPath, "r");
try {
  const head = Buffer.alloc(16);
  fs.readSync(fd, head, 0, 16, 0);
  const pickleSize = head.readUInt32LE(4); // 目录 pickle 总长（含 4B 长度头）
  const jsonSize = head.readUInt32LE(12);  // JSON 目录本体长度
  const jsonBuf = Buffer.alloc(jsonSize);
  fs.readSync(fd, jsonBuf, 0, jsonSize, 16);
  const header = JSON.parse(jsonBuf.toString("utf8"));

  let node = header;
  for (const seg of innerPath.replace(/\\/g, "/").split("/").filter(Boolean)) {
    node = node.files && node.files[seg];
    if (!node) {
      console.error(`not found in archive: ${seg} (of ${innerPath})`);
      process.exit(1);
    }
  }
  if (!("offset" in node)) {
    console.error(`entry has no offset (directory or unpacked): ${innerPath}`);
    process.exit(1);
  }
  const base = 8 + pickleSize; // 内容区基址：8B 文件头 + 目录 pickle
  const buf = Buffer.alloc(node.size);
  fs.readSync(fd, buf, 0, node.size, base + Number(node.offset));
  process.stdout.write(buf);
} finally {
  fs.closeSync(fd);
}
