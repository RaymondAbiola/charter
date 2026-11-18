import { notFound } from "next/navigation";
import { Charter } from "@/charter";
import { screens } from "@/lib/screens";

export const dynamicParams = false;

export function generateStaticParams() {
  return screens.map((screen) => ({ screen }));
}

export default async function Page({
  params,
}: {
  params: Promise<{ screen: string }>;
}) {
  const { screen } = await params;
  const selected = screens.find((candidate) => candidate === screen);
  if (!selected) notFound();
  return <Charter screen={selected} />;
}
