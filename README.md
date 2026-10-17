# Postfix Mail Tester

One script that answers "is my mail server actually healthy?" — aimed at the
Postfix setups most of us run on a VPS, but the network/DNS checks work for
any SMTP host.

## What it checks

| # | Check | Why it matters |
|---|---|---|
| 1 | Port 25 reachable + banner | blocked port = no inbound mail |
| 2 | Port 587 reachable + STARTTLS advertised | clients need a sane submission path |
| 3 | Reverse DNS (PTR) for the server IP | missing PTR → rejects / spam folder |
| 4 | SPF record for `--from-domain` | without it, receivers distrust you |
| 5 | DKIM selector + DMARC record | deliverability + spoof protection |
| 6 | postfix running, queue size, `reject_unauth_destination` (open-relay check), `smtpd_tls_security_level` | local sanity |
| 7 | Optional `--send` probe via `sendmail` | proves outbound delivery end-to-end |

Each line prints `PASS`, `WARN` or `FAIL`. Exit code is `1` if anything
failed, `2` on bad usage — CI-friendly.

## Usage

```bash
chmod +x mail-test.sh

# read-only audit (no mail sent)
./mail-test.sh --from-domain example.com

# probe a different MX host, custom DKIM selector
./mail-test.sh --from-domain example.com --smtp mail.example.com \
               --dkim-selector mail

# end-to-end: actually send a test message
./mail-test.sh --from-domain example.com --send --to you@gmail.com

# quiet mode for cron (only WARN/FAIL + summary)
./mail-test.sh --from-domain example.com --quiet
```

## Notes

- Checks 1–2 use bash's built-in `/dev/tcp` — no `nc`/`telnet` needed.
- Checks 3–5 need `dig` (package `dnsutils` / `bind-utils`).
- The PTR check resolves the **probed host's** A record, not your outbound
  IP — if they differ, verify the outbound IP's PTR separately.
- The `--send` test sends from `mailtest@<from-domain>`; the SPF record must
  authorise the server or the message may land in spam — which is itself a
  useful signal.

MIT licensed.
