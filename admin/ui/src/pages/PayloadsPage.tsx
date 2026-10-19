/**
 * Arman Tunnel admin — Payloads menu.
 *
 * One place for every payload template: filter by protocol family
 * (HTTP / WS / SSL / CONNECT) and by HTTP method (GET / POST / PUT / …),
 * search by name or body, then copy the full template — or the [NAME]
 * reference — straight into any tweak's payload box.
 *
 * READ-ONLY view of Controls → Payload token library (settings.payloadDefs);
 * editing lives there so this page can never desync from the publisher.
 */
import React, { useMemo, useState } from 'react';
import { Check, Copy, Library, Pencil, Search } from 'lucide-react';
import type { Bootstrap } from '../types';
import { Badge, Button, Card, EmptyState, PageHeader, SectionTitle } from '../components/ui';

type Kind = 'HTTP' | 'WS' | 'SSL' | 'CONNECT';

const KINDS: Array<Kind | 'ALL'> = ['ALL', 'HTTP', 'WS', 'SSL', 'CONNECT'];
const METHODS: string[] = ['ALL', 'GET', 'POST', 'PUT', 'PATCH', 'HEAD', 'CONNECT', 'RESPONSE', 'RAW'];

/** First-line method, plus the transport family the template fronts. */
function classify(name: string, tpl: string): { kind: Kind; method: string } {
  const t = tpl.trimStart();
  const m = t.match(/^(CONNECT|GET|POST|PUT|HEAD|OPTIONS|PATCH|DELETE|TRACE)\b/i);
  const method = m ? m[1].toUpperCase() : t.startsWith('HTTP/') ? 'RESPONSE' : 'RAW';
  let kind: Kind = 'HTTP';
  if (method === 'CONNECT') kind = 'CONNECT';
  else if (/upgrade:\s*websocket/i.test(tpl)) kind = 'WS';
  else if (/SNI|SSL/i.test(name)) kind = 'SSL';
  return { kind, method };
}

async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Clipboard API needs a secure context — fall back to the old way.
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
}

function Chip(props: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={props.onClick}
      className={`rounded-full border px-3 py-1 text-[11px] font-bold transition ${
        props.active
          ? 'border-accent bg-accent/15 text-accent'
          : 'border-line bg-bg text-muted hover:text-ink'
      }`}
    >
      {props.label}
    </button>
  );
}

export function PayloadsPage(props: {
  data: Bootstrap;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
  onGoControl: () => void;
}) {
  const defs = props.data.settings?.payloadDefs || {};
  const total = Object.keys(defs).length;
  const [kind, setKind] = useState<Kind | 'ALL'>('ALL');
  const [method, setMethod] = useState<string>('ALL');
  const [q, setQ] = useState('');
  const [copied, setCopied] = useState('');

  const rows = useMemo(() => {
    const list = Object.entries(defs).map(([name, tpl]) => ({ name, tpl, ...classify(name, tpl) }));
    list.sort((a, b) => a.name.localeCompare(b.name));
    const needle = q.trim().toLowerCase();
    return list.filter(
      (e) =>
        (kind === 'ALL' || e.kind === kind) &&
        (method === 'ALL' || e.method === method) &&
        (!needle || e.name.toLowerCase().includes(needle) || e.tpl.toLowerCase().includes(needle)),
    );
  }, [defs, kind, method, q]);

  async function doCopy(name: string, which: 'text' | 'ref', tpl: string) {
    const payload = which === 'text' ? tpl : `[${name}]`;
    await copyText(payload);
    const key = `${name}:${which}`;
    setCopied(key);
    props.notify(which === 'text' ? `Copied ${name} payload` : `Copied [${name}] reference`, 'success');
    setTimeout(() => setCopied((c) => (c === key ? '' : c)), 1500);
  }

  function resetFilters() {
    setKind('ALL');
    setMethod('ALL');
    setQ('');
  }

  if (total === 0) {
    return (
      <div>
        <PageHeader title="Payloads" caption="Every payload template in one place — filter, copy, paste." />
        <EmptyState
          icon={<Library className="h-8 w-8" />}
          title="The payload library is empty"
          caption="Add NAME=template lines in Controls → Payload token library — they will show up here instantly."
          action={
            <Button variant="primary" small onClick={props.onGoControl}>
              <Pencil className="h-3.5 w-3.5" /> Open library editor
            </Button>
          }
        />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Payloads"
        caption={`${total} template${total === 1 ? '' : 's'} · pick a protocol + method, then copy straight into any tweak's payload box.`}
        actions={
          <Button variant="ghost" small onClick={props.onGoControl} title="Edit the library">
            <Pencil className="h-3.5 w-3.5" /> Edit library
          </Button>
        }
      />

      <Card className="space-y-3">
        <SectionTitle title="🔎 Filter" caption="Select a protocol to narrow the list — then pick an HTTP method." />
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-16 text-[11px] font-bold uppercase tracking-wider text-muted">Protocol</span>
          {KINDS.map((k) => (
            <Chip key={k} label={k} active={kind === k} onClick={() => setKind(k)} />
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-16 text-[11px] font-bold uppercase tracking-wider text-muted">Method</span>
          {METHODS.map((m) => (
            <Chip key={m} label={m} active={method === m} onClick={() => setMethod(m)} />
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <span className="w-16 text-[11px] font-bold uppercase tracking-wider text-muted">Search</span>
          <div className="relative min-w-52 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-hint" />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="name or template text…"
              className="w-full rounded-xl border border-line bg-bg py-2 ps-9 pe-3 text-xs text-ink outline-none transition placeholder:text-hint focus:border-accent"
            />
          </div>
          <span className="text-[11px] font-bold text-hint">
            {rows.length}/{total} shown
          </span>
          {(kind !== 'ALL' || method !== 'ALL' || q) && (
            <Button small variant="ghost" onClick={resetFilters}>
              Reset
            </Button>
          )}
        </div>
      </Card>

      {rows.length === 0 ? (
        <EmptyState
          icon={<Library className="h-8 w-8" />}
          title="No payload matches this filter"
          caption="Try another protocol/method combination, or reset the filters."
          action={
            <Button small variant="primary" onClick={resetFilters}>
              Reset filters
            </Button>
          }
        />
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {rows.map((e) => {
            const keyBase = `${e.name}:`;
            return (
              <Card key={e.name} className="space-y-2.5">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-mono text-xs font-black text-accent">{e.name}</span>
                  <Badge tone={e.kind === 'WS' ? 'accent' : e.kind === 'CONNECT' ? 'warn' : 'muted'}>
                    {e.kind}
                  </Badge>
                  <Badge tone="outline">{e.method}</Badge>
                </div>
                <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-bg p-2.5 font-mono text-[11px] leading-relaxed text-muted">
                  {e.tpl}
                </pre>
                <div className="flex flex-wrap gap-2">
                  <Button
                    small
                    variant="primary"
                    onClick={() => void doCopy(e.name, 'text', e.tpl)}
                    title="Copy the full template text"
                  >
                    {copied === keyBase + 'text' ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                    {copied === keyBase + 'text' ? 'Copied!' : 'Copy payload'}
                  </Button>
                  <Button
                    small
                    variant="ghost"
                    onClick={() => void doCopy(e.name, 'ref', e.tpl)}
                    title="Copy the [NAME] reference — the panel expands it at publish"
                  >
                    {copied === keyBase + 'ref' ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                    Copy [{e.name}]
                  </Button>
                </div>
              </Card>
            );
          })}
        </div>
      )}

      <p className="rounded-xl border border-line bg-surface/60 px-3 py-2 text-[11px] leading-relaxed text-hint">
        <b className="text-muted">How to use:</b> copy a payload → open <b className="text-muted">Tweaks</b> →
        edit a tweak → paste into <b className="text-muted">Payload template</b> (or use the{' '}
        <b className="text-muted">From library</b> dropdown right above it). Tokens{' '}
        <code className="text-accent">[host]</code> <code className="text-accent">[crlf]</code>{' '}
        <code className="text-accent">[ua]</code> <code className="text-accent">[split]</code> expand at
        publish/connect time. WS front? Keep the tweak's <b className="text-muted">path</b> exact — the fake
        101 passes, wrong path = backend 404.
      </p>
    </div>
  );
}
