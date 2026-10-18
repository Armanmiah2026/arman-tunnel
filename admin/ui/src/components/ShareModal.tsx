/**
 * QR share modal — encodes the node's real share link (vless/vmess/trojan/ss)
 * or its canonical JSON for SSH/OpenVPN. The link is built server-side by the
 * same schema the app imports, so what the QR carries is exactly what lands on
 * a device.
 */
import React, { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { api } from '../api';
import { Button, Modal, Notice } from './ui';

export function ShareModal(props: {
  config: { id: string; name: string } | null;
  onClose: () => void;
}) {
  const [dataUrl, setDataUrl] = useState('');
  const [payload, setPayload] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (!props.config) return;
    let alive = true;
    setDataUrl('');
    setError('');
    (async () => {
      try {
        const link = await api.getConfigShareLink(props.config!.id);
        if (!alive) return;
        setPayload(link);
        setDataUrl(
          await QRCode.toDataURL(link, {
            width: 512,
            margin: 1,
            color: { dark: '#0b0913', light: '#c084fc' },
          }),
        );
      } catch (e: any) {
        if (alive) setError(e?.message || 'Could not build a share code');
      }
    })();
    return () => {
      alive = false;
    };
  }, [props.config]);

  return (
    <Modal open={!!props.config} onClose={props.onClose} title={`Share “${props.config?.name ?? ''}”`}>
      <div className="flex flex-col items-center gap-3">
        {error ? (
          <Notice kind="warn">{error}</Notice>
        ) : dataUrl ? (
          <>
            {/* eslint-disable-next-line jsx-a11y/alt-text */}
            <img src={dataUrl} alt="Config QR" className="h-56 w-56 rounded-xl border border-line" />
            <p className="break-all text-center font-mono text-[10px] leading-relaxed text-hint">
              {payload.length > 220 ? payload.slice(0, 220) + '…' : payload}
            </p>
            <Button
              variant="primary"
              onClick={() => {
                void navigator.clipboard.writeText(payload);
              }}
            >
              Copy to clipboard
            </Button>
          </>
        ) : (
          <div className="flex h-56 w-56 items-center justify-center rounded-xl border border-line">
            <span className="h-5 w-5 animate-spin rounded-full border-2 border-accent border-t-transparent" />
          </div>
        )}
        {!error && payload && !payload.match(/^(vless|vmess|trojan|ss):\/\//) && (
          <Notice kind="info">
            This protocol has no standard share URI, so the QR carries the canonical JSON — importable in the app via paste.
          </Notice>
        )}
      </div>
    </Modal>
  );
}
