/**
 * Insert-from-library dropdown for payload textareas.
 *
 * Pick a template from Controls → Payload token library and drop its FULL
 * text into the field (editable right away). Intrinsics ([crlf], [ua],
 * [host] …) stay literal — the publisher expands them — so what you see is
 * what ships to the app. Renders nothing when the library is empty.
 */
import React from 'react';

export function PayloadPicker(props: {
  defs?: Record<string, string>;
  onInsert: (template: string) => void;
}) {
  const defs = props.defs || {};
  const names = Object.keys(defs).sort((a, b) => a.localeCompare(b));
  if (names.length === 0) return null;
  return (
    <div className="mb-1.5 flex flex-wrap items-center gap-2">
      <span className="text-[11px] font-bold uppercase tracking-wider text-muted">From library</span>
      <select
        value=""
        onChange={(e) => {
          const n = e.target.value;
          if (n) props.onInsert(String(defs[n] ?? ''));
        }}
        className="rounded-xl border border-line bg-bg px-2.5 py-1.5 text-[11px] font-bold text-ink outline-none transition focus:border-accent"
      >
        <option value="">Insert a payload…</option>
        {names.map((n) => (
          <option key={n} value={n}>
            {n}
          </option>
        ))}
      </select>
      <span className="text-[10px] text-hint">tap to insert the full template</span>
    </div>
  );
}
