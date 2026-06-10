import { Wordmark } from "@/components/ds/Wordmark";
import { Pill } from "@/components/ds/Pill";

const COLUMNS: { h: string; links: { label: string; href: string }[] }[] = [
  {
    h: "Protocol",
    links: [
      { label: "Swap", href: "/" },
      { label: "Liquidity", href: "/liquidity" },
      { label: "Pool", href: "/pool" },
    ],
  },
  {
    h: "Develop",
    links: [
      { label: "Docs", href: "https://github.com/Kubudak90/arcoradex/tree/main/docs" },
      { label: "SDK", href: "https://github.com/Kubudak90/arcoradex/tree/main/packages/sdk" },
      { label: "GitHub", href: "https://github.com/Kubudak90/arcoradex" },
      { label: "Audit", href: "#" },
    ],
  },
  {
    h: "Ecosystem",
    links: [
      { label: "ArcoraPay", href: "https://arcorapay.xyz" },
      { label: "Arc Network", href: "https://arc.network" },
      { label: "Treasury", href: "#" },
      { label: "Brand", href: "#" },
    ],
  },
  {
    h: "Network",
    links: [
      { label: "Base Sepolia", href: "https://sepolia.basescan.org" },
      { label: "Status", href: "#" },
      { label: "Bridge", href: "#" },
    ],
  },
];

/**
 * Footer — the prototype's 4-column footer. Brand blurb + Wordmark + an
 * "Operational" success pill, the Protocol/Develop/Ecosystem/Network columns
 * (Network relabelled to Base Sepolia), and the mono © / `v2-testnet` bar.
 */
export function Footer() {
  return (
    <footer
      style={{
        position: "relative",
        zIndex: 1,
        borderTop: "1px solid var(--border)",
        marginTop: 80,
        background: "var(--surface)",
      }}
    >
      <div
        style={{
          maxWidth: 1280,
          margin: "0 auto",
          padding: "48px 24px 28px",
          display: "grid",
          gridTemplateColumns: "1.6fr repeat(4, 1fr)",
          gap: 32,
        }}
      >
        <div style={{ maxWidth: 280 }}>
          <Wordmark size={18} />
          <p style={{ marginTop: 14, fontSize: 13, color: "var(--fg-3)", lineHeight: 1.6 }}>
            Stableswap on Base Sepolia. Part of the ArcoraPay ecosystem — settle in any stable,
            swap at oracle price.
          </p>
          <div style={{ marginTop: 16 }}>
            <Pill tone="success">
              <span
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: "50%",
                  background: "var(--success)",
                }}
              />{" "}
              Operational
            </Pill>
          </div>
        </div>
        {COLUMNS.map((c) => (
          <div key={c.h}>
            <div className="overline" style={{ marginBottom: 12 }}>
              {c.h}
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
              {c.links.map((l) => (
                <FooterLink key={l.label} href={l.href} label={l.label} />
              ))}
            </div>
          </div>
        ))}
      </div>
      <div
        style={{
          maxWidth: 1280,
          margin: "0 auto",
          padding: "16px 24px 28px",
          borderTop: "1px solid var(--border-faint)",
          display: "flex",
          justifyContent: "space-between",
          fontSize: 12.5,
          color: "var(--fg-3)",
          fontFamily: "var(--font-mono)",
        }}
      >
        <span>© 2026 ArcoraLabs · v2-testnet</span>
        <span style={{ display: "flex", gap: 16 }}>
          <a href="#" style={{ color: "var(--fg-3)", textDecoration: "none" }}>
            Terms
          </a>
          <a href="#" style={{ color: "var(--fg-3)", textDecoration: "none" }}>
            Privacy
          </a>
        </span>
      </div>
    </footer>
  );
}

function FooterLink({ href, label }: { href: string; label: string }) {
  const external = href.startsWith("http");
  return (
    <a
      href={href}
      target={external ? "_blank" : undefined}
      rel={external ? "noreferrer" : undefined}
      className="footer-link"
      style={{ fontSize: 13.5, color: "var(--fg-2)", textDecoration: "none" }}
    >
      {label}
    </a>
  );
}
