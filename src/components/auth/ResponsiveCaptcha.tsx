import { useEffect, useState } from 'react';
import HCaptcha from '@hcaptcha/react-hcaptcha';

interface ResponsiveCaptchaProps {
  instanceKey: number;
  siteKey: string;
  onVerify: (token: string) => void;
  onExpire: () => void;
  onError: () => void;
}

const COMPACT_CAPTCHA_QUERY = '(max-width: 360px)';

function shouldUseCompactCaptcha() {
  return typeof window !== 'undefined' && window.matchMedia(COMPACT_CAPTCHA_QUERY).matches;
}

export function ResponsiveCaptcha({
  instanceKey,
  siteKey,
  onVerify,
  onExpire,
  onError,
}: ResponsiveCaptchaProps) {
  const [isCompact, setIsCompact] = useState(shouldUseCompactCaptcha);

  useEffect(() => {
    const mediaQuery = window.matchMedia(COMPACT_CAPTCHA_QUERY);
    const handleChange = () => setIsCompact(mediaQuery.matches);

    handleChange();
    mediaQuery.addEventListener('change', handleChange);

    return () => {
      mediaQuery.removeEventListener('change', handleChange);
    };
  }, []);

  return (
    <div className="max-w-full overflow-hidden">
      <HCaptcha
        key={`${instanceKey}-${isCompact ? 'compact' : 'normal'}`}
        sitekey={siteKey}
        size={isCompact ? 'compact' : 'normal'}
        onVerify={onVerify}
        onExpire={onExpire}
        onError={onError}
      />
    </div>
  );
}
