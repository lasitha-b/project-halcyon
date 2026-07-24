# Halcyon Logistics — Engagement Brief

You have been engaged to perform an internal penetration test against Halcyon
Logistics' corporate network. Scope, rules, and starting information below.

## Scope

- Halcyon's internal corporate network `10.20.10.0/24` is the objective, along
  with anything you must traverse to reach it.
- You are positioned **outside** the corporate perimeter, on the external
  segment `192.168.50.0/24`. Halcyon's edge firewall sits between you and
  everything else — it exposes exactly one service to the outside, and blocks
  direct access to the internal network. You will have to work through what it
  *does* expose.
- Windows Defender is running on all Windows hosts. It is not disabled for
  you. Plan accordingly.

## Starting point

You have been given external network access only — no credentials, no internal
documentation. Your attack box sits at `192.168.50.66`. The one thing you were
told: Halcyon publishes an internet-facing operations intranet at
`http://intranet.halcyon.local`. From the outside it resolves to the firewall's
public address `192.168.50.254` (add `192.168.50.254  intranet.halcyon.local` to
your `/etc/hosts`). That web app is your only way in — direct connections to the
internal `10.20.10.0/24` hosts are dropped at the edge, so expect to gain a
foothold on the web tier first and pivot inward from there.

## Objectives

Work toward increasing levels of access. Each milestone below has a proof
token to submit:

1. **Web foothold** — achieve code execution on the web server.
2. **Linux root** — escalate to root on the web server.
3. **First domain credential** — obtain a working Active Directory credential
   (of any kind: password, hash, or ticket) for any domain principal.
4. **Privilege escalation** — obtain local administrator access on an internal
   Windows client.
5. **Domain Admin** — obtain Domain Admin equivalent access (a successful
   DCSync of `krbtgt` is sufficient proof on its own).

There is more than one way to reach several of these milestones. Not every
technique you find will lead anywhere real — some leads are genuine dead
ends, same as in a real engagement.

## Rules of engagement

- Stay inside the lab's networks (external `192.168.50.0/24`, DMZ
  `172.20.1.0/24`, and internal `10.20.10.0/24`). Do not attempt to bridge,
  route, or pivot traffic to any network outside the lab itself. Pivoting
  *between* the lab's own segments — which is the whole point — is fair game.
- Standard pentest tooling is expected and allowed (BloodHound, Impacket,
  Certipy, Rubeus, mimikatz, sqlmap, ffuf, etc.) — this lab assumes their use.
- Have fun, and document your path as you go — the answer key you'll compare
  against afterward records the *intended* paths, not necessarily the only
  ones.
