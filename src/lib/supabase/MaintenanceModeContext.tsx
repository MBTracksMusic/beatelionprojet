import { createContext, useContext, type ReactNode } from 'react';
import type { useMaintenanceMode } from './useMaintenanceMode';

type MaintenanceModeValue = ReturnType<typeof useMaintenanceMode>;

const MaintenanceModeContext = createContext<MaintenanceModeValue | null>(null);

interface MaintenanceModeProviderProps {
  value: MaintenanceModeValue;
  children: ReactNode;
}

export function MaintenanceModeProvider({ value, children }: MaintenanceModeProviderProps) {
  return (
    <MaintenanceModeContext.Provider value={value}>
      {children}
    </MaintenanceModeContext.Provider>
  );
}

export function useMaintenanceModeContext() {
  const context = useContext(MaintenanceModeContext);

  if (!context) {
    throw new Error('useMaintenanceModeContext must be used within MaintenanceModeProvider');
  }

  return context;
}
