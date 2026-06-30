# Design Overview

---

## 1. Design Principles

| Principle | Approach | Rationale |
|---|---|---|
| Least privilege | Grant only the required ports and permissions | Minimize the attack surface |
| Infrastructure as Code | Manage all resources with CloudFormation | Reproducibility, change tracking, prevention of manual errors |
| No SSH | Connect via SSM Session Manager | Exposing the SSH port invites brute-force attacks |
| Redundant protocols | Both WireGuard and OpenVPN | Stay connectable even if one is blocked |
| Cost optimization | t4g.nano + Graviton2 (ARM) | Lower cost than equivalent x86 instances |

---

## 2. Network Design

```
VPC: 10.0.0.0/16
└── Public subnet: 10.0.1.0/24
    └── EC2 (VPN server) + Elastic IP (static public IP)
```

| VPN protocol | Server IP | Client IP range |
|---|---|---|
| WireGuard | 10.8.0.1 | 10.8.0.2–254 |
| OpenVPN | 10.9.0.1 | 10.9.0.2–254 |

---

## 3. Security Design

### 3.1 Defense-in-Depth Layers

```
Internet
    │
    ▼
[AWS Security Group]
    ├─ UDP 51820 (WireGuard): allow
    ├─ TCP 443 (OpenVPN): allow
    └─ TCP 22 (SSH): closed ← replaced by SSM
    │
    ▼
[EC2 OS - firewalld (nftables backend)]
    ├─ MASQUERADE (rewrite VPN client source IP)
    ├─ FORWARD (wg0 → ens5 inter-interface forwarding)
    └─ fail2ban (brute-force prevention)
    │
    ▼
[AWS GuardDuty]
    └─ Analyzes VPC Flow Logs / CloudTrail for threats
```

### 3.2 Security Group vs OS Firewall — Division of Roles

| Capability | Security Group | firewalld (OS) |
|---|---|---|
| Allow inbound on specific ports | ✅ | ✅ |
| MASQUERADE (source IP rewrite) | ❌ not possible | ✅ |
| FORWARD (inter-interface forwarding) | ❌ not possible | ✅ |
| Dynamic IP blocking via fail2ban | ❌ not possible | ✅ |

Running as a VPN server requires MASQUERADE and FORWARD. A Security Group cannot provide these, so an OS-level firewall is required.

### 3.3 Packet Processing Flow (FORWARD and MASQUERADE)

```
Received on wg0 (from VPN client)
    │
    ▼
PREROUTING (nat table)
    │
    ▼
Routing decision
    │
    ▼ destined for outside
FORWARD chain (filter table) ← if DROPped here, the packet goes no further
    │
    ▼ only if allowed
POSTROUTING (nat table) ← MASQUERADE (IP rewrite) happens here
    │
    ▼
Sent out via ens5 → Internet
```

If FORWARD is not allowed, packets never reach MASQUERADE. Both must be configured.

### 3.4 Why the Security Group Source IP is 0.0.0.0/0

Setting the inbound source for the VPN ports (UDP 51820 / TCP 443) to `0.0.0.0/0` is a deliberate design choice.

**Why no IP restriction:**

A VPN exists to let you connect from anywhere — while traveling, on a phone, from a hotel, etc. The source IP changes every time, so restricting by IP would make the VPN itself unusable. Security is enforced by **cryptographic authentication**, not by IP restriction.

| Protocol | Authentication | Why 0.0.0.0/0 is still safe |
|---|---|---|
| WireGuard (UDP 51820) | Public-key cryptography (Curve25519) | Without the correct private key, no VPN session can be established. WireGuard also **does not respond at all** to unauthenticated packets (to a port scanner the port appears not to exist) |
| OpenVPN (TCP 443) | PKI client certificate + ta.key | Without the certificate and ta.key, the connection is rejected at the TLS handshake stage |

> **Reference**: [Protocol & Cryptography - WireGuard](https://www.wireguard.com/protocol/)
>
> **Excerpt**
> "the server does not even respond at all to an unauthorized client; it is silent and invisible."

**When IP restriction does make sense (not applicable here):**  
When the source is limited to a fixed IP (e.g., a site-to-site VPN connecting only from a specific office). For a personal full-tunnel VPN, 0.0.0.0/0 is the correct choice.

---

## 4. CloudFormation Stack Layout

```
01_vpc.yaml          → VPC, subnet, IGW, route table
02_iam.yaml          → IAM role / instance profile for SSM
03_security.yaml     → Security Group (inbound: UDP 51820, TCP 443 only; no SSH 22)
04_ec2.yaml          → EC2, Elastic IP, user_data (full automated VPN setup)
05_monitoring.yaml   → CloudWatch alarms, SNS notifications, GuardDuty enablement
```

Inter-stack dependencies are passed via `Outputs` → `Parameters`. Re-deploying only the EC2 stack does not affect the VPC or SG.

---

## 5. VPN Protocol Comparison and Selection

### WireGuard vs OpenVPN

| Aspect | WireGuard | OpenVPN (TCP 443) |
|---|---|---|
| Speed | Fast, low latency | Slightly slower (TCP overhead) |
| Configuration complexity | Simple (public keys only) | More involved (PKI certificates needed) |
| Ease of passing firewalls | Harder where UDP is blocked | Passes more easily (TCP 443) |
| Security | Modern cryptography (Curve25519, etc.) | Proven track record |

**Adopted approach:** Use WireGuard normally, and fall back to OpenVPN (TCP 443) where UDP is blocked.

### EC2 Self-Hosted vs AWS Client VPN

| Comparison | EC2 self-hosted | AWS Client VPN |
|---|---|---|
| Monthly cost scale | **Very low** | **High** (overkill pricing for personal use) |
| Protocols | WireGuard + OpenVPN | OpenVPN only |
| Customization | Full control | Constrained |

> Cost scale: Very low < Low < Medium < High. Exact amounts are intentionally omitted, as they vary by time and conditions (check each official pricing page).

For personal use (1–3 client devices), AWS Client VPN's pricing model does not fit, so EC2 self-hosting was selected.

---

## 6. EC2 Configuration

| Item | Choice | Rationale |
|---|---|---|
| Instance type | t4g.nano (ARM / Graviton2) | Sufficient for a personal VPN; lower cost than x86 |
| OS | Amazon Linux 2023 | SSM Agent pre-installed; RHEL-family learning value |
| Storage | gp3 20GB (encrypted) | Latest-gen SSD; encryption required for data protection |
| Public IP | Elastic IP (static) | IP stays the same across server restarts |
| SSH key pair | Created in ed25519 format (for emergencies) | Normally connect only via SSM Session Manager; the SSH port is closed and unused in practice. ed25519 uses a shorter key than RSA while providing strong, modern security |

---

## 7. Monitoring Design

| Service | Target | Threshold / content |
|---|---|---|
| CloudWatch Alarm | CPU utilization | Alarm when >85% (sustained 5 min) |
| CloudWatch Alarm | Status check | Alarm after 3 consecutive failures |
| GuardDuty | VPC Flow Logs / CloudTrail | Detects suspicious traffic and possible credential compromise |
| SNS | On alarm | Email notification |
