export function Footer() {
  return (
    <footer className="border-t border-border mt-24 px-6 py-8 text-center text-xs text-fg-muted">
      <p>
        ArcoraDEX · v1 testnet · Part of{" "}
        <a
          href="https://github.com/Kubudak90"
          target="_blank"
          rel="noreferrer"
          className="hover:text-fg transition"
        >
          ArcoraLabs
        </a>
      </p>
      <p className="mt-1">
        <a
          href="https://testnet.arcscan.app"
          target="_blank"
          rel="noreferrer"
          className="hover:text-fg transition"
        >
          Block explorer
        </a>{" "}
        ·{" "}
        <a
          href="https://github.com/Kubudak90/arcoradex"
          target="_blank"
          rel="noreferrer"
          className="hover:text-fg transition"
        >
          Source
        </a>
      </p>
    </footer>
  );
}
