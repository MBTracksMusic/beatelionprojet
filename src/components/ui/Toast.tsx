import { AlertCircle, CheckCircle, Info, X } from 'lucide-react';
import { useEffect, useState } from 'react';

export type ToastType = 'success' | 'error' | 'info' | 'warning';

export interface Toast {
  id: string;
  type: ToastType;
  message: string;
  duration?: number;
}

interface ToastProps extends Toast {
  onClose: (id: string) => void;
}

const icons = {
  success: <CheckCircle className="w-5 h-5 text-green-400" />,
  error: <AlertCircle className="w-5 h-5 text-red-400" />,
  warning: <AlertCircle className="w-5 h-5 text-yellow-400" />,
  info: <Info className="w-5 h-5 text-blue-400" />,
};

const bgColors = {
  success: 'bg-green-900/20 border-green-700/50',
  error: 'bg-red-900/20 border-red-700/50',
  warning: 'bg-yellow-900/20 border-yellow-700/50',
  info: 'bg-blue-900/20 border-blue-700/50',
};

export function Toast({ id, type, message, duration = 5000, onClose }: ToastProps) {
  const [isExiting, setIsExiting] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => {
      setIsExiting(true);
      setTimeout(() => onClose(id), 300);
    }, duration);

    return () => clearTimeout(timer);
  }, [id, duration, onClose]);

  return (
    <div
      className={`transform transition-all duration-300 ${
        isExiting ? 'translate-x-full opacity-0' : 'translate-x-0 opacity-100'
      }`}
    >
      <div
        className={`flex items-center gap-3 px-4 py-3 rounded-lg border backdrop-blur-sm ${bgColors[type]}`}
        role="alert"
      >
        {icons[type]}
        <span className="text-sm text-gray-100 flex-1">{message}</span>
        <button
          type="button"
          onClick={() => {
            setIsExiting(true);
            setTimeout(() => onClose(id), 300);
          }}
          className="ml-2 p-1 hover:bg-white/10 rounded transition-colors"
          aria-label="Close notification"
        >
          <X className="w-4 h-4 text-gray-400" />
        </button>
      </div>
    </div>
  );
}

export function ToastContainer({ toasts, onClose }: { toasts: Toast[]; onClose: (id: string) => void }) {
  return (
    <div className="fixed top-4 right-4 z-50 space-y-2 pointer-events-none">
      {toasts.map((toast) => (
        <div key={toast.id} className="pointer-events-auto">
          <Toast {...toast} onClose={onClose} />
        </div>
      ))}
    </div>
  );
}
