# Trusting the Local TLS Certificate in Chrome

The ingress in `deploy/bases/app/ingress/main.yaml` is wired to cert-manager's `selfsigned` `ClusterIssuer` (`deploy/overlays/kind/clusterissuer-selfsigned.yaml`). Self-signed leaf certificates are not chained to any trusted root, so Chrome renders `https://magento.test` with a `NET::ERR_CERT_AUTHORITY_INVALID` warning.

Three ways to fix it, from quickest to cleanest:

- **Option A** — import the current cluster certificate into Chrome's trust store. One-off, per-hostname. Fastest.
- **Option B** — install a local CA via [`mkcert`](https://github.com/FiloSottile/mkcert) and reconfigure cert-manager to sign from it. Every hostname you issue is trusted automatically.
- **Option C** — roll your own CA with `openssl`. Same outcome as B, no extra tooling.

Before any option, make sure the hostname resolves to the cluster:

```bash
echo "$(minikube ip)  magento.test" | sudo tee -a /etc/hosts
```

### Per-environment names

The staging and production overlays patch the ingress to use distinct TLS secret names so certs don't collide across namespaces. Use the right trio for whichever env you're trusting:

| Env | Namespace | TLS secret | Hostname |
|-----|-----------|------------|----------|
| `dev` | `default` | `magento` | `magento.test` |
| `stage` | `staging` | `magento-staging` | `staging.magento.test` |
| `prod` | `production` | `magento-production` | per `deploy/overlays/production/patches/ingress*.yaml` |

Verify for your env before copy-pasting the commands below:

```bash
kubectl -n <ns> get ingress main -o jsonpath='{.spec.tls[0].secretName}{"\n"}'
kubectl -n <ns> get ingress main -o jsonpath='{.spec.rules[0].host}{"\n"}'
```

---

## Option A — Import the cluster cert into Chrome (quick)

### 1. Extract the cert from the TLS Secret

Set shell variables for your env (values from the table above):

```bash
NS=staging
SECRET=magento-staging
HOST=staging.magento.test

kubectl -n "$NS" get secret "$SECRET" \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "$HOST.crt"

# Sanity check
openssl x509 -in "$HOST.crt" -noout -subject -issuer -dates
```

**Is the cert real or temporary?** The ingress carries `cert-manager.io/issue-temporary-certificate: "true"`, so cert-manager hands out a short-lived placeholder until the real cert is issued. If you import the temporary one, it'll be replaced the moment the Certificate goes `Ready` and you'll have to re-import. Check status first:

```bash
kubectl -n "$NS" get certificate
# READY=True  → real cert, safe to import
# READY=False → temporary cert; investigate before importing:
kubectl -n "$NS" describe certificate "$SECRET" | tail -30
kubectl -n "$NS" get certificaterequest,order,challenge
```

Common blocker on Minikube: the ingress has no `ADDRESS` because `minikube tunnel` isn't running, so HTTP-01 challenges can't reach the cluster and the Certificate stays `False` indefinitely.

### 2. Install into Chrome's trust store (Linux)

Chrome on Linux uses the NSS shared database at `~/.pki/nssdb`.

```bash
# One-time: install NSS tools
sudo apt install libnss3-tools

# Trust as a server cert ("P" = trusted peer). Nickname must be unique per cert —
# reusing a nickname overwrites the previous entry, so use $HOST to keep envs separate.
certutil -d sql:$HOME/.pki/nssdb -A -t "P,," -n "$HOST" -i "$HOST.crt"

# Verify
certutil -d sql:$HOME/.pki/nssdb -L
```

To remove an old entry (e.g. before re-importing after a reissue):

```bash
certutil -d sql:$HOME/.pki/nssdb -D -n "$HOST"
```

### 3. Restart Chrome

```bash
pkill chrome
```

Open `https://magento.test` — the padlock should be green.

### When to re-run

cert-manager reissues the cert when the Secret is deleted or the underlying `Certificate` CR is regenerated. Each reissue produces a fresh serial, so Chrome will flag it again until you repeat steps 1–3. That's the main drawback of this option.

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain "$HOST.crt"
```

### Windows

```powershell
Import-Certificate -FilePath .\staging.magento.test.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

---

## Option B — Local CA via `mkcert` (recommended)

`mkcert` creates a real local CA, installs it into every trust store on your machine (system, Chrome/NSS, Firefox, Java), and you hand the CA to cert-manager so every cert it issues chains to a Chrome-trusted root.

### 1. Install `mkcert`

```bash
sudo apt install libnss3-tools
curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
chmod +x mkcert-v*-linux-amd64
sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
```

macOS: `brew install mkcert nss`. Windows: `choco install mkcert`.

### 2. Generate and install the root CA

```bash
mkcert -install
mkcert -CAROOT
# -> /home/<you>/.local/share/mkcert   (rootCA.pem + rootCA-key.pem)
```

`mkcert -install` writes the CA into the system trust store and into Chrome's NSS database. Chrome now trusts anything signed by this CA.

### 3. Hand the CA to cert-manager

```bash
kubectl -n cert-manager create secret tls mkcert-ca \
  --cert="$(mkcert -CAROOT)/rootCA.pem" \
  --key="$(mkcert -CAROOT)/rootCA-key.pem"
```

### 4. Swap the `ClusterIssuer` to CA mode

Edit `deploy/overlays/kind/clusterissuer-selfsigned.yaml` (keep the name `selfsigned` so the cert-manager `ingressShim.defaultIssuerName=selfsigned` in the `Makefile` still matches):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  ca:
    secretName: mkcert-ca
```

Apply and force a reissue:

```bash
kubectl apply -f deploy/overlays/kind/clusterissuer-selfsigned.yaml

# Delete the TLS secret for whichever env(s) you want reissued.
# Use the namespace + secret-name pairs from the table at the top.
kubectl -n default    delete secret magento            # dev
kubectl -n staging    delete secret magento-staging    # stage
kubectl -n production delete secret magento-production # prod
# cert-manager reissues automatically, signed by the mkcert CA
```

Restart Chrome — every env is now green, permanently. No re-import on reissue, and every new hostname (new overlay, new ingress) is trusted automatically.

### Rollback

```bash
git checkout deploy/overlays/kind/clusterissuer-selfsigned.yaml
kubectl apply -f deploy/overlays/kind/clusterissuer-selfsigned.yaml
kubectl -n cert-manager delete secret mkcert-ca
```

---

## Option C — Manual CA with `openssl`

Same outcome as Option B without `mkcert`. Useful if you want to understand the moving parts or can't install extra tools.

### 1. Create the root CA

```bash
openssl genrsa -out rootCA.key 4096
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 \
  -subj "/CN=Local Dev CA" -out rootCA.crt
```

### 2. Trust the root in Chrome

GUI: `chrome://settings/certificates` → **Authorities** → **Import** → select `rootCA.crt` → check **Trust this certificate for identifying websites**.

CLI equivalent on Linux:

```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "CT,C,C" -n "Local Dev CA" -i rootCA.crt
```

`"CT,C,C"` marks it as a trusted CA for SSL/email/object signing — different flag from Option A's `"P,,"` which trusts a single peer cert.

### 3. Load the CA into cert-manager

```bash
kubectl -n cert-manager create secret tls mkcert-ca \
  --cert=rootCA.crt --key=rootCA.key
```

### 4. Swap the `ClusterIssuer` — same as Option B step 4

Apply, delete the `magento` Secret, reissue.

---

## Which option should I pick?

| Criterion | A | B | C |
|-----------|---|---|---|
| Setup time | 30s | 2m | 5m |
| Survives cert reissue | No | Yes | Yes |
| Works for new hostnames | No | Yes | Yes |
| Extra tooling | `certutil` | `mkcert` | `openssl` |
| Good for | One-shot demo | Daily development | Air-gapped / audit-friendly setups |

For a demo or a single throwaway environment, Option A is fine. For any dev loop where you'll reissue certs, add staging/production overlays, or poke at new ingress hosts, set up Option B once and forget about it.

---

## Troubleshooting

**Chrome still shows the warning after import.**
Fully quit Chrome (`pkill chrome`). Chrome caches cert decisions per session and won't pick up NSS changes until restart.

**`certutil` says the cert already exists.**
Delete the old entry first: `certutil -d sql:$HOME/.pki/nssdb -D -n "magento.test"`.

**Cert is trusted but page still fails with `NET::ERR_CERT_COMMON_NAME_INVALID`.**
The cert's SAN doesn't include the hostname you're visiting. Check `openssl x509 -in magento.test.crt -noout -text | grep -A1 "Subject Alternative Name"` — the ingress rules in `deploy/bases/app/ingress/main.yaml` determine which hosts get added.

**Option B/C: cert-manager doesn't reissue after secret delete.**
Force it by deleting the `Certificate` CR too: `kubectl -n default delete certificate magento`. Check `kubectl -n default describe certificate magento` for events if reissue still stalls.

**NetworkPolicy blocks cert-manager.**
The `default-deny-all` policy in `deploy/bases/app/networkpolicy.yaml` plus the per-component allow policies should already permit cert-manager's webhook/controller traffic. If a new policy breaks HTTP-01 challenges, make sure the ingress controller can reach the `acme-http-solver` pod cert-manager spawns in the same namespace.
