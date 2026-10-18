/**
 * ImageUpload — the panel's image-DB picker.
 *
 * A controlled component on a URL string. Three ways to set it:
 *   · pick a file → uploaded to imgbb (via the Worker's /api/upload-image)
 *     → the returned URL lands in the field
 *   · "From library" → a modal grid of every previously uploaded image
 *     (web-loaded previews, newest first) — click to select
 *   · paste any hosted image URL by hand
 * Plus a live preview and a clear button. Used for server/tweak logos
 * (Robi/Airtel instead of country flags) and the backend wallpaper.
 */
import React, { useEffect, useRef, useState } from 'react';
import { api } from '../api';
import type { PanelImage } from '../types';
import { Modal } from './ui';

/** Logos are rendered as tiny square chips — anything a user offers up is
 *  auto-shrunk to ≤ 100 KB before upload. Wallpapers use their own uploader
 *  (AppControlPage) and keep their original size. */
const LOGO_MAX_BYTES = 100 * 1024;

function approxBytes(dataUrl: string): number {
  const comma = dataUrl.indexOf(',');
  const b64 = comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
  return Math.round((b64.length * 3) / 4);
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('Unreadable image'));
    img.src = src;
  });
}

/** Re-encode an image (data URL) so its byte size drops to ≤ [limitBytes].
 *  PNG is tried first so transparency survives; falls back to a JPEG quality
 *  ladder, then a dimension cap. Never enlarges; returns null on failure. */
async function compressTo(
  dataUrl: string,
  limitBytes: number,
): Promise<string | null> {
  if (approxBytes(dataUrl) <= limitBytes) return dataUrl;
  try {
    const img = await loadImage(dataUrl);
    const canvas = document.createElement('canvas');
    let { width, height } = img;
    // Cap the long edge so huge files shrink by dimensions, not just quality.
    const maxEdge = 512;
    if (Math.max(width, height) > maxEdge) {
      const s = maxEdge / Math.max(width, height);
      width = Math.max(1, Math.round(width * s));
      height = Math.max(1, Math.round(height * s));
    }
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, width, height);

    let png = '';
    try {
      png = canvas.toDataURL('image/png');
    } catch (_) {}
    if (png && approxBytes(png) <= limitBytes) return png;

    for (let q = 0.85; q >= 0.2; q -= 0.1) {
      const jpeg = canvas.toDataURL('image/jpeg', q);
      if (approxBytes(jpeg) <= limitBytes) return jpeg;
    }
    // Absolute fallback — one last shot at the lowest quality.
    return canvas.toDataURL('image/jpeg', 0.18);
  } catch (_) {
    return null;
  }
}

export function ImageUpload(props: {
  label: string;
  value: string;
  onChange: (url: string) => void;
  hint?: string;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const [busy, setBusy] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const [libOpen, setLibOpen] = useState(false);
  const [lib, setLib] = useState<PanelImage[]>([]);
  const [libBusy, setLibBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  async function uploadFile(file: File) {
    if (!file.type.startsWith('image/')) {
      props.notify('Only image files can be uploaded', 'error');
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      props.notify('Image too large (max 5 MB)', 'error');
      return;
    }
    setBusy(true);
    try {
      const dataBase64 = await new Promise<string>((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(String(r.result || ''));
        r.onerror = () => reject(new Error('Could not read the file'));
        r.readAsDataURL(file);
      });
      const shrunk = await compressTo(dataBase64, LOGO_MAX_BYTES);
      if (!shrunk) {
        props.notify('Could not process this image', 'error');
        return;
      }
      const wasShrunk = approxBytes(dataBase64) > LOGO_MAX_BYTES;
      const mime =
        !wasShrunk
          ? file.type
          : shrunk.startsWith('data:image/jpeg')
            ? 'image/jpeg'
            : 'image/png';
      const res = await api.uploadImage(shrunk, file.name, mime);
      props.onChange(res.url);
      props.notify(
        wasShrunk
          ? `Image uploaded (auto-compressed to ${Math.max(1, Math.round(approxBytes(shrunk) / 1024))} KB)`
          : 'Image uploaded',
        'success',
      );
    } catch (e: any) {
      props.notify(e?.message || 'Upload failed', 'error');
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  async function openLibrary() {
    setLibOpen(true);
    setLibBusy(true);
    try {
      const res = await api.images();
      setLib(res.images);
    } catch (e: any) {
      props.notify(e?.message || 'Could not load the library', 'error');
      setLibOpen(false);
    } finally {
      setLibBusy(false);
    }
  }

  async function forget(url: string) {
    try {
      const res = await api.forgetImage(url);
      setLib(res.images);
    } catch (e: any) {
      props.notify(e?.message || 'Could not remove', 'error');
    }
  }

  return (
    <div>
      {props.label && (
        <label className="mb-1 block text-[11px] font-semibold uppercase tracking-wider text-hint">
          {props.label}
        </label>
      )}
      <div className="flex items-start gap-2">
        {/* Preview (web-loaded from the hosted URL) */}
        <div
          className={`flex h-14 w-14 shrink-0 items-center justify-center overflow-hidden rounded-xl border ${
            dragOver ? 'border-accent bg-accent/10' : 'border-line bg-surface2'
          }`}
          onDragOver={(e) => {
            e.preventDefault();
            setDragOver(true);
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDragOver(false);
            const f = e.dataTransfer.files && e.dataTransfer.files[0];
            if (f) void uploadFile(f);
          }}
        >
          {props.value ? (
            <img src={props.value} alt="" className="h-full w-full object-cover" />
          ) : (
            <span className="text-lg">🖼️</span>
          )}
        </div>
        <div className="min-w-0 flex-1 space-y-1.5">
          <div className="flex gap-1.5">
            <input
              value={props.value}
              onChange={(e) => props.onChange(e.target.value)}
              placeholder="https://i.ibb.co/… (upload, library or paste)"
              spellCheck={false}
              className="min-w-0 flex-1 rounded-lg border border-line bg-bg px-2.5 py-1.5 font-mono text-xs outline-none placeholder:text-hint focus:border-accent"
            />
            <button
              type="button"
              disabled={busy || !props.value}
              onClick={() => props.onChange('')}
              title="Clear"
              className="rounded-lg border border-line px-2 text-xs text-muted hover:border-danger hover:text-danger disabled:opacity-40"
            >
              ✕
            </button>
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={() => fileRef.current?.click()}
              className="rounded-lg border border-accent/50 bg-accent/10 px-2.5 py-1 text-[11px] font-bold text-accent hover:bg-accent/20 disabled:opacity-50"
            >
              {busy ? 'Uploading…' : 'Upload image'}
            </button>
            <button
              type="button"
              onClick={() => void openLibrary()}
              className="rounded-lg border border-line px-2.5 py-1 text-[11px] font-bold text-muted hover:border-accent hover:text-accent"
            >
              From library
            </button>
            {props.hint && <span className="text-[10px] text-hint">{props.hint}</span>}
          </div>
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files && e.target.files[0];
              if (f) void uploadFile(f);
            }}
          />
        </div>
      </div>

      {/* Library: every previously uploaded image, web-loaded previews */}
      <Modal
        open={libOpen}
        onClose={() => setLibOpen(false)}
        title={`Image library (${lib.length})`}
        wide
      >
        {libBusy ? (
          <p className="py-8 text-center text-sm text-hint">Loading…</p>
        ) : lib.length === 0 ? (
          <p className="py-8 text-center text-sm text-hint">
            Nothing uploaded yet — upload an image from any form first.
          </p>
        ) : (
          <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
            {lib.map((img) => (
              <div key={img.url} className="group relative">
                <button
                  type="button"
                  onClick={() => {
                    props.onChange(img.url);
                    setLibOpen(false);
                  }}
                  className={`block w-full overflow-hidden rounded-xl border transition-colors ${
                    props.value === img.url ? 'border-accent' : 'border-line hover:border-accent/60'
                  }`}
                  title={img.filename || img.url}
                >
                  <img src={img.url} alt="" className="aspect-square w-full object-cover" />
                </button>
                <button
                  type="button"
                  onClick={() => void forget(img.url)}
                  title="Remove from library"
                  className="absolute right-1 top-1 rounded-lg bg-black/70 px-1.5 py-0.5 text-xs text-white opacity-0 transition-opacity group-hover:opacity-100 focus:opacity-100"
                >
                  ✕
                </button>
              </div>
            ))}
          </div>
        )}
      </Modal>
    </div>
  );
}
