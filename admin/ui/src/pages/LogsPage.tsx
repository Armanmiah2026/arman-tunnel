import React from 'react';
import { Trash2 } from 'lucide-react';
import type { ActivityLog } from '../types';
import { api } from '../api';
import { Badge, Button, Card, EmptyState, PageHeader } from '../components/ui';

export function LogsPage(props: {
  logs: ActivityLog[];
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  async function clearAll() {
    try {
      await api.clearLogs();
      await props.refresh();
      props.notify('Activity log cleared', 'info');
    } catch (e: any) {
      props.notify(e?.message || 'Failed to clear', 'error');
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Activity"
        caption="Server-side audit trail — sign-ins, publishes, imports and deletions."
        actions={
          <Button variant="ghost" onClick={clearAll}>
            <Trash2 className="h-4 w-4" /> Clear
          </Button>
        }
      />
      {!props.logs.length ? (
        <EmptyState title="No activity yet" />
      ) : (
        <Card className="divide-y divide-line !p-0 overflow-hidden">
          {props.logs.map((l) => (
            <div key={l.id} className="flex items-start gap-3 px-4 py-3">
              <Badge tone={l.status === 'success' ? 'accent' : l.status === 'error' ? 'warn' : 'muted'}>
                {l.type}
              </Badge>
              <div className="min-w-0 flex-1">
                <p className="break-words text-[13px] leading-snug text-ink">{l.action}</p>
                <p className="mt-0.5 text-[11px] text-hint">
                  {new Date(l.time).toLocaleString()}
                  {l.actor ? ` · ${l.actor}` : ''}
                </p>
              </div>
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}
