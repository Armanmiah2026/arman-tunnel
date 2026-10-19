/**
 * Small shared primitives for the admin panel. Everything visual derives from
 * the tokens in index.css — violet accent, amber for warnings, no other hues.
 */
import React, { useEffect, useRef } from 'react';

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

export function Card(props: { children: React.ReactNode; className?: string }) {
  return (
    <div
      className={`rounded-2xl border border-line bg-surface p-4 sm:p-5 ${props.className || ''}`}
    >
      {props.children}
    </div>
  );
}

export function SectionTitle(props: {
  icon?: React.ReactNode;
  title: string;
  caption?: string;
  right?: React.ReactNode;
}) {
  return (
    <div className="mb-3 flex items-start justify-between gap-3">
      <div className="min-w-0">
        <h2 className="flex items-center gap-2 text-sm font-bold text-ink">
          {props.icon}
          <span>{props.title}</span>
        </h2>
        {props.caption && <p className="mt-0.5 text-xs leading-relaxed text-hint">{props.caption}</p>}
      </div>
      {props.right}
    </div>
  );
}

export function PageHeader(props: {
  title: string;
  caption?: string;
  actions?: React.ReactNode;
}) {
  return (
    <header className="mb-4 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-lg font-black tracking-tight text-ink">{props.title}</h1>
        {props.caption && <p className="mt-1 max-w-xl text-xs text-muted">{props.caption}</p>}
      </div>
      {props.actions && <div className="flex flex-wrap items-center gap-2">{props.actions}</div>}
    </header>
  );
}

export function EmptyState(props: {
  icon?: React.ReactNode;
  title: string;
  caption?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-2 rounded-2xl border border-dashed border-line bg-surface/50 px-6 py-10 text-center">
      {props.icon && <div className="text-accent">{props.icon}</div>}
      <p className="text-sm font-bold text-ink">{props.title}</p>
      {props.caption && <p className="max-w-sm text-xs text-muted">{props.caption}</p>}
      {props.action}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

const inputCls =
  'w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-[13px] text-ink outline-none transition placeholder:text-hint focus:border-accent disabled:opacity-50';

export function Field(props: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  hint?: string;
  type?: 'text' | 'password' | 'number' | 'url';
  mono?: boolean;
  required?: boolean;
  error?: string | null;
  min?: number;
  max?: number;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">
        {props.label}
        {props.required && <span className="text-accent"> *</span>}
      </span>
      <input
        type={props.type || 'text'}
        value={props.value}
        min={props.min}
        max={props.max}
        onChange={(e) => props.onChange(e.target.value)}
        placeholder={props.placeholder}
        spellCheck={false}
        autoComplete="off"
        className={`${inputCls} ${props.mono ? 'font-mono text-xs' : ''} ${
          props.error ? 'border-warn' : ''
        }`}
      />
      {(props.error || props.hint) && (
        <span className={`mt-1 block text-[11px] ${props.error ? 'text-warn' : 'text-hint'}`}>
          {props.error || props.hint}
        </span>
      )}
    </label>
  );
}

export function TextArea(props: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  rows?: number;
  placeholder?: string;
  mono?: boolean;
  error?: string | null;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">
        {props.label}
      </span>
      <textarea
        rows={props.rows ?? 4}
        value={props.value}
        onChange={(e) => props.onChange(e.target.value)}
        placeholder={props.placeholder}
        spellCheck={false}
        className={`${inputCls} resize-y leading-relaxed ${props.mono ? 'font-mono text-xs' : ''} ${
          props.error ? 'border-warn' : ''
        }`}
      />
      {props.error && <span className="mt-1 block text-[11px] text-warn">{props.error}</span>}
    </label>
  );
}

export function Select<T extends string>(props: {
  label: string;
  value: T;
  options: ReadonlyArray<{ value: T; label: string }>;
  onChange: (v: T) => void;
  hint?: string;
  disabled?: boolean;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">
        {props.label}
      </span>
      <select
        value={props.value}
        onChange={(e) => props.onChange(e.target.value as T)}
        disabled={props.disabled}
        className={inputCls}
      >
        {props.options.map((o) => (
          <option key={o.value} value={o.value} className="bg-surface text-ink">
            {o.label}
          </option>
        ))}
      </select>
      {props.hint && <span className="mt-1 block text-[11px] text-hint">{props.hint}</span>}
    </label>
  );
}

export function Switch(props: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  hint?: string;
  danger?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={() => props.onChange(!props.checked)}
      className="flex w-full items-center justify-between gap-3 rounded-xl border border-line bg-bg px-3 py-2.5 text-left transition hover:border-accent/50"
    >
      <span className="min-w-0">
        <span className={`block text-[13px] font-semibold ${props.danger ? 'text-warn' : 'text-ink'}`}>
          {props.label}
        </span>
        {props.hint && <span className="block text-[11px] text-hint">{props.hint}</span>}
      </span>
      <span
        className={`relative h-6 w-10 shrink-0 rounded-full transition ${
          props.checked ? 'bg-accent' : 'bg-surface2'
        }`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${
            props.checked ? 'left-[18px]' : 'left-0.5'
          }`}
        />
      </span>
    </button>
  );
}

type ButtonVariant = 'primary' | 'ghost' | 'danger' | 'lime';
const buttonVariants: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-black hover:brightness-110',
  lime: 'bg-lime text-black hover:brightness-105',
  ghost: 'bg-surface2 text-ink hover:bg-border',
  danger: 'bg-warn text-black hover:brightness-110',
};

export function Button(props: {
  children: React.ReactNode;
  onClick?: () => void;
  variant?: ButtonVariant;
  type?: 'button' | 'submit';
  disabled?: boolean;
  busy?: boolean;
  small?: boolean;
  full?: boolean;
  title?: string;
  className?: string;
}) {
  return (
    <button
      type={props.type || 'button'}
      title={props.title}
      disabled={props.disabled || props.busy}
      onClick={props.onClick}
      className={`${props.className || ''} inline-flex items-center justify-center gap-1.5 rounded-xl font-bold transition active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-50 ${
        props.small ? 'px-2.5 py-1.5 text-[11px]' : 'px-4 py-2.5 text-[13px]'
      } ${props.full ? 'w-full' : ''} ${buttonVariants[props.variant || 'ghost']}`}
    >
      {props.busy && (
        <span className="h-3 w-3 animate-spin rounded-full border-2 border-current border-t-transparent" />
      )}
      {props.children}
    </button>
  );
}

export function Badge(props: {
  children: React.ReactNode;
  tone?: 'accent' | 'muted' | 'warn' | 'outline';
  title?: string;
}) {
  const tones = {
    accent: 'bg-accent/15 text-accent',
    muted: 'bg-surface2 text-muted',
    warn: 'bg-warn/15 text-warn',
    outline: 'border border-line text-hint',
  };
  return (
    <span
      title={props.title}
      className={`inline-flex items-center gap-1 whitespace-nowrap rounded-md px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide ${tones[props.tone || 'muted']}`}
    >
      {props.children}
    </span>
  );
}

export function Notice(props: {
  kind: 'info' | 'warn';
  children: React.ReactNode;
}) {
  const isWarn = props.kind === 'warn';
  return (
    <div
      className={`rounded-xl border px-3 py-2.5 text-xs leading-relaxed ${
        isWarn ? 'border-warn/40 bg-warn/10 text-warn' : 'border-accent/30 bg-accent/10 text-accent'
      }`}
    >
      {props.children}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Modal
// ---------------------------------------------------------------------------

export function Modal(props: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
  wide?: boolean;
  footer?: React.ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!props.open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && props.onClose();
    window.addEventListener('keydown', onKey);
    document.body.style.overflow = 'hidden';
    return () => {
      window.removeEventListener('keydown', onKey);
      document.body.style.overflow = '';
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.open]);

  if (!props.open) return null;
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 p-0 backdrop-blur-sm sm:items-center sm:p-4"
      onMouseDown={(e) => e.target === e.currentTarget && props.onClose()}
    >
      <div
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-label={props.title}
        className={`anim-pop flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-line bg-surface shadow-2xl sm:rounded-2xl ${
          props.wide ? 'sm:max-w-3xl' : 'sm:max-w-lg'
        }`}
      >
        <div className="flex items-center justify-between border-b border-line px-4 py-3">
          <h3 className="text-sm font-bold text-ink">{props.title}</h3>
          <button
            onClick={props.onClose}
            className="rounded-lg p-1.5 text-muted transition hover:bg-surface2 hover:text-ink"
            aria-label="Close"
          >
            ✕
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-4">{props.children}</div>
        {props.footer && (
          <div className="flex flex-wrap items-center justify-end gap-2 border-t border-line px-4 py-3">
            {props.footer}
          </div>
        )}
      </div>
    </div>
  );
}

/** Two-column grid that collapses on mobile. */
export function Grid(props: { children: React.ReactNode; cols?: 2 | 3 }) {
  return (
    <div
      className={`grid gap-3 ${
        props.cols === 3 ? 'sm:grid-cols-2 lg:grid-cols-3' : 'sm:grid-cols-2'
      }`}
    >
      {props.children}
    </div>
  );
}
