"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Wordmark } from "@/components/brand/Wordmark";
import { ConnectButton } from "@/components/wallet/ConnectButton";
import { FaucetButton } from "@/components/wallet/FaucetButton";

const NAV = [
  { id: "swap", label: "Swap", href: "/" },
  { id: "liquidity", label: "Liquidity", href: "/liquidity" },
  { id: "pool", label: "Pool", href: "/pool" },
];

function isActive(pathname: string, href: string) {
  return href === "/" ? pathname === "/" : pathname.startsWith(href);
}

export function Header() {
  const pathname = usePathname();
  return (
    <header
      className="sticky top-0 z-50 border-b border-arc-ink-100"
      style={{
        background: "rgba(255,255,255,0.85)",
        backdropFilter: "saturate(140%) blur(12px)",
        WebkitBackdropFilter: "saturate(140%) blur(12px)",
      }}
    >
      <div className="mx-auto max-w-[1280px] px-8 py-3.5 flex items-center gap-8">
        <Link href="/" className="flex">
          <Wordmark size={28} />
        </Link>
        <nav className="flex gap-1 ml-2">
          {NAV.map((l) => {
            const active = isActive(pathname, l.href);
            return (
              <Link
                key={l.id}
                href={l.href}
                className="px-3.5 py-2 rounded-full text-sm font-medium transition-colors"
                style={{
                  color: active ? "var(--arc-ink-900)" : "var(--arc-ink-500)",
                  background: active ? "var(--arc-ink-50)" : "transparent",
                }}
              >
                {l.label}
              </Link>
            );
          })}
        </nav>
        <div className="flex-1" />
        <a
          href="https://testnet.arcscan.app"
          target="_blank"
          rel="noreferrer"
          className="hidden sm:flex items-center gap-1.5 text-[13px] text-arc-ink-500 hover:text-arc-ink-700 transition-colors"
        >
          <span className="dot live" />
          Arc Testnet
        </a>
        <FaucetButton />
        <ConnectButton />
      </div>
    </header>
  );
}
