# TLS test fixtures

Throwaway certificates for `test/zizq/tls_test.exs`, generated with
`openssl`. They exist so the tests parse what `:public_key.pem_decode/1`
actually returns rather than hand-written approximations of it — which
is where the interesting cases are (an EC key, for instance, is
preceded by its curve parameters).

They are **not** secrets. Nothing trusts this CA, the keys protect
nothing, and they are never used outside the test suite.

| File | What it is |
| --- | --- |
| `ca.pem` | Self-signed test CA |
| `client.pem` | Client certificate, signed by that CA |
| `client-key.pem` | Its key, PKCS#8 (`PrivateKeyInfo`) |
| `ec-key.pem` | An EC key, covering the `EcpkParameters` block OpenSSL writes ahead of it |

Regenerate with:

```sh
openssl req -x509 -newkey rsa:2048 -keyout ca-key.pem -out ca.pem \
    -days 3650 -nodes -subj "/CN=Zizq Test CA"
openssl req -newkey rsa:2048 -keyout client-key.pem -out client.csr \
    -nodes -subj "/CN=zizq-test-client"
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem \
    -CAcreateserial -out client.pem -days 3650
openssl ecparam -genkey -name prime256v1 -out ec-key.pem
rm -f client.csr ca.srl ca-key.pem
```
