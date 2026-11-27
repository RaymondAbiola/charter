import Link from "next/link";
import type { Screen } from "@/lib/screens";

const notes: Record<
  Exclude<Screen, "overview">,
  { label: string; copy: string }
> = {
  deposit: {
    label: "FOR DEPOSITORS",
    copy: "Supply both pool tokens for LP shares. Managers owe the passive result plus rent; unleased capital stays in the full-range position.",
  },
  leases: {
    label: "THE RENTAL MARKET",
    copy: "Managers compete on rent and put their own bond at risk. Open a slot, or outbid a lease with a five-minute takeover delay.",
  },
  manager: {
    label: "FOR MANAGERS",
    copy: "Run the range. Pay the rent. Keep enough equity to cover what you owe. The hook checks your obligation after every swap.",
  },
  activity: {
    label: "THE AUDIT TRAIL",
    copy: "Follow capital from deposit to settlement. Every entry comes from the hook's events and links to its transaction.",
  },
};

export function ScreenNote({
  screen,
}: {
  screen: Exclude<Screen, "overview">;
}) {
  const note = notes[screen];
  return (
    <div className="c-screen-note">
      <span className="c-eyebrow">{note.label}</span>
      <p>{note.copy}</p>
    </div>
  );
}

export function OverviewIntro() {
  return (
    <section className="c-intro" aria-labelledby="agreement-title">
      <div className="c-intro-copy">
        <p className="c-eyebrow">THE PROBLEM WITH MANAGED LIQUIDITY</p>
        <h2 id="agreement-title">
          Their range choice.
          <br />
          <span>Your price exposure.</span>
        </h2>
        <p>
          A managed vault can change your exposure to ETH through its range
          choices. Its returns can reflect that exposure rather than better
          market making. Depositors carry a risk they never chose.
        </p>
        <div className="c-solution">
          <p className="c-eyebrow">HOW CHARTER SOLVES IT</p>
          <h3>Make the manager owe passive + rent.</h3>
          <p>
            Managers lease your liquidity, pay rent and post a bond. They owe
            the full-range passive result, wherever they set their range. They
            keep gains above that obligation; their bond covers shortfalls. The
            hook checks each swap and closes leases that can no longer cover
            what they owe.
          </p>
        </div>
        <Link className="c-action-link" href="/deposit">
          Supply capital <span aria-hidden="true">↗</span>
        </Link>
      </div>
      <aside className="c-agreement" aria-label="The Charter agreement">
        <p className="c-eyebrow">THE DEPOSITOR&apos;S CLAIM</p>
        <strong>
          Passive result <span>+ rent</span>
        </strong>
        <dl>
          <div>
            <dt>Who runs the range</dt>
            <dd>The manager</dd>
          </div>
          <div>
            <dt>What covers a shortfall</dt>
            <dd>Their bond</dd>
          </div>
          <div>
            <dt>Where unleased capital sits</dt>
            <dd>Full range</dd>
          </div>
        </dl>
        <p className="c-agreement-foot">
          Managers run the strategy. The passive benchmark defines what they
          owe.
        </p>
        <a className="c-study-link" href="#vault-study">
          Why this design? Read the four-vault study{" "}
          <span aria-hidden="true">↓</span>
        </a>
      </aside>
      <nav className="c-journey" aria-label="Follow the capital">
        <span>FOLLOW THE CAPITAL</span>
        {[
          ["01", "/deposit", "Supply", "Receive LP shares"],
          ["02", "/leases", "Lease", "Compare rental offers"],
          ["03", "/manager", "Monitor", "Watch bond coverage"],
          ["04", "/activity", "Verify", "Read the onchain record"],
        ].map(([number, href, label, detail]) => (
          <Link key={href} href={href}>
            <span>{number}</span>
            <div>
              <b>{label}</b>
              <small>{detail}</small>
            </div>
            <i aria-hidden="true">↗</i>
          </Link>
        ))}
      </nav>
    </section>
  );
}
