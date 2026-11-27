import {
  replay,
  replayTitle,
  replayNote,
  replayFindings,
  replaySource,
} from "@/data/evidence";
import { percent } from "@/lib/format";

const signed = (n: number) => `${n > 0 ? "+" : ""}${percent(n)}`;

export function VaultReplay() {
  return (
    <section
      className="c-replay"
      id="vault-replay"
      aria-labelledby="vault-replay-title"
    >
      <div className="c-panel-heading">
        <div>
          <p className="c-eyebrow">HISTORICAL REPLAY / BLOCK BY BLOCK</p>
          <h2 id="vault-replay-title">{replayTitle}</h2>
        </div>
        <span className="c-replay-model">MODEL / NOT A LIVE RESULT</span>
      </div>
      <p className="c-replay-note">{replayNote}</p>
      <table
        className="c-replay-table"
        role="table"
        aria-describedby="replay-terms replay-source"
      >
        <caption id="replay-terms">
          Depositor returns versus passive. Manager loss and uncovered amounts
          are percentages of capital. The base case has 0% rent.
        </caption>
        <thead role="rowgroup">
          <tr role="row">
            <th scope="col" role="columnheader">
              Vault / lease closed
            </th>
            <th scope="col" role="columnheader">
              As it ran
            </th>
            <th scope="col" role="columnheader">
              Charter / 0% rent
            </th>
            <th scope="col" role="columnheader">
              Charter / 5% rent
            </th>
            <th scope="col" role="columnheader">
              Manager loss
            </th>
            <th scope="col" role="columnheader">
              Uncovered
            </th>
          </tr>
        </thead>
        <tbody role="rowgroup">
          {replay.map((row) => (
            <tr key={row.vault} role="row">
              <th scope="row" role="rowheader">
                <b>{row.vault}</b>
                <small>Lease closed on day {row.closedDay}</small>
              </th>
              <td role="cell" className="c-replay-before">
                <span className="c-replay-mobile-label" aria-hidden="true">
                  As it ran
                </span>
                <strong
                  className={
                    row.actualVsPassive < 0 ? "c-replay-loss" : "c-replay-gain"
                  }
                >
                  {signed(row.actualVsPassive)}
                </strong>
              </td>
              <td role="cell" className="c-replay-passive">
                <span className="c-replay-mobile-label" aria-hidden="true">
                  Charter / 0% rent
                </span>
                <strong>{percent(row.charterVsPassive)}</strong>
                <small>Passive</small>
              </td>
              <td role="cell" className="c-replay-detail">
                <span className="c-replay-mobile-label" aria-hidden="true">
                  Charter / 5% rent
                </span>
                <span>{signed(row.charterWithRent)}</span>
              </td>
              <td role="cell" className="c-replay-detail">
                <span className="c-replay-mobile-label" aria-hidden="true">
                  Manager loss
                </span>
                <span>{percent(row.managerLoss)}</span>
              </td>
              <td role="cell" className="c-replay-detail">
                <span className="c-replay-mobile-label" aria-hidden="true">
                  Uncovered
                </span>
                <span>{percent(row.uncovered)}</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p id="replay-source" className="c-replay-source">
        {replaySource}
      </p>
      <p className="c-replay-tradeoff">
        The trade-off is visible in Vault 0x5763: its depositors&apos; +12.90%
        versus passive also becomes passive. The bond covers shortfalls;
        depositors give up the upside above their claim too.
      </p>
      <div className="c-replay-findings">
        <h3>What the replay tested</h3>
        <ul>
          {replayFindings.map((finding) => (
            <li key={finding}>{finding}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}
