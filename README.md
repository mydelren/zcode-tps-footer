# ZCode-TPS-Footer

给 ZCode 桌面版（macOS）的每条回答下方加上 DeepSeek 风格的用量统计行：

```
15:40 · 用时 7分40秒 · 首 token 7秒 · 49 tok/s · GLM-5.3
```

- **用时**：整轮墙钟（含工具执行时段）
- **首 token**：本轮第一次模型调用的首 token 延迟（TTFT，Time To First Token）
- **tok/s**：Σ输出 token ÷ Σ解码时间（排除首 token 等待，多步回合自动折叠）
- **模型**：本轮用过的模型（多模型斜杠拼接）

历史回答滚动回看时也会自动补上统计行。

## 原理

ZCode 的 CLI 每次模型调用都会把 timing 落进本地 SQLite（`~/.zcode/cli/db/db.sqlite` 的
`model_usage` / `turn_usage` 表）。本工具三件套：

1. **数据服务**：launchd 常驻的本地小服务（127.0.0.1:3117，仅本机可访问），只读方式
   按回合折叠数据库，吐 JSON。
2. **注入脚本**：安装时在渲染层 `index.html` 加一行 `<script>` 标签（重打包 app.asar，
   原包自动备份），脚本监听界面消息节点，按"用户消息 ID"桥接数据库回合，把统计行
   画在每条回答底部。
3. **安装/卸载脚本**：一键装、一键还原。

不动 ZCode 任何业务代码，注入脚本异常全部静默吞掉，最坏情况就是统计行不显示。

## 安装

```bash
git clone https://github.com/HuaiPengFei666/zcode-tps-footer.git
cd zcode-tps-footer
bash install.command    # 或 macOS 下直接双击 install.command
# 然后完全退出 ZCode（Cmd+Q）再打开
```

前置要求：macOS + ZCode 桌面版装在 /Applications + Node.js（npx 可用，用于解/打包 asar）。

## 卸载

```bash
bash uninstall.sh   # 恢复原始 app.asar + 卸载数据服务，重启 ZCode 即纯原生
```

## ZCode 更新后

整包更新会覆盖 app.asar（统计行消失，不影响使用）。**重新双击一次
`install.command` 即可恢复**（脚本自动检测并重打）。

## 兼容性说明

- 仅适配 ZCode 3.11.x（Electron 41）；大版本更新后若界面消息节点结构变了，
  需要更新 `inject.js` 里的选择器（`section[data-turn-id]`，其值为用户消息 ID）。
- 统计口径对齐 deepseek-ai/deepseek-harness（MIT）的 `turn-metrics.ts` 语义。
- 首次安装会自动备份原包为 `app.asar.tps-bak`，随时可回滚。

## 常见问题

- **统计行没出现**：`curl 127.0.0.1:3117/healthz` 看数据服务是否在跑；
  排障日志在 `~/.zcode/tps-inject/server.log`。
- **想关掉某个字段**：编辑 `~/.zcode/tps-inject/inject.js` 的 `render()`，重启 ZCode 生效
  （脚本从磁盘加载，不需要重打 asar）。

## License

MIT。注入与统计口径参考了 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（MIT）。
本工具与 Z.ai 官方无关，修改自用请知悉 ZCode 用户协议的相关条款。
