#!/usr/bin/env bash
#
# mail-test.sh — quick health check for a Postfix (or any SMTP) mail server.
#
# Checks:
#   * SMTP connectivity on port 25 (+ banner grab)
#   * submission port 587 (+ STARTTLS advertisement)
#   * reverse DNS (PTR) for the server IP
#   * SPF, DKIM (configurable selector) and DMARC records for --from-domain
#   * local postfix sanity: service running, queue size, open-relay check,
#     smtpd_tls_security_level
#   * optional: send a real test message via sendmail (--send --to addr)
#
# Usage:
#   mail-test.sh --from-domain example.com [--smtp mail.example.com]
#                [--dkim-selector default] [--send --to you@gmail.com] [--quiet]
#
# Exit code: 0 when no FAIL, 1 when any check failed, 2 on bad usage.
#
set -euo pipefail

FROM_DOMAIN=""
SMTP_HOST=""
DKIM_SELECTOR="default"
SEND=0
TO=""
QUIET=0
FAILURES=0

usage() {
	cat <<'EOF'
Usage: mail-test.sh --from-domain example.com [options]

  --from-domain DOMAIN   domain used in From: / envelope sender (required)
  --smtp HOST            SMTP host to probe (default: mail.<from-domain>)
  --dkim-selector NAME   DKIM selector to look up (default: default)
  --send                 actually send a test message (needs --to)
  --to ADDRESS           recipient for the --send test
  --quiet                only print WARN/FAIL lines and the summary
  -h, --help             show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--from-domain)   FROM_DOMAIN="$2"; shift 2 ;;
		--smtp)          SMTP_HOST="$2"; shift 2 ;;
		--dkim-selector) DKIM_SELECTOR="$2"; shift 2 ;;
		--send)          SEND=1; shift ;;
		--to)            TO="$2"; shift 2 ;;
		--quiet)         QUIET=1; shift ;;
		-h|--help)       usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[[ -z "$FROM_DOMAIN" ]] && { echo "error: --from-domain is required" >&2; usage >&2; exit 2; }
[[ -z "$SMTP_HOST" ]]   && SMTP_HOST="mail.${FROM_DOMAIN}"

pass() { [[ $QUIET -eq 0 ]] && printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Grab the SMTP greeting banner over a raw TCP connection (bash /dev/tcp).
banner() { # host port
	timeout 8 bash -c 'exec 3<>/dev/tcp/'"$1"'/'"$2"'; head -c 512 <&3; exec 3>&-' 2>/dev/null \
		| tr -d '\r' | head -1
}

# --- 1. Port 25 -----------------------------------------------------------
if B=$(banner "$SMTP_HOST" 25); then
	pass "SMTP port 25 reachable on $SMTP_HOST — ${B:0:80}"
else
	fail "SMTP port 25 NOT reachable on $SMTP_HOST (port blocked? postfix down?)"
fi

# --- 2. Port 587 + STARTTLS ----------------------------------------------
if B=$(banner "$SMTP_HOST" 587); then
	pass "Submission port 587 reachable — ${B:0:80}"
	EHLO=$(timeout 8 bash -c 'exec 3<>/dev/tcp/'"$SMTP_HOST"'/587; head -c 256 <&3 >/dev/null; echo "EHLO mailtest" >&3; head -c 2048 <&3' 2>/dev/null | tr -d '\r' || true)
	if grep -qi 'STARTTLS' <<<"$EHLO"; then
		pass "STARTTLS advertised on 587"
	else
		warn "STARTTLS not advertised on 587"
	fi
else
	warn "Port 587 not reachable on $SMTP_HOST"
fi

# --- 3. Reverse DNS + SPF / DKIM / DMARC -----------------------------------
if command -v dig >/dev/null 2>&1; then
	MXIP=$(dig +short "$SMTP_HOST" A | head -1)
	if [[ -n "$MXIP" ]]; then
		PTR=$(dig +short -x "$MXIP" | head -1)
		if [[ -n "$PTR" ]]; then
			pass "PTR for $MXIP → $PTR"
		else
			fail "No PTR (reverse DNS) for $MXIP — many providers will reject or spam-folder your mail"
		fi
	else
		warn "Could not resolve A record for $SMTP_HOST"
	fi

	SPF=$(dig +short "$FROM_DOMAIN" TXT | grep -i 'v=spf1' | head -1 || true)
	if [[ -n "$SPF" ]]; then
		pass "SPF: ${SPF:0:100}"
	else
		fail "No SPF record for $FROM_DOMAIN"
	fi

	DMARC=$(dig +short "_dmarc.$FROM_DOMAIN" TXT | head -1 || true)
	if [[ -n "$DMARC" ]]; then
		pass "DMARC: ${DMARC:0:100}"
	else
		warn "No DMARC record for $FROM_DOMAIN (recommended: v=DMARC1; p=none to start)"
	fi

	DKIM=$(dig +short "${DKIM_SELECTOR}._domainkey.${FROM_DOMAIN}" TXT | head -1 || true)
	if [[ -n "$DKIM" ]]; then
		pass "DKIM selector '$DKIM_SELECTOR' published"
	else
		warn "No DKIM TXT at ${DKIM_SELECTOR}._domainkey.${FROM_DOMAIN}"
	fi
else
	warn "dig not installed — skipping DNS checks"
fi

# --- 4. Local postfix sanity (only when postfix is installed) -------------
if command -v postconf >/dev/null 2>&1; then
	if systemctl is-active --quiet postfix 2>/dev/null || pgrep -x master >/dev/null 2>&1; then
		pass "postfix service is running"
	else
		fail "postfix installed but not running"
	fi

	Q=$(mailq 2>/dev/null | grep -cE '^[A-F0-9]{10,}' || true)
	if [[ "$Q" -eq 0 ]]; then
		pass "mail queue empty"
	else
		warn "mail queue has $Q message(s) — inspect with 'mailq'"
	fi

	RESTRICTIONS=$(postconf -h smtpd_recipient_restrictions 2>/dev/null || true)
	if grep -q 'reject_unauth_destination' <<<"$RESTRICTIONS"; then
		pass "smtpd_recipient_restrictions includes reject_unauth_destination (not an open relay)"
	else
		fail "smtpd_recipient_restrictions missing reject_unauth_destination — possible OPEN RELAY"
	fi

	TLS=$(postconf -h smtpd_tls_security_level 2>/dev/null || true)
	if [[ "$TLS" == "may" || "$TLS" == "encrypt" ]]; then
		pass "smtpd_tls_security_level=$TLS"
	else
		warn "smtpd_tls_security_level='$TLS' (consider 'may')"
	fi
else
	warn "postfix not installed locally — skipping local checks"
fi

# --- 5. Optional live send test -------------------------------------------
if [[ $SEND -eq 1 ]]; then
	[[ -z "$TO" ]] && { echo "error: --send needs --to" >&2; exit 2; }
	if command -v sendmail >/dev/null 2>&1; then
		{
			echo "From: mailtest <mailtest@${FROM_DOMAIN}>"
			echo "To: $TO"
			echo "Subject: mail-test.sh probe $(date -u +%FT%TZ)"
			echo
			echo "If you can read this, outbound mail from ${SMTP_HOST} works."
		} | sendmail -t \
			&& pass "test message accepted by local MTA (check $TO inbox/spam)" \
			|| fail "sendmail rejected the test message"
	else
		warn "sendmail not found — cannot send test message"
	fi
fi

# --- Summary ---------------------------------------------------------------
[[ $QUIET -eq 0 ]] && echo '----'
if [[ $FAILURES -gt 0 ]]; then
	echo "$FAILURES check(s) FAILED"
	exit 1
fi
echo "All checks passed."
