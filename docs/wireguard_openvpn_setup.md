# WireGuard / OpenVPN Setup Overview

> **Note:** IP addresses and private keys are masked with placeholder values.  
> The server IP is shown as `<EC2-ELASTIC-IP>`, and client settings as `<CLIENT-PRIVATE-KEY>` / `<SERVER-PUBLIC-KEY>`.

---

## AWS Infrastructure (CloudFormation)

### Multi-Stack Layout

The AWS foundation for the VPN server is deployed as 5 CloudFormation stacks.  
Splitting stacks lets you "recreate only EC2" or "change only the SG" independently. Inter-stack dependencies (VpcId, SubnetId, SecurityGroupId, etc.) are passed via `Outputs` → `Parameters`.

```
① 01_vpc.yaml          → VPC / subnet / Internet Gateway
② 02_iam.yaml          → IAM role / EC2 instance profile
③ 03_security.yaml     → Security Group (allow UDP 51820, TCP 443, SSM only)
④ 04_ec2.yaml          → EC2 / Elastic IP association / VPN initial setup via user_data
⑤ 05_monitoring.yaml   → CloudWatch alarms / SNS email notification / Budget alarm
```

**Deploy order:** ① and ② in parallel → ③ after ① → ④ after ①②③ → ⑤ after ④

### Deployment (GUI and CLI)

> For learning, I first walked through the steps in the AWS Management Console (GUI), then moved to CLI automation.

#### GUI (AWS Management Console) Steps

Repeat the following for each stack ①–⑤ (follow the deploy order):

1. AWS console → search **CloudFormation** → **Create stack**
2. **Use a new resource (standard)** → **Upload a template file**
3. Select the target `.yaml` file → **Next**
4. Enter a stack name (e.g., `personal-vpn-vpc-stack`) → enter the previous stack's output values as parameters → **Next**
5. **Create stack** → wait until the status is **`CREATE_COMPLETE`**
6. Note the values on the **Outputs tab** (VpcId, SubnetId, etc.) and use them as parameters for the next stack

> ⚠️ The IAM stack (02_iam.yaml) shows an "I acknowledge that AWS CloudFormation might create IAM resources" checkbox. You cannot deploy without checking it.

#### CLI (AWS CLI) Deployment Commands

```powershell
# ① VPC / ② IAM can be deployed in parallel
aws cloudformation create-stack `
  --stack-name personal-vpn-vpc-stack `
  --template-body file://cfn/01_vpc.yaml `
  --region ap-northeast-1

aws cloudformation create-stack `
  --stack-name personal-vpn-iam-stack `
  --template-body file://cfn/02_iam.yaml `
  --capabilities CAPABILITY_NAMED_IAM `  # explicit acknowledgement to create IAM resources
  --region ap-northeast-1

# ④ EC2 stack (pass the outputs of ①②③ as parameters)
aws cloudformation create-stack `
  --stack-name personal-vpn-ec2-stack `
  --template-body file://cfn/04_ec2.yaml `
  --parameters `
    ParameterKey=SubnetId,ParameterValue=<SubnetId from VPC stack output> `
    ParameterKey=SecurityGroupId,ParameterValue=<SGId from SG stack output> `
    ParameterKey=InstanceProfileName,ParameterValue=personal-vpn-ec2-profile `
    ParameterKey=ExistingEipAllocationId,ParameterValue=<Elastic IP AllocationId> `
    ParameterKey=ExistingEipAddress,ParameterValue=<EC2-ELASTIC-IP> `
  --region ap-northeast-1

# ⑤ Monitoring stack (pass the EC2 InstanceId)
aws cloudformation create-stack `
  --stack-name personal-vpn-monitoring-stack `
  --template-body file://cfn/05_monitoring.yaml `
  --parameters `
    ParameterKey=AlertEmail,ParameterValue=<notification email address> `
    ParameterKey=InstanceId,ParameterValue=<InstanceId from EC2 stack output> `
  --region ap-northeast-1
```

### SNS Subscription Confirmation (Required)

After the monitoring stack deploys, an `AWS Notification - Subscription Confirmation` email is sent to the specified address.  
**CloudWatch alarm emails will not arrive unless you click the "Confirm subscription" link.**

```bash
# Check confirmation status
# AWS console → SNS → Subscriptions → Status column
# If "PendingConfirmation", you can resend via "Request confirmation"
aws sns list-subscriptions-by-topic \
  --topic-arn <SNS topic ARN> \
  --region ap-northeast-1 \
  --query 'Subscriptions[*].{Status:SubscriptionArn,Endpoint:Endpoint}'
```

### EC2 Access (SSM Session Manager)

SSH (port 22) is never opened. All access to EC2 is via **SSM Session Manager**.

```bash
# Start a shell session from the AWS CLI (no browser needed)
aws ssm start-session \
  --target <instance-id> \
  --region ap-northeast-1

# After the session opens, switch to root for VPN setup work
sudo -i
```

| Benefit | Detail |
|---|---|
| No SSH port | No need to open port 22 on the Security Group |
| Connection logs | Session history is recorded in CloudTrail / SSM logs |
| IAM control | "Who can connect" is managed via IAM policy |

---

## WireGuard Setup

### Overall Flow

```
1. Install WireGuard (on EC2)
2. Generate key pairs (server + clients)
3. Create the server config (/etc/wireguard/wg0.conf)
4. Start the service and enable on boot
5. Generate and distribute client config files
6. Import on the client device and verify the connection
```

### Key Points of the Server Config (wg0.conf)

```ini
[Interface]
Address    = 10.8.0.1/24          # server IP inside the VPN
ListenPort = 51820                 # UDP port
PrivateKey = <SERVER-PRIVATE-KEY>

# Manage firewalld zone settings via PostUp/PostDown
# WARNING: wg-quick joins lines continued with "\" by "removing the spaces."
#   Always write multiple commands on a single line separated by ";" (see troubleshooting.md Case 3)
PostUp   = firewall-cmd --zone=public --add-masquerade --permanent; firewall-cmd --zone=public --add-forward --permanent; firewall-cmd --zone=trusted --add-interface=wg0 --permanent; firewall-cmd --reload
PostDown = firewall-cmd --zone=public --remove-masquerade --permanent; firewall-cmd --zone=public --remove-forward --permanent; firewall-cmd --zone=trusted --remove-interface=wg0 --permanent; firewall-cmd --reload

[Peer]                             # client 1 (smartphone)
PublicKey  = <CLIENT1-PUBLIC-KEY>
AllowedIPs = 10.8.0.2/32

[Peer]                             # client 2 (PC)
PublicKey  = <CLIENT2-PUBLIC-KEY>
AllowedIPs = 10.8.0.3/32
```

### Generating a Client Config

```bash
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)
CLIENT_PRIVATE=$(cat /etc/wireguard/client1_private.key)

cat > /tmp/wg0-client1.conf << EOF
[Interface]
Address    = 10.8.0.2/24
DNS        = 8.8.8.8, 8.8.4.4
PrivateKey = ${CLIENT_PRIVATE}

[Peer]
PublicKey       = ${SERVER_PUBLIC}
AllowedIPs      = 0.0.0.0/0, ::/0   # full tunnel (all traffic via VPN)
Endpoint        = <EC2-ELASTIC-IP>:51820
PersistentKeepalive = 25
EOF
```

- **Smartphone:** show a QR code with `qrencode -t ansiutf8 < /tmp/wg0-client1.conf` and scan it in the app
- **PC (Windows):** transfer the file and import it in the WireGuard app

### Design Notes

| Item | Detail |
|---|---|
| AllowedIPs = 0.0.0.0/0 | Route all traffic via the VPN (full tunnel). Turning the VPN off for video streaming is recommended (mind data-transfer charges) |
| PersistentKeepalive = 25 | Periodic keepalive to maintain the connection across NAT. Important for keeping a phone connected |
| Registering the EC2 NIC to a zone | On AL2023, NetworkManager does not auto-register the NIC to a firewalld zone, so it must be added explicitly in user_data |

---

## OpenVPN Setup

### Difference from WireGuard / When to Use It

OpenVPN is configured as a fallback for environments where WireGuard cannot be used (corporate networks, countries that block UDP, strict firewall environments). Because it uses TCP 443 (the same port as HTTPS), it tends to pass through in most environments.

### Building the PKI (Certificate Authority)

OpenVPN requires client-certificate authentication. Build your own CA with easy-rsa.

```bash
# Prepare the working directory
make-cadir ~/openvpn-ca && cd ~/openvpn-ca

# Init PKI → create CA → server cert → client cert → DH params → TLS auth key
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-req server nopass
./easyrsa sign-req server server
./easyrsa gen-req client1 nopass
./easyrsa sign-req client client1
./easyrsa gen-dh                      # takes 2-5 minutes
openvpn --genkey secret ~/openvpn-ca/pki/ta.key
```

### Key Points of the Server Config (server.conf)

```conf
port  443
proto tcp
dev   tun

# certificates / keys
ca   /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key  /etc/openvpn/server/server.key
dh   /etc/openvpn/server/dh.pem
tls-auth /etc/openvpn/server/ta.key 0

# VPN internal network (dynamically assigned to clients from 10.9.0.0/24)
server 10.9.0.0 255.255.255.0

# push DNS and default route to clients (from the server)
push "dhcp-option DNS 8.8.8.8"
push "redirect-gateway def1 bypass-dhcp"

cipher AES-256-GCM
auth   SHA256
user   nobody       # drop privileges after init (least privilege)
group  nobody
persist-key
persist-tun
```

### Generating the Client Config (.ovpn)

By inlining all certificates and keys into a single file, the client is self-contained in one `.ovpn` file.

```bash
cat > /tmp/client1.ovpn << EOF
client
dev tun
proto tcp
remote <EC2-ELASTIC-IP> 443
resolv-retry infinite
nobind
cipher AES-256-GCM
auth SHA256
key-direction 1

<ca>
$(cat ~/openvpn-ca/pki/ca.crt)
</ca>
<cert>
$(cat ~/openvpn-ca/pki/issued/client1.crt)
</cert>
<key>
$(cat ~/openvpn-ca/pki/private/client1.key)
</key>
<tls-auth>
$(cat ~/openvpn-ca/pki/ta.key)
</tls-auth>
EOF
```

---

## firewalld Zone Design (Common to WireGuard / OpenVPN)

Amazon Linux 2023's firewalld uses the **nftables backend**. Because `iptables -L` does not count packets, use `firewall-cmd` to check firewalld zone settings.

```bash
# Check zone assignment (if empty, masquerade does not take effect)
firewall-cmd --get-active-zones

# Add the NIC to a zone (run automatically by user_data)
NIC=$(ip route show default | awk '{print $5}')
firewall-cmd --zone=public  --add-interface=$NIC --permanent
firewall-cmd --zone=trusted --add-interface=wg0  --permanent
firewall-cmd --zone=public  --add-masquerade --permanent
firewall-cmd --zone=public  --add-forward    --permanent
firewall-cmd --reload
```
