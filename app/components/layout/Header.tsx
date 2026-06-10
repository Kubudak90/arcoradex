"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Wordmark } from "@/components/ds/Wordmark";
import { Icon } from "@/components/ds/Icon";
import { iconBtnStyle } from "@/components/ds/iconBtnStyle";
import { ConnectButton } from "@/components/wallet/ConnectButton";
import { FaucetButton } from "@/components/wallet/FaucetButton";
import { ChainSwitcher } from "@/components/wallet/ChainSwitcher";
import { useTheme } from "./useTheme";

const NAV = [
  { id: "swap", label: "Swap", href: "/" },
  { id: "liquidity", label: "Liquidity", href: "/liquidity" },
  { id: "pool", label: "Pool", href: "/pool" },
];

function isActive(pathname: string, href: string) {
  return href === "/" ? pathname === "/" : pathname.startsWith(href);
}

/**
 * Header — the prototype's sticky glass `TopNav`. Wordmark, NavTab tabs
 * (active = `usePathname()` match with the lime underline), the network
 * switcher chip (`<ChainSwitcher>` — Arc testnet ⇄ Base Sepolia), the Faucet
 * chip (`<FaucetButton>`), the dark/light theme toggle (persisted to
 * localStorage), and `<ConnectButton>`.
 */
export function Header() {
  const pathname = usePathname();
  const { dark, toggle } = useTheme();
  return (
    <header
      style={{
        position: "sticky",
        top: 0,
        zIndex: 100,
        backdropFilter: "blur(var(--glass-blur))",
        WebkitBackdropFilter: "blur(var(--glass-blur))",
        background: "var(--glass-bg)",
        borderBottom: "1px solid var(--border)",
      }}
    >
      <div
        style={{
          maxWidth: 1280,
          margin: "0 auto",
          height: 64,
          padding: "0 24px",
          display: "flex",
          alignItems: "center",
          gap: 24,
        }}
      >
        <Link href="/" style={{ textDecoration: "none", display: "flex" }}>
          <Wordmark size={19} />
        </Link>
        <nav style={{ display: "flex", gap: 2, marginLeft: 8 }}>
          {NAV.map((l) => {
            const active = isActive(pathname, l.href);
            return (
              <Link
                key={l.id}
                href={l.href}
                style={{
                  position: "relative",
                  display: "inline-flex",
                  alignItems: "center",
                  height: 38,
                  padding: "0 14px",
                  textDecoration: "none",
                  fontSize: 14,
                  fontWeight: 600,
                  fontFamily: "var(--font-sans)",
                  color: active ? "var(--fg-1)" : "var(--fg-3)",
                  transition: "color var(--dur-fast)",
                }}
              >
                {l.label}
                {active && (
                  <span
                    style={{
                      position: "absolute",
                      left: 12,
                      right: 12,
                      bottom: -1,
                      height: 2.5,
                      borderRadius: 2,
                      background: "var(--accent)",
                    }}
                  />
                )}
              </Link>
            );
          })}
        </nav>
        <div style={{ flex: 1 }} />
        <ChainSwitcher />
        <FaucetButton />
        <button
          onClick={toggle}
          aria-label="Toggle theme"
          style={{ ...iconBtnStyle, border: "1px solid var(--border)", width: 42, height: 42 }}
          onMouseEnter={(e) => (e.currentTarget.style.background = "var(--surface-2)")}
          onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
        >
          <Icon name={dark ? "sun" : "moon"} size={18} />
        </button>
        <ConnectButton />
      </div>
    </header>
  );
}
