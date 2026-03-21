import { useEffect } from 'react';
import { useLocation } from 'react-router-dom';
import { initAnalytics, trackPage } from '../../lib/analytics';

export function AnalyticsTracker() {
  const location = useLocation();

  useEffect(() => {
    void initAnalytics();
  }, []);

  useEffect(() => {
    const path = `${location.pathname}${location.search}${location.hash}`;
    trackPage(path);
  }, [location.hash, location.pathname, location.search]);

  return null;
}
