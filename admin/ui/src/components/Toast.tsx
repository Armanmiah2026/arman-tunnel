import React from 'react';

export type ToastKind = 'success' | 'error' | 'info';
export interface ToastItem {
  id: number;
  message: string;
  kind: ToastKind;
}

export function ToastHost(props: {
  toasts: ToastItem[];
  onDismiss: (id: number) => void;
}) {
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-20 z-[70] flex flex-col items-center gap-2 px-4 lg:bottom-6">
      {props.toasts.map((t) => (
        <button
          key={t.id}
          onClick={() => props.onDismiss(t.id)}
          className={`anim-in pointer-events-auto max-w-md rounded-xl px-4 py-2.5 text-left text-xs font-semibold shadow-lg ${
            t.kind === 'success'
              ? 'bg-accent text-black'
              : t.kind === 'error'
                ? 'bg-warn text-black'
                : 'bg-surface2 text-ink border border-line'
          }`}
        >
          {t.message}
        </button>
      ))}
    </div>
  );
}
