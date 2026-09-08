// trust/sign.go — optional ed25519 signatures over trust entries.
//
// Per docs/adr/0004-trust-model.md, a trust entry may carry a signature so an
// approval can be shared with a team: one person reviews a config and signs
// their trust entry, others verify it against that person's public key instead
// of reviewing the file again.
//
// The signature covers a deterministic JSON encoding of every field except
// `signature` itself.
package trust

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
)

// SigAlgorithm is the only algorithm this implementation accepts.
const SigAlgorithm = "ed25519"

// ErrNoSignature is returned when verification is asked for an unsigned entry.
var ErrNoSignature = fmt.Errorf("trust entry is not signed")

// LoadPrivateKey reads an OpenSSH ed25519 private key (e.g. ~/.ssh/id_ed25519).
//
// Only ed25519 is accepted: the entry format pins the algorithm, and silently
// accepting an RSA key would produce a signature nothing can verify.
func LoadPrivateKey(path string) (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read private key: %w", err)
	}

	raw, err := ssh.ParseRawPrivateKey(data)
	if err != nil {
		var passErr *ssh.PassphraseMissingError
		if errors.As(err, &passErr) {
			return nil, fmt.Errorf("private key %s is passphrase-protected; "+
				"envee cannot prompt for it — use an unencrypted key, or "+
				"decrypt it into a temporary file", path)
		}
		return nil, fmt.Errorf("parse private key %s: %w", path, err)
	}

	key, ok := raw.(*ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("private key %s is not ed25519 (got %T); "+
			"generate one with: ssh-keygen -t ed25519", path, raw)
	}
	return *key, nil
}

// LoadPublicKey reads an ed25519 public key in OpenSSH authorized_keys format
// (e.g. ~/.ssh/id_ed25519.pub).
func LoadPublicKey(path string) (ed25519.PublicKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read public key: %w", err)
	}

	pub, _, _, _, err := ssh.ParseAuthorizedKey(data)
	if err != nil {
		return nil, fmt.Errorf("parse public key %s: %w", path, err)
	}
	crypto, ok := pub.(ssh.CryptoPublicKey)
	if !ok {
		return nil, fmt.Errorf("public key %s has no usable key material", path)
	}
	ed, ok := crypto.CryptoPublicKey().(ed25519.PublicKey)
	if !ok {
		return nil, fmt.Errorf("public key %s is not ed25519 (got %s)", path, pub.Type())
	}
	return ed, nil
}

// KeyID returns a stable fingerprint of a public key, used to tell the reader
// which key produced a signature.
func KeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// signingPayload returns the deterministic JSON the signature covers: every
// field of the entry except `signature`.
//
// It goes through a map so encoding/json sorts the keys. Struct field order
// would otherwise be part of the signed bytes, and reordering the struct — a
// change with no semantic meaning — would invalidate every existing signature.
func signingPayload(e Entry) ([]byte, error) {
	e.Signature = nil

	data, err := json.Marshal(e)
	if err != nil {
		return nil, err
	}
	var generic map[string]any
	if err := json.Unmarshal(data, &generic); err != nil {
		return nil, err
	}
	delete(generic, "signature")
	return json.Marshal(generic)
}

// SignEntry signs e in place with priv.
func SignEntry(e *Entry, priv ed25519.PrivateKey, now time.Time) error {
	payload, err := signingPayload(*e)
	if err != nil {
		return fmt.Errorf("build signing payload: %w", err)
	}
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		return fmt.Errorf("private key does not yield an ed25519 public key")
	}

	e.Signature = &Sig{
		Algorithm: SigAlgorithm,
		KeyID:     KeyID(pub),
		Value:     base64.StdEncoding.EncodeToString(ed25519.Sign(priv, payload)),
		SignedAt:  now.UTC(),
	}
	return nil
}

// VerifyEntry checks e's signature against pub.
func VerifyEntry(e Entry, pub ed25519.PublicKey) error {
	if e.Signature == nil {
		return ErrNoSignature
	}
	if e.Signature.Algorithm != SigAlgorithm {
		return fmt.Errorf("unsupported signature algorithm %q", e.Signature.Algorithm)
	}
	if want := KeyID(pub); e.Signature.KeyID != want {
		return fmt.Errorf("signature was made by key %s, not %s",
			e.Signature.KeyID, want)
	}

	sig, err := base64.StdEncoding.DecodeString(e.Signature.Value)
	if err != nil {
		return fmt.Errorf("decode signature: %w", err)
	}
	payload, err := signingPayload(e)
	if err != nil {
		return fmt.Errorf("build signing payload: %w", err)
	}
	if !ed25519.Verify(pub, payload, sig) {
		return fmt.Errorf("signature does not match the entry (it was modified, " +
			"or signed for a different config)")
	}
	return nil
}
