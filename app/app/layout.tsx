import type { Metadata } from "next";
import { Inter } from "next/font/google";
import { Providers } from "@/components/wallet/Providers";
import { Header } from "@/components/layout/Header";
import { Footer } from "@/components/layout/Footer";
import "./globals.css";

const inter = Inter({ variable: "--font-inter", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "ArcoraDEX — Oracle-priced multi-stable DEX",
  description:
    "Public-LP, oracle-priced multi-stablecoin DEX on Arc. Deposit any active stable, earn 90% of swap fees, withdraw single-token at oracle price.",
  metadataBase: new URL("https://swap.arcorapay.xyz"),
  openGraph: {
    title: "ArcoraDEX",
    description: "Oracle-priced multi-stablecoin DEX with public liquidity",
    url: "https://swap.arcorapay.xyz",
    siteName: "ArcoraDEX",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${inter.variable} h-full`}>
      <body className="min-h-full flex flex-col">
        <Providers>
          <Header />
          <main className="flex-1 mx-auto w-full max-w-5xl px-6 py-12">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
