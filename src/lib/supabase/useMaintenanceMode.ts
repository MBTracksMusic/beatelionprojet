import { useCallback, useEffect, useState } from 'react';
import type { RealtimePostgresChangesPayload } from '@supabase/supabase-js';
import { supabase } from './client';
import type { Database } from './database.types';

type SettingsRow = Database['public']['Tables']['settings']['Row'];
type SettingsRowShape = Pick<SettingsRow, 'id' | 'maintenance_mode' | 'updated_at'>;

const SETTINGS_SELECT = 'id, maintenance_mode, updated_at';
const SETTINGS_CHANNEL = 'public:settings:maintenance-mode';

function isSettingsRow(value: unknown): value is SettingsRowShape {
  if (!value || typeof value !== 'object') return false;

  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.id === 'string'
    && typeof candidate.maintenance_mode === 'boolean'
    && typeof candidate.updated_at === 'string'
  );
}

export function useMaintenanceMode() {
  const [maintenance, setMaintenance] = useState(false);
  const [settingsId, setSettingsId] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const applySettingsRow = useCallback((row: SettingsRowShape | null) => {
    if (!row) {
      setMaintenance(false);
      setSettingsId(null);
      setUpdatedAt(null);
      return;
    }

    setMaintenance(row.maintenance_mode);
    setSettingsId(row.id);
    setUpdatedAt(row.updated_at);
  }, []);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    const { data, error: fetchError } = await supabase
      .from('settings')
      .select(SETTINGS_SELECT)
      .limit(1)
      .maybeSingle();

    if (fetchError) {
      setError(fetchError.message);
      setIsLoading(false);
      return null;
    }

    applySettingsRow(data ?? null);
    setIsLoading(false);
    return data ?? null;
  }, [applySettingsRow]);

  useEffect(() => {
    void refresh();

    const channelName = `${SETTINGS_CHANNEL}:${Math.random().toString(36).slice(2)}`;
    const channel = supabase
      .channel(channelName)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'settings' },
        (payload: RealtimePostgresChangesPayload<Record<string, unknown>>) => {
          if (payload.eventType === 'DELETE') {
            applySettingsRow(null);
            return;
          }

          if (isSettingsRow(payload.new)) {
            applySettingsRow(payload.new);
          }
        },
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [applySettingsRow, refresh]);

  const updateMaintenanceMode = useCallback(async (nextValue: boolean) => {
    if (!settingsId) {
      throw new Error('Maintenance settings row is missing');
    }

    const { data, error: updateError } = await supabase
      .from('settings')
      .update({ maintenance_mode: nextValue })
      .eq('id', settingsId)
      .select(SETTINGS_SELECT)
      .single();

    if (updateError) {
      throw updateError;
    }

    applySettingsRow(data);
    return data;
  }, [applySettingsRow, settingsId]);

  return {
    maintenance,
    settingsId,
    updatedAt,
    isLoading,
    error,
    refresh,
    updateMaintenanceMode,
  };
}
