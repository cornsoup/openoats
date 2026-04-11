# Future Ideas

Rolling list of things to tackle later. Add to the top, mark as done or move to a dated spec when you start working on one.

---

## 1. Native macOS design review

Review the entire codebase with an eye toward making OpenOats feel like a standard, idiomatic macOS app. Current UI has ad-hoc layouts, custom chrome, and mixed patterns that don't match platform conventions.

**Reference skill:** https://mcpmarket.com/tools/skills/macos-native-design

**Likely areas to examine:**
- Window chrome, title bar, toolbar conventions
- Standard menu bar items and shortcuts
- Sheet vs panel vs window usage
- Control sizing and spacing (SF Symbols, SF font metrics)
- Sidebar patterns vs the current stacked-panes approach
- Keyboard navigation and focus rings
- Accessibility (VoiceOver labels, Dynamic Type where reasonable)

**Outcome:** a spec listing concrete changes, ordered by impact.

---

## 2. Five-level detail slider for the live summary

Add a 5-position slider at the bottom of the Meeting Summary pane that controls how much detail the summary shows. Levels roughly:

1. **Tight** — one-paragraph summary, essential only
2. **Brief** — a few sentences, a little more color
3. **Standard** — the current default
4. **Detailed** — fuller narrative with minor points
5. **Comprehensive** — near-transcript level of detail

**Implementation sketch:**
- Change the LLM prompt in `LiveSummaryEngine` to request five parallel versions in one JSON response:
  ```json
  {
    "summaries": { "1": "...", "2": "...", "3": "...", "4": "...", "5": "..." },
    "newKeyPoints": ["..."]
  }
  ```
- Store all five in the engine's state; display only the one matching the slider position.
- Slider position persists like zoom (new `AppSettings.summaryDetailLevel: Int`, default 3).
- When the user drags the slider, no new LLM call — just switch which stored version renders. Only when the next scheduled update fires does the engine regenerate all five at once.
- Cost impact: ~2-3x the tokens per update (more output). Still bounded per update.

**Open questions:**
- Should the slider affect key points too, or only the narrative? (Probably narrative only — key points are atomic.)
- How to visually show that changing the slider is free/instant vs waiting for the next update?

---

## 3. Topic-organized key points

Right now key points accumulate as a flat list, which gets unwieldy in long meetings. Better: group key points by topic, so a 45-minute meeting shows something like:

```
Pricing Discussion
  • CAC under $50 via referral
  • Gross margins target 70%

Launch Timeline
  • Shipped April 15
  • Two-week opt-in period

Compliance Concerns
  • Legal flagged session tokens
```

**Implementation sketch:**
- Change the LLM schema to return topic-grouped points:
  ```json
  {
    "summary": "...",
    "keyPointsByTopic": {
      "Pricing Discussion": ["...", "..."],
      "Launch Timeline": ["..."]
    }
  }
  ```
- On update, merge new topics into existing ones (same topic name = append to that group; new topic = new section).
- The LLM system prompt needs to tell it to reuse existing topic names when the new material fits an existing topic, to avoid fragmentation.
- Rendering: the "Key Points" section in `LiveSummaryPanel` becomes a list of collapsible topic headers with bullets underneath. Each topic can be independently collapsed (possibly with its own persistent state).

**Risks:**
- Topic drift: the LLM might rename "Pricing" to "Pricing & Unit Economics" on a later update, creating a duplicate section. Mitigation: pass the list of existing topic names in the prompt and tell the LLM to reuse them when appropriate.
- Too many topics: a meandering meeting could create 15 thin sections. Mitigation: minimum 2-point threshold before a topic gets its own section, or a cap on the number of topics with a "Misc" bucket for the rest.

---
