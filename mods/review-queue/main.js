// @ts-check
import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, panes, agents, run, hc, notify, nextCommand, theme } from "herdr";

const MAX_SEEN = 10;
const ERROR_DURATION_MS = 5000;

function icon(program, size, color) {
  if (!program?.icon) return null;
  return program.tint
    ? svg(program.icon).size(size).flex_none().text_color(color)
    : image(program.icon).w(size).h(size).flex_none();
}

function termName(term) {
  return term?.name || term?.template || term?.program?.name || term?.address || "";
}

function cleanSummary(raw) {
  const oneLine = String(raw ?? "").replace(/[\r\n\t]+/g, " ").trim();
  if (oneLine.length <= 200) return oneLine;
  return `${oneLine.slice(0, 199)}…`;
}

function relativeAge(ts, now) {
  const n = Number(ts);
  if (!n || !Number.isFinite(n)) return "just now";
  const diff = Math.max(0, now - n);
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

function statusKey(term, agentStatusMap) {
  const s = agentStatusMap.get(term.address) ?? term.status ?? "idle";
  if (s === "working" || s === "blocked" || s === "done" || s === "idle") return s;
  if (s === "error") return "blocked";
  return "idle";
}

function isLive(term) {
  return Boolean(term?.address) && (term.state == null || term.state === "live");
}

function pendingList(all) {
  return all
    .filter((t) => isLive(t) && t.labels?.review === "ready")
    .sort((a, b) => {
      const atA = Number(a.labels?.["review.at"]) || 0;
      const atB = Number(b.labels?.["review.at"]) || 0;
      if (atA !== atB) return atA - atB;
      return String(a.address).localeCompare(String(b.address));
    });
}

function seenList(all) {
  return all
    .filter((t) => isLive(t) && t.labels?.review === "seen")
    .sort((a, b) => {
      const seenA = Number(a.labels?.["review.seen_at"]) || Number(a.labels?.["review.at"]) || 0;
      const seenB = Number(b.labels?.["review.seen_at"]) || Number(b.labels?.["review.at"]) || 0;
      if (seenB !== seenA) return seenB - seenA;
      return String(a.address).localeCompare(String(b.address));
    })
    .slice(0, MAX_SEEN);
}

export default class ReviewQueue extends View {
  init(_props, cx) {
    this.seenOpen = false;
    this.notified = new Set();
    this.errors = new Map();
    this.seeded = false;
    this.seedInitial(terminals());

    cx.timer.every(30000, (cx) => cx.notify());

    cx.spawn(async (cx) => {
      for (;;) {
        const cmd = await nextCommand();
        if (cmd === "next" || cmd === "review-queue.next") {
          const oldest = pendingList(terminals())[0];
          if (oldest) {
            this.openTerminal(oldest.address);
            cx.notify();
          }
        }
      }
    });
  }

  seedInitial(all) {
    if (!Array.isArray(all)) return;
    for (const term of all) {
      if (isLive(term) && term.labels?.review === "ready") {
        const at = String(term.labels?.["review.at"] ?? "");
        this.notified.add(`${term.address}\u0000${at}`);
      }
    }
  }

  trackNotifications(pending) {
    if (!this.seeded) {
      this.seeded = true;
      for (const term of pending) {
        const at = String(term.labels?.["review.at"] ?? "");
        this.notified.add(`${term.address}\u0000${at}`);
      }
      return;
    }

    for (const term of pending) {
      const at = String(term.labels?.["review.at"] ?? "");
      const key = `${term.address}\u0000${at}`;
      if (this.notified.has(key)) continue;
      this.notified.add(key);

      const name = termName(term);
      const summary = cleanSummary(term.labels?.["review.summary"]);
      notify({
        title: "Ready for review",
        body: summary ? `${name}: ${summary}` : name,
        level: "info",
        action: { name: "agent.focus", args: { terminal: term.address } },
      });
    }
  }

  openTerminal(terminal) {
    const hasPane = panes().some((p) => p.terminal === terminal);
    if (hasPane) {
      run("agent.focus", { terminal });
    } else {
      run("terminal.keep", { terminal, place: "right" });
    }
  }

  runHcLabel(addr, labelArgs, cx) {
    cx.spawn(async (cx) => {
      try {
        const res = await hc(["label", addr, ...labelArgs]);
        if (res.code !== 0) {
          const msg = (res.stderr || res.stdout || `hc label failed (${res.code})`).trim();
          await this.showRowError(addr, msg, cx);
          return;
        }
        if (this.errors.has(addr)) {
          this.errors.delete(addr);
          cx.notify();
        }
      } catch (err) {
        const msg = String(err?.message ?? err ?? "hc label failed").trim();
        await this.showRowError(addr, msg, cx);
      }
    });
  }

  async showRowError(addr, text, cx) {
    const token = {};
    this.errors.set(addr, { text, token });
    cx.notify();
    await cx.sleep(ERROR_DURATION_MS);
    if (this.errors.get(addr)?.token === token) {
      this.errors.delete(addr);
      cx.notify();
    }
  }

  markSeen(addr, cx) {
    const now = Date.now();
    this.runHcLabel(addr, ["review=seen", `review.seen_at=${now}`], cx);
  }

  clearReview(addr, cx) {
    this.runHcLabel(
      addr,
      ["review=", "review.summary=", "review.at=", "review.to=", "review.seen_at="],
      cx,
    );
  }

  reopenReview(term, cx) {
    const addr = term.address;
    const at = String(term.labels?.["review.at"] ?? "");
    this.notified.add(`${addr}\u0000${at}`);
    this.runHcLabel(addr, ["review=ready", "review.seen_at="], cx);
  }

  actionButton(t, id, label, onClick) {
    return div()
      .id(id)
      .px(7)
      .py(2)
      .rounded(5)
      .bg(t.raised)
      .border_1()
      .border_color(t.border)
      .text_size(11)
      .text_color(t.muted)
      .cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((e, cx) => {
        cx.stop_propagation();
        onClick(e, cx);
      })
      .child(label);
  }

  renderRow(t, term, isSeen, now, agentStatusMap) {
    const addr = term.address;
    const name = termName(term);
    const summary = cleanSummary(term.labels?.["review.summary"]);
    const ts = isSeen
      ? term.labels?.["review.seen_at"] ?? term.labels?.["review.at"]
      : term.labels?.["review.at"];
    const age = relativeAge(ts, now);
    const st = statusKey(term, agentStatusMap);
    const dotColor = t[st] ?? t.idle;
    const pic = icon(term.program, 15, t.foreground);
    const rowErr = this.errors.get(addr)?.text;
    const prefix = isSeen ? "seen" : "ready";

    return v_flex()
      .id(`rq-row-${prefix}-${addr}`)
      .w_full()
      .p(9)
      .gap(5)
      .rounded(7)
      .bg(t.surface)
      .border_1()
      .border_color(t.border)
      .cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_click(() => this.openTerminal(addr))
      .child(
        h_flex()
          .w_full()
          .gap(7)
          .items_center()
          .child(div().size(8).rounded(4).flex_none().bg(dotColor))
          .when(Boolean(pic), (el) => el.child(pic))
          .child(
            div()
              .flex_1()
              .min_w(0)
              .truncate()
              .font_semibold()
              .text_size(12.5)
              .text_color(isSeen ? t.muted : t.foreground)
              .child(name),
          )
          .child(div().flex_none().text_size(11).text_color(t.dim).child(addr))
          .child(div().flex_none().text_size(11).text_color(t.dim).child(age)),
      )
      .when(Boolean(summary), (el) =>
        el.child(
          div()
            .w_full()
            .max_h(36)
            .line_height("18px")
            .overflow_hidden()
            .text_ellipsis()
            .text_size(12)
            .text_color(isSeen ? t.dim : t.muted)
            .child(summary),
        ),
      )
      .child(
        h_flex()
          .w_full()
          .pt(2)
          .gap(6)
          .items_center()
          .child(
            this.actionButton(t, `rq-open-${prefix}-${addr}`, "Open", () =>
              this.openTerminal(addr),
            ),
          )
          .when(!isSeen, (el) =>
            el.child(
              this.actionButton(t, `rq-seen-${addr}`, "Seen", (_e, cx) =>
                this.markSeen(addr, cx),
              ),
            ),
          )
          .when(isSeen, (el) =>
            el
              .child(
                this.actionButton(t, `rq-reopen-${addr}`, "Reopen", (_e, cx) =>
                  this.reopenReview(term, cx),
                ),
              )
              .child(
                this.actionButton(t, `rq-clear-${addr}`, "Clear", (_e, cx) =>
                  this.clearReview(addr, cx),
                ),
              ),
          ),
      )
      .when(Boolean(rowErr), (el) =>
        el.child(
          div()
            .w_full()
            .pt(2)
            .text_size(11)
            .text_color(t.blocked)
            .truncate()
            .child(rowErr ?? ""),
        ),
      );
  }

  render() {
    const t = theme();
    const all = terminals();
    const pending = pendingList(all);
    const seen = seenList(all);
    const now = Date.now();
    const agentStatusMap = new Map(agents().map((a) => [a.address, a.status]));

    this.trackNotifications(pending);

    const hasPending = pending.length > 0;

    return v_flex()
      .id("review-queue-root")
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .border_l(1)
      .border_color(t.border)
      .text_color(t.foreground)
      .text_size(13)
      .child(
        h_flex()
          .h(40)
          .px(14)
          .gap(8)
          .flex_none()
          .items_center()
          .justify_between()
          .border_b(1)
          .border_color(t.border)
          .child(div().font_semibold().text_size(13).text_color(t.foreground).child("Review queue"))
          .child(
            div()
              .px(7)
              .py(1)
              .rounded(6)
              .bg(hasPending ? t.done : t.raised)
              .text_size(11)
              .font_semibold()
              .text_color(hasPending ? t.background : t.dim)
              .child(String(pending.length)),
          ),
      )
      .child(
        v_flex()
          .id("review-queue-list")
          .flex_1()
          .min_h(0)
          .p(10)
          .gap(8)
          .overflow_y_scrollbar()
          .when(!hasPending, (el) =>
            el.child(
              v_flex()
                .w_full()
                .py(18)
                .px(10)
                .gap(4)
                .items_center()
                .rounded(7)
                .bg(t.surface)
                .border_1()
                .border_color(t.border)
                .child(
                  div()
                    .font_medium()
                    .text_size(12.5)
                    .text_color(t.muted)
                    .child("Nothing waiting for review"),
                )
                .child(
                  div()
                    .text_size(11)
                    .text_color(t.dim)
                    .child('Run hc-review ready "<summary>" when done'),
                ),
            ),
          )
          .when(hasPending, (el) =>
            el.children(pending.map((term) => this.renderRow(t, term, false, now, agentStatusMap))),
          )
          .when(seen.length > 0, (el) =>
            el.child(
              v_flex()
                .w_full()
                .pt(6)
                .gap(6)
                .child(
                  h_flex()
                    .id("rq-seen-toggle")
                    .w_full()
                    .h(28)
                    .px(6)
                    .gap(6)
                    .rounded(5)
                    .items_center()
                    .cursor_pointer()
                    .hover((s) => s.bg(t.hover))
                    .on_click((_e, cx) => {
                      this.seenOpen = !this.seenOpen;
                      cx.notify();
                    })
                    .child(
                      div()
                        .text_size(11)
                        .text_color(t.dim)
                        .child(this.seenOpen ? "▾" : "▸"),
                    )
                    .child(
                      div()
                        .font_medium()
                        .text_size(11.5)
                        .text_color(t.muted)
                        .child("Seen"),
                    )
                    .child(
                      div()
                        .px(5)
                        .py(1)
                        .rounded(4)
                        .bg(t.raised)
                        .text_size(10.5)
                        .text_color(t.dim)
                        .child(String(seen.length)),
                    ),
                )
                .when(this.seenOpen, (sec) =>
                  sec.children(seen.map((term) => this.renderRow(t, term, true, now, agentStatusMap))),
                ),
            ),
          ),
      );
  }
}
