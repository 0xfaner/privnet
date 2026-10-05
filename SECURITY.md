# Security policy

Use the repository's **Security** tab to report suspected vulnerabilities
privately when private vulnerability reporting is enabled. Include the
privnet revision, mihomo version, affected command and a minimal
reproduction with synthetic values. Keep real credentials, subscription
files, certificates' private keys and unredacted Azure output out of issues
and pull requests.

If proxy credentials are exposed, replace them on the server and distribute
fresh client profiles over an authenticated channel. If a TLS or Reality
private key is exposed, replace the corresponding key material and refresh
the affected certificate pins or Reality public key in client profiles.
