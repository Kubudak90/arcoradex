"use client";

interface TokenIconProps {
  symbol: string;
  size?: number;
  className?: string;
}

const PALETTE: Record<string, [string, string]> = {
  USDC: ["#2563FF", "#1D5DFF"],
  USDT: ["#0AA38F", "#13B8AF"],
  PYUSD: ["#1B62FF", "#1B62FF"],
  DAI: ["#F4B731", "#F59E0B"],
  EURC: ["#1F4FB8", "#2563FF"],
  TRYC: ["#DC2626", "#E5484D"],
  BRLC: ["#16A34A", "#0AA38F"],
};

export function TokenIcon({ symbol, size = 24, className }: TokenIconProps) {
  const sym = symbol.toUpperCase();
  const colors = PALETTE[sym] ?? ["#2563FF", "#00C2A8"];
  const id = `tok-${sym}-${size}`;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      className={className}
      role="img"
      aria-label={sym}
      style={{ flexShrink: 0 }}
    >
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse">
          <stop stopColor={colors[0]} />
          <stop offset="1" stopColor={colors[1]} />
        </linearGradient>
      </defs>
      <circle cx="12" cy="12" r="12" fill={`url(#${id})`} />
      <text
        x="12"
        y="14"
        textAnchor="middle"
        dominantBaseline="middle"
        fontSize={size * 0.36}
        fontFamily="Roboto, system-ui, sans-serif"
        fontWeight="700"
        fill="white"
        style={{ letterSpacing: "-0.02em" }}
      >
        {sym.slice(0, 4)}
      </text>
    </svg>
  );
}
