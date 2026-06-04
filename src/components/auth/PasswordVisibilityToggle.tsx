import { Eye, EyeOff } from 'lucide-react';

interface PasswordVisibilityToggleProps {
  isVisible: boolean;
  onToggle: () => void;
  showLabel: string;
  hideLabel: string;
}

export function PasswordVisibilityToggle({
  isVisible,
  onToggle,
  showLabel,
  hideLabel,
}: PasswordVisibilityToggleProps) {
  const label = isVisible ? hideLabel : showLabel;
  const Icon = isVisible ? EyeOff : Eye;

  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={isVisible}
      title={label}
      onClick={onToggle}
      className="flex h-8 w-8 items-center justify-center rounded-md text-zinc-500 transition-colors hover:text-zinc-200 focus:outline-none focus:ring-2 focus:ring-rose-500/50"
    >
      <Icon className="h-5 w-5" aria-hidden="true" />
    </button>
  );
}
