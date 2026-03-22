import { type ReactNode } from 'react';
import { Outlet } from 'react-router-dom';
import { Header } from './Header';
import { Footer } from './Footer';

interface LayoutProps {
  children?: ReactNode;
  hidePlayer?: boolean;
}

export function Layout({ children, hidePlayer }: LayoutProps) {
  return (
    <div className="min-h-screen bg-zinc-950 text-white flex flex-col">
      <Header />
      <main className="flex-1 pt-16 pb-20">{children ?? <Outlet />}</main>
      <Footer />
    </div>
  );
}
