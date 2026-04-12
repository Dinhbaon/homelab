# SOPS Secret Management

This repo uses [SOPS](https://github.com/getsops/sops) with Age encryption for secrets management.

## Quick Reference

### Prerequisites
- `sops` installed (`brew install sops` or from releases)
- Age key at `./age.key` (or set `SOPS_AGE_KEY_FILE` env var)

### Adding a New Secret

**Never edit encrypted secret files directly.** Always follow this workflow:

1. **Decrypt the file first:**
   ```bash
   export SOPS_AGE_KEY=$(cat age.key)
   sops -d clusters/homelab/apps/<app>/secret.yaml > /tmp/secret-decrypted.yaml
   ```

2. **Edit the decrypted file:**
   ```bash
   vi /tmp/secret-decrypted.yaml
   # Add or modify your secret values
   ```

3. **Re-encrypt the file:**
   ```bash
   sops -e /tmp/secret-decrypted.yaml > clusters/homelab/apps/<app>/secret.yaml
   ```

4. **Commit and push:**
   ```bash
   git add clusters/homelab/apps/<app>/secret.yaml
   git commit -m "chore(<app>): add new secret"
   git push
   ```

### Renaming Secret Keys

When renaming keys (e.g., `JWTAccessTokenSecret` → `JWT_ACCESS_TOKEN_SECRET`):

1. **Decrypt first:**
   ```bash
   export SOPS_AGE_KEY=$(cat age.key)
   sops -d clusters/homelab/apps/<app>/secret.yaml > /tmp/secret-decrypted.yaml
   ```

2. **Rename the keys in the plaintext file** using your editor

3. **Re-encrypt:**
   ```bash
   sops -e /tmp/secret-decrypted.yaml > clusters/homelab/apps/<app>/secret.yaml
   ```

4. **Commit and push**

## Why Direct Edits Break Things

SOPS encrypts each value individually and calculates a MAC (Message Authentication Code) over the encrypted data. When you edit the file directly (even just changing a key name), the MAC becomes invalid because:

1. The encrypted values remain the same
2. But the file structure/content has changed
3. SOPS detects this mismatch and fails with: `cipher: message authentication failed`

This is a security feature - it prevents tampering with encrypted files. The only way to modify secrets is through proper SOPS encryption.

## SOPS Configuration

The `.sops.yaml` at repo root defines encryption rules:

```yaml
creation_rules:
  - path_regex: .*/secret.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1cdptwtsh43266j2lm5w9yt44xz8nvscw3srvqgsec26md5lmhemsm4xqka
```

This means:
- All files matching `*/secret*.yaml` are encrypted
- Only `data` and `stringData` fields are encrypted (keys stay plaintext for K8s)
- Recipients must have the corresponding Age private key

## Flux Integration

Flux uses the `sops-age` secret in the `flux-system` namespace to decrypt secrets. Ensure the Age key in `age.key` matches what's configured in the cluster:

```bash
# Verify keys match
kubectl get secret -n flux-system sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d
cat age.key
```

If keys don't match, you'll see: `decryption failed for 'aucra-secret': cipher: message authentication failed`

## Recovery

If a secret file becomes corrupted (MAC failure):

1. Get the actual values from the cluster:
   ```bash
   export KUBECONFIG=~/kubeconfig
   kubectl get secret <secret-name> -n <namespace> -o yaml
   ```

2. Create a new plaintext secret file with those values

3. Re-encrypt with SOPS using the workflow above

4. Commit and push - Flux will update the cluster
