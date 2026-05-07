interface WordmarkProps {
  size?: number;
  showText?: boolean;
}

export function ArcoraLogo({ size = 36 }: { size?: number }) {
  const id = `arc-${size}`;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 512 512"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="ArcoraDEX"
    >
      <defs>
        <linearGradient id={`${id}-blue`} x1="95" y1="349" x2="344" y2="161" gradientUnits="userSpaceOnUse">
          <stop stopColor="#2563FF" />
          <stop offset="1" stopColor="#1D5DFF" />
        </linearGradient>
        <linearGradient id={`${id}-teal`} x1="191" y1="286" x2="431" y2="365" gradientUnits="userSpaceOnUse">
          <stop stopColor="#00C2A8" />
          <stop offset="1" stopColor="#13B8AF" />
        </linearGradient>
      </defs>
      <rect x="58" y="52" width="396" height="396" rx="96" fill="white" />
      <rect x="59" y="53" width="394" height="394" rx="95" stroke="#E6ECF2" strokeWidth="2" />
      <g transform="translate(76 120)">
        <path d="M36 210H100L180 96L207 138H284L238 68L262 32H165L36 210Z" fill={`url(#${id}-blue)`} />
        <path d="M179 32H262L238 68H213L179 32Z" fill="#2563FF" fillOpacity=".2" />
        <path d="M158 118H310L338 151L266 242H198L236 192H124L124 242L78 196L124 150H158V118Z" fill={`url(#${id}-teal)`} />
        <path d="M103 196H235L200 242H266L338 151L310 118H158V150H125L103 172V196Z" fill="#0B1426" fillOpacity=".06" />
      </g>
    </svg>
  );
}

export function Wordmark({ size = 28, showText = true }: WordmarkProps) {
  return (
    <div className="flex items-center gap-2.5">
      <ArcoraLogo size={size} />
      {showText ? (
        <div
          className="flex items-baseline gap-1.5 font-medium"
          style={{
            fontFamily: "var(--font-brand)",
            fontWeight: 600,
            fontSize: size * 0.6,
            letterSpacing: "-0.01em",
          }}
        >
          <span className="text-arc-ink-900">Arcora</span>
          <span className="t-grad">Dex</span>
        </div>
      ) : null}
    </div>
  );
}
