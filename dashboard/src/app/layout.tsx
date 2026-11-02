import { GeistSerif } from "geist/font/serif";
import type { Metadata, Viewport } from "next";
import { Geist_Mono } from "next/font/google";
import "./globals.css";

const mono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-geist-mono",
  display: "swap",
});

const title = "meter";
const description = "AI usage across machines.";
const ogImage = { url: "/opengraph-image.png", width: 1200, height: 630, alt: description };

export const metadata: Metadata = {
  title: { default: title, template: "%s · meter" },
  description,
  metadataBase: process.env.NEXT_PUBLIC_SITE_URL ? new URL(process.env.NEXT_PUBLIC_SITE_URL) : undefined,
  robots: { index: false, follow: false },
  manifest: "/manifest.webmanifest",
  openGraph: {
    type: "website",
    siteName: "meter",
    title,
    description,
    images: [ogImage],
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
    images: [ogImage],
  },
};

export const viewport: Viewport = {
  themeColor: "#0b0d12",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${mono.variable} ${GeistSerif.variable} dark`}>
      <body className="min-h-dvh bg-background text-foreground antialiased">{children}</body>
    </html>
  );
}
