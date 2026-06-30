# Architecture Diagrams

> These diagrams are written in **Mermaid**. GitHub renders them automatically as diagrams, so no image files are needed (in a local editor you can preview them with a VS Code extension).

---

## 1. Overall Architecture

```mermaid
flowchart TB
    subgraph clients["Client devices"]
        PC["PC (Windows)"]
        SP["Smartphone (Android / iOS)"]
    end

    NET["Internet"]

    subgraph aws["AWS ap-northeast-1 (Tokyo region)"]
        IGW["Internet Gateway"]

        subgraph vpc["VPC 10.0.0.0/16"]
            SG["Security Group<br/>Allow UDP 51820 / TCP 443<br/>SSH(22) closed"]
            subgraph subnet["Public subnet"]
                EC2["EC2 t4g.nano<br/>Amazon Linux 2023<br/>wg0 : 10.8.0.1/24 (WireGuard)<br/>tun0 : 10.9.0.1/24 (OpenVPN)<br/>firewalld / fail2ban / SSM Agent"]
            end
        end

        subgraph monitor["Monitoring & Security"]
            GD["GuardDuty<br/>Threat detection"]
            CW["CloudWatch Alarms<br/>CPU / traffic / health"]
            CT["CloudTrail → S3<br/>Audit log storage"]
            SNS["SNS → Email notification"]
        end

        SSM["SSM Session Manager<br/>Ops access without open ports"]
    end

    PC -->|"WireGuard UDP 51820"| IGW
    SP -->|"OpenVPN TCP 443"| IGW
    IGW --> SG --> EC2
    EC2 -->|"Relays via NAT"| IGW --> NET

    EC2 -. metrics .-> CW
    EC2 -. logs .-> CT
    CW --> SNS
    GD --> SNS
    SSM -. connect without SSH .-> EC2
```

**Key points**

- All client traffic is aggregated at EC2, which relays it to the Internet on the client's behalf (full tunnel).
- WireGuard (UDP 51820) is used normally; where UDP is blocked, it falls back to OpenVPN (TCP 443).
- SSH(22) is never opened; operations go exclusively through SSM Session Manager.

---

## 2. CloudFormation Stack Layout (Dependencies)

```mermaid
flowchart LR
    S1["01_vpc<br/>VPC / subnet / IGW"]
    S2["02_iam<br/>IAM role / profile"]
    S3["03_security<br/>Security Group"]
    S4["04_ec2<br/>EC2 / Elastic IP / user_data"]
    S5["05_monitoring<br/>CloudWatch / SNS / Budgets"]

    S1 --> S3
    S1 --> S4
    S2 --> S4
    S3 --> S4
    S4 --> S5
```

**Key points**

- Split into 5 stacks so that "rebuild only EC2" or "change only the SG" can be done independently.
- Cross-stack values (VpcId, SubnetId, SecurityGroupId, etc.) are passed via `Outputs` → `Parameters`.

---

## 3. Traffic Flow (How a Packet Reaches the Internet)

```mermaid
flowchart LR
    C["Client"] -->|"encrypted traffic"| W["EC2<br/>received on wg0 / tun0"]
    W --> F["firewalld<br/>FORWARD allowed"]
    F --> M["firewalld<br/>MASQUERADE (NAT)"]
    M --> I["Internet"]
```

**Key points**

- If `FORWARD` is not allowed, packets never reach `MASQUERADE`, so both must be configured.
- Amazon Linux 2023 uses firewalld's nftables backend, so `iptables -L` counters are not reliable indicators.
