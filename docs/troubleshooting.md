# Troubleshooting Casebook

Real incidents encountered during the build, and the process of identifying the root cause and resolving them.  
The emphasis is on preserving the investigation flow of "narrowing from symptom to cause."

> **Note:** IP addresses, AWS account IDs, and IAM ARNs are shown as `<MASKED>`.

---

## Case 1: CloudFormation CREATE_FAILED (Japanese used in a Security Group Description)

### Symptom

```
Resource handler returned message: "Value (...) for parameter GroupDescription is invalid.
Character sets beyond ASCII are not supported."
```

The Security Group stack rolled back with `CREATE_FAILED`.

### Cause

The EC2 API `CreateSecurityGroup` allows only ASCII characters in `GroupDescription`. Japanese (multibyte) characters and full-width symbols (such as `（）`) are not allowed.

```yaml
# Bad (before)
GroupDescription: VPNサーバ用SG - WireGuard(UDP 51820)とOpenVPN(TCP 443)のみ許可

# Good (after)
GroupDescription: VPN server SG - allow only WireGuard (UDP 51820) and OpenVPN (TCP 443)
```

**Point:** This constraint applies not only to the group's `GroupDescription` but also to the `Description` of inbound/outbound rules. Assuming "it's a description field, so Japanese is fine" caused a recurrence.

### Prevention

```powershell
# Before deploying, check that Description-type properties contain no Japanese / full-width characters
Select-String -Path "cfn\*.yaml" `
    -Pattern "(GroupDescription|Description):.*[぀-ヿ㐀-鿿！-｠]"
```

### Lesson

CloudFormation fails on the first error during resource creation, so even after fixing `GroupDescription`, it fails again on the next rule's `Description` (you need to find all occurrences at once).

---

## Case 2: VPN Connects but Has No Internet Access (firewalld zone not assigned)

### Symptom

The WireGuard connection is established (`wg show` shows a handshake). Ping to EC2 works. But the browser cannot reach external sites.

### Investigation

```bash
# Step 1: check IP forwarding
sysctl net.ipv4.ip_forward
# → 1 (OK)

# Step 2: check firewalld settings
firewall-cmd --list-all
# → masquerade: yes (looks OK)

# Step 3: check active zones
firewall-cmd --get-active-zones
# → (returns nothing) ← root cause identified here
```

### Root Cause

**The EC2 NIC (ens5) was not assigned to any firewalld zone.**

- The masquerade/forward rules themselves exist, but are "not applied to any interface."
- `iptables -L FORWARD` counters stay at 0 because AL2023 uses the **nftables backend** (iptables does not count here — this itself is not a symptom but AL2023's design).

On Amazon Linux 2023, due to the NetworkManager–firewalld integration, the NIC may not be auto-registered to a zone.

### Resolution

```bash
# Immediate fix (run manually)
NIC=$(ip route show default | awk '{print $5}')
firewall-cmd --zone=public  --add-interface=$NIC --permanent
firewall-cmd --zone=trusted --add-interface=wg0  --permanent
firewall-cmd --reload
```

To prevent recurrence, the NIC zone-registration commands were added to CloudFormation's user_data so they are applied automatically on the next EC2 recreation.

### Lesson

- Even when `firewall-cmd --list-all` "looks OK," always confirm **which interface it is applied to**.
- Judging "no packets are passing" solely from `iptables -L` counters is wrong on AL2023 (check the nftables backend counters with `nft list ruleset`).

---

## Case 3: wg-quick PostUp `\` Line Continuation Concatenates Commands and the Service Fails to Start

### Symptom

```
$ systemctl restart wg-quick@wg0
Line unrecognized: firewall-cmd--zone=public--add-forward--permanent;\
```

### Cause

When wg-quick processes multi-line continuation (`\`) in PostUp, it removes the spaces while joining the lines.

```ini
# Bad (multi-line continuation)
PostUp = firewall-cmd --zone=public --add-masquerade --permanent \
         firewall-cmd --zone=public --add-forward --permanent
# → after joining: firewall-cmd--zone=public--add-masquerade--permanentfirewall-cmd...
```

### Resolution

```ini
# Good (single line, separated by ;)
PostUp = firewall-cmd --zone=public --add-masquerade --permanent; firewall-cmd --zone=public --add-forward --permanent; firewall-cmd --zone=trusted --add-interface=wg0 --permanent; firewall-cmd --reload
```

### Lesson

A `\` continuation that is fine in a shell script misbehaves in wg-quick's own parser. Tool-specific constraints need to be documented clearly.

---

## Case 4: OpenVPN Startup Error `key values mismatch` (vars mixed EASYRSA_ALGO="ec" with RSA-based settings)

### Symptom

```
OpenSSL: error:05800074:x509 certificate routines::key values mismatch:
Cannot load private key file /etc/openvpn/server/server.key
Error: private key password verification failed
Exiting due to fatal error
```

### Cause

The guide's vars had `EASYRSA_ALGO = "ec"`, so `gen-req` generated an EC key, but `server.conf`'s `dh` directive and the `gen-dh` step assumed RSA. Part of the PKI ran as EC and part as RSA, so the certificate (RSA) and the private key (EC) used mismatched algorithms.

| Step | Actual behavior | Assumed algorithm |
|---|---|---|
| vars `EASYRSA_ALGO = "ec"` | Generates an EC key | EC |
| `gen-dh` / `dh dh.pem` | Uses DH parameters | RSA |

### Resolution

Remove the EC setting from vars to standardize on RSA, then delete and rebuild the entire PKI.

```bash
# Remove the EC setting from vars
sed -i '/EASYRSA_ALGO/d' ~/openvpn-ca/vars
grep EASYRSA_ALGO ~/openvpn-ca/vars  # OK if nothing is printed

# Stop the service and delete everything
systemctl stop openvpn-server@server
rm -rf ~/openvpn-ca/pki/
rm -f /etc/openvpn/server/{ca,server}.crt \
      /etc/openvpn/server/server.key \
      /etc/openvpn/server/{dh,ta}.*
rm -f /tmp/client1.ovpn

# Rebuild the PKI (standardized on RSA)
cd ~/openvpn-ca
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-req server nopass && ./easyrsa sign-req server server   # yes
./easyrsa gen-req client1 nopass && ./easyrsa sign-req client client1 # yes
./easyrsa gen-dh
openvpn --genkey secret ~/openvpn-ca/pki/ta.key
# cp into /etc/openvpn/server/, apply chmod 600, then start
systemctl enable --now openvpn-server@server
```

### Lesson

Keep the PKI algorithm consistent from vars all the way to `server.conf`. If you use EC, you must skip `gen-dh` and set `dh none` in `server.conf`. If you use RSA (the default), do not set `EASYRSA_ALGO` in vars. Whenever you regenerate certificates, always regenerate and redistribute the `.ovpn` files too.

---

## Case 5: CloudFormation Re-deploy `CREATE_FAILED` (S3 Bucket Name Conflict)

### Background

Before the real build, as an AWS sanity check, CloudTrail was **enabled manually from the console**, which auto-created an S3 bucket (`personal-vpn-cloudtrail-<MASKED>`). The bucket was then left in place without being deleted.

Later, when deploying the CloudFormation monitoring stack (`05_monitoring.yaml`), the template tried to create an S3 bucket with the same name, conflicting with the existing bucket.

### Symptom

```
Resource handler returned message:
"personal-vpn-cloudtrail-<MASKED> already exists"
```

The stack reverts to `ROLLBACK_COMPLETE`.

### Identifying the Cause

Two factors combined:

1. **Prior manual action**: the S3 bucket created when enabling CloudTrail from the console was still there.
2. **`DeletionPolicy: Retain` behavior**: a manually created S3 bucket (not managed by CloudFormation) cannot be touched by the stack even if it tries to delete it.

**How to check:**
```bash
# Find the CREATE_FAILED row on the Events tab
aws cloudformation describe-stack-events \
  --stack-name personal-vpn-monitoring-stack \
  --region ap-northeast-1 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].{Resource:LogicalResourceId,Reason:ResourceStatusReason}'
```

### Resolution

1. AWS console → S3 → select the bucket (`personal-vpn-cloudtrail-<ACCOUNT_ID>`)
2. Delete all objects in the bucket
3. Delete the bucket itself
4. Re-deploy the stack

### Lesson

`DeletionPolicy: Retain` is set to "prevent accidental deletion," but on re-deploy you must delete the S3 bucket manually. Build a habit of checking for "leftover resources" after deleting a stack and before re-deploying.

---

## Tool / Investigation Command Reference

| What to check | Command |
|---|---|
| **CloudFormation / AWS** | |
| Stack status | `aws cloudformation describe-stacks --stack-name <name> --region ap-northeast-1` |
| Stack error details | `aws cloudformation describe-stack-events --stack-name <name> --query 'StackEvents[?ResourceStatus==\`CREATE_FAILED\`]'` |
| EC2 instance state | `aws ec2 describe-instances --filters Name=tag:Project,Values=personal-vpn --output table` |
| SNS subscription status | `aws sns list-subscriptions-by-topic --topic-arn <ARN> --query 'Subscriptions[*].{Status:SubscriptionArn}'` |
| **VPN server (inside EC2)** | |
| WireGuard connection state | `wg show` |
| firewalld active zones | `firewall-cmd --get-active-zones` |
| firewalld applied settings | `firewall-cmd --list-all` |
| IP forwarding | `sysctl net.ipv4.ip_forward` |
| nftables ruleset (AL2023) | `nft list ruleset` |
| VPN service status (WireGuard) | `systemctl status wg-quick@wg0` |
| VPN service status (OpenVPN) | `systemctl status openvpn-server@server` |
| Live logs (WireGuard) | `journalctl -u wg-quick@wg0 -f` |
| Live logs (OpenVPN) | `tail -f /var/log/openvpn.log` |
| Verify cert/key pair | Compare `openssl x509 -noout -modulus -in server.crt \| md5sum` with `openssl rsa -noout -modulus -in server.key \| md5sum` |
