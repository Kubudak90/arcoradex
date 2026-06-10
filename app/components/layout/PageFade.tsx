"use client";
import { usePathname } from "next/navigation";

/**
 * Page-transition wrapper — ported from the prototype's `PageFade`. Re-keyed on
 * the pathname so each route swap replays the `ar-pagein` entrance. Motion is
 * gated globally by `prefers-reduced-motion` (globals.css collapses the
 * animation for those users).
 */
export function PageFade({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <div key={pathname} style={{ animation: "ar-pagein .4s var(--ease-standard)" }}>
      {children}
    </div>
  );
}
