# Self-Hosted VPN Server on AWS (CloudFormation + WireGuard / OpenVPN)

A portfolio project demonstrating infrastructure design, IaC, security architecture, and troubleshooting skills.  
Built a personal VPN server on AWS from scratch — covering **technology comparison, cost analysis, security design, and incident investigation**, all done independently.

| Item | Details |
|---|---|
| Build period | May–June 2026 (~1.5 months) |
| Monthly cost | Very low (EC2 t4g.nano + GuardDuty, etc.) — exact figures omitted as pricing varies |
| VPN clients | PC (Windows), Smartphone (Android / iOS) |
| AWS Region | ap-northeast-1 (Tokyo) |

---

## Background & AI Usage Policy

### Why I Built This

When my security software subscription came up for renewal, I decided to build and manage my own VPN server instead.  
The goal was to apply Linux knowledge from LinuC Level 1 & 2 certification, together with server-building skills I had studied on my own, in a real-world project — and to create a tangible demonstration of how far I can go on my own design and implementation.

### How I Used AI (Claude Code)

> I did not let AI build everything. Instead, I had Claude Code generate step-by-step procedures, then executed each step myself.

| Responsibility | Owner |
|---|---|
| Architecture design & technology selection | **Me** |
| Security design (Security Groups, IAM, SSM) | **Me** |
| CloudFormation template design decisions | **Me** |
| Root cause investigation & error analysis | **Me** |
| Drafting procedures & supplementing technical info | Claude Code |
| Information gathering support during troubleshooting | Claude Code |

**Verification of AI output:** Every technical claim from Claude Code was validated against official documentation (AWS, OpenVPN, WireGuard, etc.) before adoption.  
Each troubleshooting case in `docs/troubleshooting.md` includes source documentation and citations for this reason.

---

## Architecture

```
[Client (PC / Smartphone)]
         │
         │  WireGuard (UDP 51820)  ← primary
         │  OpenVPN  (TCP 443)     ← fallback (corporate networks, strict firewalls)
         ▼
┌─────────────────────────────────────┐
│  AWS ap-northeast-1 (Tokyo)         │
│                                     │
│  ┌──────────────────────────────┐  │
│  │  VPC 10.0.0.0/16             │  │
│  │                              │  │
│  │  ┌────────────────────────┐ │  │
│  │  │  EC2 t4g.nano           │ │  │
│  │  │  Amazon Linux 2023      │ │  │
│  │  │                        │ │  │
│  │  │  wg0  : 10.8.0.1/24   │ │  │
│  │  │  tun0 : 10.9.0.1/24   │ │  │
│  │  │                        │ │  │
│  │  │  ├ firewalld (nftables)│ │  │
│  │  │  │   masquerade (SNAT) │ │  │
│  │  │  │   forward           │ │  │
│  │  │  ├ fail2ban            │ │  │
│  │  │  └ SSM Agent           │ │  │
│  │  └────────────────────────┘ │  │
│  │                              │  │
│  │  Security Group              │  │
│  │  ├ UDP 51820 (WireGuard)    │  │
│  │  ├ TCP 443  (OpenVPN)       │  │
│  │  └ SSH 22  → closed         │  │
│  └──────────────────────────────┘  │
│                                     │
│  GuardDuty (threat detection)       │
│  CloudWatch (monitoring & alarms)   │
│  SSM Session Manager (ops access)   │
└─────────────────────────────────────┘
         │
         ▼
    [Internet Gateway]
         │
         ▼
      [Internet]
```

---

## Tech Stack

| Category | Technology |
|---|---|
| IaC | AWS CloudFormation (multi-stack) |
| Cloud | Amazon EC2 (t4g.nano / ARM64), VPC, Security Group, Elastic IP, IAM |
| VPN protocols | WireGuard, OpenVPN |
| OS / Middleware | Amazon Linux 2023, firewalld (nftables backend), fail2ban, easy-rsa |
| Security | AWS GuardDuty, AWS SSM Session Manager, PKI (self-managed CA) |
| Monitoring | AWS CloudWatch Alarms (CPU, status check, failed login attempts) |

---

## Key Design Decisions

### 1. No SSH Port 22 Open

All operational access to EC2 is handled exclusively through **AWS Systems Manager (SSM) Session Manager**.  
SSM establishes shell sessions without opening any ports, fundamentally eliminating unauthorized SSH attempts from the internet.  
fail2ban is also deployed as an additional defense-in-depth layer.

### 2. WireGuard + OpenVPN Hybrid

| Item | WireGuard (primary) | OpenVPN (fallback) |
|---|---|---|
| Protocol / Port | UDP 51820 | TCP 443 (same port as HTTPS) |
| Speed | Fast, low latency | Slightly slower (TCP overhead) |
| Use case | Normal browsing / daily use | Corporate networks, strict firewall environments |

Because OpenVPN here uses TCP 443 (the same port as HTTPS), it tends to pass through restrictive firewalls where WireGuard (UDP) is blocked.

### 3. CloudFormation Multi-Stack Design

```
01_vpc.yaml        → VPC, subnets, IGW (network foundation)
02_iam.yaml        → IAM role, instance profile
03_security.yaml   → Security Group (port rules)
04_ec2.yaml        → EC2, Elastic IP, user_data (automated VPN setup)
05_monitoring.yaml → CloudWatch alarms, SNS notification
```

Splitting stacks allows independent changes — e.g., "rebuild only EC2" or "modify SG only" — without touching the rest.  
Dependencies are managed via `Outputs` → `Parameters` cross-stack references.

### 4. EC2 Self-Hosted vs AWS Client VPN

| Comparison | EC2 Self-Hosted | AWS Client VPN |
|---|---|---|
| Monthly cost scale | **Very low** | **High** (endpoint + per-connection charges run continuously) |
| Protocol support | WireGuard + OpenVPN | OpenVPN only |
| Customization | Full control | Limited options |

> Cost scale: Very low < Low < Medium < High. Exact figures are intentionally omitted, as AWS pricing varies by date, region, usage, and conditions — see each service's official pricing page.

Selected EC2 self-hosted for cost efficiency and protocol flexibility.

### 5. Firewall Design (firewalld / nftables)

The OS-level firewall controls **NAT (MASQUERADE) and FORWARD** rules.  
AWS Security Groups handle port allow/deny only — IP forwarding and NAT require OS-level firewall configuration.

```
Client → [EC2 wg0 ingress] → [firewalld FORWARD chain] → [firewalld POSTROUTING: MASQUERADE] → Internet
```

Both `FORWARD` and `POSTROUTING (MASQUERADE)` must be configured; missing either breaks routing.  
Note: Amazon Linux 2023 uses the nftables backend, so `iptables -L` counters are not reliable indicators.

---

## Troubleshooting Highlights

Full details in [docs/troubleshooting.md](docs/troubleshooting.md).

### Case: VPN Connected but No Internet Access

**Symptom:** WireGuard connection established; ping from phone reaches EC2; browser cannot reach external sites.

**Investigation:** `sysctl` (OK) → `firewall-cmd --list-all` (looked OK) → `firewall-cmd --get-active-zones` (**empty**) ← root cause identified

**Root cause:** The EC2 NIC (ens5) was not assigned to any firewalld zone. Masquerade rules existed but were not applied to any interface. `iptables -L` counters showed 0 because AL2023 uses the nftables backend.

**Fix:** Explicitly assigned the NIC to the public zone in `user_data`.

---

### Case: wg-quick PostUp Command Concatenation on Line Continuation

**Symptom:** `Line unrecognized: firewall-cmd--zone=public--add-forward--permanent;`

**Root cause:** wg-quick removes spaces when joining lines with `\`, concatenating `firewall-cmd` and `--zone` into an unrecognized token.

**Fix:** Removed the `\` line continuation and wrote all commands on a single line separated by `;`.

---

### Case: CloudFormation Re-deploy `CREATE_FAILED` (S3 Bucket Name Conflict)

**Symptom:** After deleting and redeploying the monitoring stack: `personal-vpn-cloudtrail-<MASKED> already exists` → `ROLLBACK_COMPLETE`.

**Root cause:** An S3 bucket with `DeletionPolicy: Retain` persists after stack deletion. Re-deploy attempts to create a bucket with the same name, causing a conflict.

**Investigation:** CloudFormation → target stack → Events tab → `CREATE_FAILED` row → Reason column.

**Fix:** Deleted remaining bucket objects → deleted the bucket → re-deployed the stack.

---

## Documentation

| File | Contents |
|---|---|
| [docs/design_overview.md](docs/design_overview.md) | Architecture, security design, technology selection rationale (**read first**) |
| [docs/architecture_diagram.md](docs/architecture_diagram.md) | System architecture, CloudFormation stacks, and traffic flow (Mermaid diagrams) |
| [docs/basic_design.md](docs/basic_design.md) | Requirements, overall structure, network design details |
| [docs/detailed_design.md](docs/detailed_design.md) | Component-level design (VPC / EC2 / SG / monitoring) |
| [docs/wireguard_openvpn_setup.md](docs/wireguard_openvpn_setup.md) | AWS infrastructure setup + VPN configuration key points |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Incidents encountered during the build and root cause analysis |

---

## Skills Demonstrated

- **CloudFormation**: Infrastructure as Code, multi-stack design, cross-stack dependency management
- **VPN protocols**: WireGuard / OpenVPN internals, use case differentiation
- **Linux firewall**: iptables / nftables / firewalld architecture and design
- **PKI**: Self-managed CA using easy-rsa (CA cert, server cert, client certs)
- **AWS Security**: GuardDuty, SSM Session Manager, Security Group layering
- **OS-level troubleshooting**: firewalld zone assignment, nftables backend behavior, iptables counter interpretation
- **End-to-end ownership**: Design → Build → Operate → Incident response → Documentation, entirely solo

---

> **Note:** This repository contains no private keys, client configuration files, or actual IP addresses.
