/**
 * ZCode 每答统计行注入脚本（DeepSeek 式：`9月4日 10:27 · 用时 2分44秒 · 首 token 4.3秒 · 42 tok/s`）
 *
 * 挂载方式：由 app/ shim 在每次 did-finish-load 时 executeJavaScript 注入（幂等闸防重复）。
 * 数据源：http://127.0.0.1:3117/turns（launchd 常驻 tps_stats_server.py，口径=tps_footer.py=DeepSeek）。
 * 定位锚：ZCode 渲染层每轮对话是 <section data-turn-id="...">（虚拟滚动，滚到哪渲染哪）。
 * 设计约束：任何异常静默吞掉，绝不影响主界面；React 若删掉注入节点，observer 会重画。
 */
(() => {
  if (window.__tpsFooterLoaded) return;
  window.__tpsFooterLoaded = true;

  const API = "http://127.0.0.1:3117";
  const MARK = "data-tps-footer";
  const CLASS = "tps-footer-line";
  const CACHE_MS = 2000;

  let turns = [];
  let fetchedAt = 0;

  const norm = (s) => String(s || "").replace(/^turn_/, "");

  async function fetchTurns() {
    if (Date.now() - fetchedAt < CACHE_MS) return;
    try {
      const r = await fetch(`${API}/turns?limit=800&_=${Date.now()}`);
      const j = await r.json();
      if (Array.isArray(j.turns)) {
        turns = j.turns;
        fetchedAt = Date.now();
      }
    } catch {
      /* 服务未起，静默 */
    }
  }

  function fmtDur(ms) {
    const t = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(t / 60);
    const s = t % 60;
    return m > 0 ? `${m}分${String(s).padStart(2, "0")}秒` : `${t}秒`;
  }
  function fmtLat(ms) {
    const s = Math.max(0, (ms || 0) / 1000);
    return s < 10 ? String(+s.toFixed(1)) : String(Math.round(s));
  }
  function fmtTps(v) {
    return v >= 10 ? String(Math.round(v)) : String(+Number(v).toFixed(1));
  }
  function fmtStamp(ms) {
    const d = new Date(ms);
    const now = new Date();
    const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    if (d.toDateString() === now.toDateString()) return hm;
    const sameYear = d.getFullYear() === now.getFullYear();
    return sameYear
      ? `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`
      : `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
  }

  function render(section, t) {
    if (section.querySelector(`[${MARK}]`)) return;
    const line = document.createElement("div");
    line.setAttribute(MARK, "1");
    line.className = CLASS;
    const parts = [fmtStamp(t.end_ms), `用时 ${fmtDur(t.run_ms)}`];
    if (t.ttft_ms != null && t.ttft_ms >= 0) parts.push(`首 token ${fmtLat(t.ttft_ms)}秒`);
    if (t.tps) parts.push(`${fmtTps(t.tps)} tok/s`);
    if (Array.isArray(t.models) && t.models.length) parts.push(t.models.join("/"));
    line.textContent = parts.join(" · ");
    Object.assign(line.style, {
      fontSize: "12px",
      opacity: "0.55",
      padding: "0 16px 4px",
      userSelect: "none",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis",
    });
    section.appendChild(line);
    // 可见性自检：渲染了但量出 0 尺寸 → 上报，换挂载策略的依据
    requestAnimationFrame(() => {
      try {
        const r = line.getBoundingClientRect();
        if (r.height === 0 || r.width === 0) ping(-2, `INVISIBLE host=${section.tagName} cls=${(section.className || "").slice(0, 60)}`);
      } catch {}
    });
  }

  let lastSecs = -1;
  function ping(secs, extra) {
    if (secs === lastSecs && !extra) return;
    lastSecs = secs;
    try {
      let snap = "";
      if (secs === 0) {
        snap =
          [...document.body.children]
            .map(
              (e) =>
                e.tagName +
                "[" +
                [...e.attributes].map((a) => a.name + "=" + (a.value || "").slice(0, 30)).join(",") +
                "]" +
                ">" +
                e.children.length
            )
            .join(" | ")
            .slice(0, 1400);
      } else if (extra) {
        snap = extra.slice(0, 1400);
      }
      fetch(`${API}/ping?secs=${secs}&snap=${encodeURIComponent(snap)}`).catch(() => {});
    } catch {}
  }

  let pending = false;
  async function scan() {
    if (pending) return;
    pending = true;
    try {
      const secs = document.querySelectorAll("section[data-turn-id]");
      if (!secs.length) {
        ping(0);
        return;
      }
      // 首扫上报真实 DOM 的 turn-id 原值（诊断匹配用）
      if (lastSecs < 0 || secs.length !== lastExpect) {
        lastExpect = secs.length;
        ping(
          secs.length,
          "IDS " +
            [...secs]
              .slice(0, 10)
              .map((s) => (s.getAttribute("data-turn-id") || "?").slice(0, 44))
              .join(",")
        );
      } else {
        ping(secs.length);
      }
      await fetchTurns();
      let matched = 0,
        rendered = 0,
        missed = 0;
      secs.forEach((s) => {
        if (s.querySelector(`[${MARK}]`)) {
          rendered++;
          return;
        }
        // 桥：界面 section[data-turn-id] 实为用户消息 ID（msg_xxx）→ turns[].msg_id
        const domId = norm(s.getAttribute("data-turn-id"));
        let t = turns.find((x) => norm(x.msg_id) === domId || norm(x.turn_id) === domId);
        if (!t && domId.length >= 16) {
          // 防御：DOM 属性若是截断版，退化为前缀匹配
          t = turns.find((x) => {
            const m = norm(x.msg_id);
            return m.startsWith(domId) || domId.startsWith(m);
          });
        }
        if (t) {
          matched++;
          render(s, t);
        } else {
          missed++;
        }
      });
      if (missed > 0 && matched === 0 && rendered === 0) {
        ping(-1, `NOMATCH dom=${secs.length} cache=${turns.length} first=${(secs[0].getAttribute("data-turn-id") || "?").slice(0, 44)} latest=${turns[0] ? turns[0].turn_id.slice(0, 44) : "?"}`);
      }
    } catch {
      /* 静默 */
    } finally {
      pending = false;
    }
  }
  let lastExpect = -2;

  function start() {
    try {
      const mo = new MutationObserver(() => {
        clearTimeout(mo._t);
        mo._t = setTimeout(scan, 300);
      });
      mo.observe(document.body, { childList: true, subtree: true });
      setInterval(scan, 4000);
      scan();
    } catch {
      /* 静默 */
    }
  }

  if (document.body) start();
  else document.addEventListener("DOMContentLoaded", start);
})();
