import { ImagePlus, Trash2, Video } from 'lucide-react';
import { Button } from '../ui/Button';
import type { ForumPostAttachment } from '../../lib/supabase/types';

const ACCEPTED_FORUM_MEDIA = 'image/jpeg,image/png,image/webp,image/gif,video/mp4,video/webm,video/quicktime';

const formatBytes = (value: number) => {
  if (!Number.isFinite(value) || value <= 0) return '';
  if (value < 1024 * 1024) return `${Math.ceil(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(value >= 10 * 1024 * 1024 ? 0 : 1)} MB`;
};

interface ForumMediaFieldProps {
  file: File | null;
  disabled?: boolean;
  label: string;
  hint: string;
  chooseLabel: string;
  removeLabel: string;
  onChange: (file: File | null) => void;
}

export function ForumMediaField({
  file,
  disabled = false,
  label,
  hint,
  chooseLabel,
  removeLabel,
  onChange,
}: ForumMediaFieldProps) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-950/50 p-3">
      <div className="mb-3 flex items-start gap-2">
        {file?.type.startsWith('video/') ? (
          <Video className="mt-0.5 h-4 w-4 text-sky-300" aria-hidden="true" />
        ) : (
          <ImagePlus className="mt-0.5 h-4 w-4 text-amber-300" aria-hidden="true" />
        )}
        <div>
          <p className="text-sm font-medium text-zinc-200">{label}</p>
          <p className="text-xs leading-5 text-zinc-500">{hint}</p>
        </div>
      </div>

      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <label className="inline-flex w-fit cursor-pointer items-center rounded-lg border border-zinc-700 px-3 py-2 text-sm text-zinc-200 hover:bg-zinc-800/80">
          <input
            type="file"
            accept={ACCEPTED_FORUM_MEDIA}
            className="sr-only"
            disabled={disabled}
            onChange={(event) => onChange(event.target.files?.[0] ?? null)}
          />
          {chooseLabel}
        </label>

        {file && (
          <div className="flex min-w-0 items-center gap-2 text-xs text-zinc-400">
            <span className="truncate">{file.name}</span>
            <span className="shrink-0 text-zinc-600">{formatBytes(file.size)}</span>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={disabled}
              onClick={() => onChange(null)}
              aria-label={removeLabel}
            >
              <Trash2 className="h-4 w-4" aria-hidden="true" />
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}

interface ForumPostMediaProps {
  attachments?: ForumPostAttachment[];
}

export function ForumPostMedia({ attachments }: ForumPostMediaProps) {
  const visibleAttachments = attachments?.filter((attachment) => attachment.signed_url) ?? [];
  if (visibleAttachments.length === 0) return null;

  return (
    <div className="mt-4 space-y-3">
      {visibleAttachments.map((attachment) => (
        <div key={attachment.id} className="overflow-hidden rounded-lg border border-zinc-800 bg-black">
          {attachment.media_type === 'image' ? (
            <img
              src={attachment.signed_url ?? ''}
              alt={attachment.original_filename ?? 'Forum media'}
              className="max-h-[520px] w-full object-contain"
              loading="lazy"
            />
          ) : (
            <video
              src={attachment.signed_url ?? ''}
              controls
              preload="metadata"
              className="max-h-[520px] w-full bg-black"
            />
          )}
        </div>
      ))}
    </div>
  );
}
