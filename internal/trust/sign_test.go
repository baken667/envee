package trust

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// genSSHKey produces a real OpenSSH ed25519 keypair with ssh-keygen, so the
// parser is exercised against the format users actually have rather than
// something this package produced itself.
func genSSHKey(t *testing.T, keyType string) (priv, pub string) {
	t.Helper()
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen not available")
	}
	dir := t.TempDir()
	priv = filepath.Join(dir, "id_"+keyType)
	cmd := exec.Command("ssh-keygen", "-q", "-t", keyType, "-N", "", "-C", "envee-test", "-f", priv)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, out)
	}
	return priv, priv + ".pub"
}

func testEntry() Entry {
	return Entry{
		Version:     1,
		FileHash:    "sha256:abc123",
		FilePath:    "/home/alice/proj/envee.toml",
		TrustedAt:   time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC),
		TrustedBy:   "alice",
		ToolVersion: "0.2.0",
	}
}

func TestSignAndVerifyRoundTrip(t *testing.T) {
	privPath, pubPath := genSSHKey(t, "ed25519")

	priv, err := LoadPrivateKey(privPath)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := LoadPublicKey(pubPath)
	if err != nil {
		t.Fatal(err)
	}

	e := testEntry()
	if err := SignEntry(&e, priv, time.Now()); err != nil {
		t.Fatal(err)
	}
	if e.Signature == nil {
		t.Fatal("no signature was attached")
	}
	if e.Signature.Algorithm != SigAlgorithm {
		t.Errorf("algorithm = %q", e.Signature.Algorithm)
	}
	if !strings.HasPrefix(e.Signature.KeyID, "sha256:") {
		t.Errorf("key_id = %q, want a sha256 fingerprint", e.Signature.KeyID)
	}
	if err := VerifyEntry(e, pub); err != nil {
		t.Errorf("a freshly signed entry must verify: %v", err)
	}
}

// The whole point of the signature is that it is bound to the config's
// content. Changing the hash must invalidate it.
func TestVerifyRejectsTamperedHash(t *testing.T) {
	privPath, pubPath := genSSHKey(t, "ed25519")
	priv, _ := LoadPrivateKey(privPath)
	pub, _ := LoadPublicKey(pubPath)

	e := testEntry()
	if err := SignEntry(&e, priv, time.Now()); err != nil {
		t.Fatal(err)
	}
	e.FileHash = "sha256:tampered"

	if err := VerifyEntry(e, pub); err == nil {
		t.Fatal("a modified file hash must invalidate the signature")
	}
}

func TestVerifyRejectsTamperedFields(t *testing.T) {
	privPath, pubPath := genSSHKey(t, "ed25519")
	priv, _ := LoadPrivateKey(privPath)
	pub, _ := LoadPublicKey(pubPath)

	for name, mutate := range map[string]func(*Entry){
		"path":       func(e *Entry) { e.FilePath = "/tmp/evil/envee.toml" },
		"expiry":     func(e *Entry) { e.ExpiresAt = time.Now().Add(24 * time.Hour) },
		"trusted_by": func(e *Entry) { e.TrustedBy = "mallory" },
		"comment":    func(e *Entry) { e.Comment = "looks fine to me" },
	} {
		t.Run(name, func(t *testing.T) {
			e := testEntry()
			if err := SignEntry(&e, priv, time.Now()); err != nil {
				t.Fatal(err)
			}
			mutate(&e)
			if err := VerifyEntry(e, pub); err == nil {
				t.Errorf("modifying %s must invalidate the signature", name)
			}
		})
	}
}

func TestVerifyRejectsWrongKey(t *testing.T) {
	privPath, _ := genSSHKey(t, "ed25519")
	_, otherPubPath := genSSHKey(t, "ed25519")

	priv, _ := LoadPrivateKey(privPath)
	otherPub, _ := LoadPublicKey(otherPubPath)

	e := testEntry()
	if err := SignEntry(&e, priv, time.Now()); err != nil {
		t.Fatal(err)
	}
	err := VerifyEntry(e, otherPub)
	if err == nil {
		t.Fatal("verification against an unrelated key must fail")
	}
	// The key-id mismatch should be reported plainly rather than as a generic
	// cryptographic failure, so the user knows they used the wrong key.
	if !strings.Contains(err.Error(), "was made by key") {
		t.Errorf("unhelpful error for a key mismatch: %v", err)
	}
}

func TestVerifyUnsignedEntry(t *testing.T) {
	_, pubPath := genSSHKey(t, "ed25519")
	pub, _ := LoadPublicKey(pubPath)
	if err := VerifyEntry(testEntry(), pub); err != ErrNoSignature {
		t.Errorf("got %v, want ErrNoSignature", err)
	}
}

// The signed payload must not depend on struct field order, or reordering
// fields (a change with no semantic meaning) would invalidate every signature
// in existence.
func TestSigningPayloadIsDeterministic(t *testing.T) {
	e := testEntry()
	first, err := signingPayload(e)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		again, err := signingPayload(e)
		if err != nil {
			t.Fatal(err)
		}
		if string(again) != string(first) {
			t.Fatalf("payload is not stable:\n  %s\n  %s", first, again)
		}
	}
	if strings.Contains(string(first), "signature") {
		t.Errorf("the signature field must not be part of what is signed: %s", first)
	}
}

// A signature already present must not affect the payload, or verification
// would never reproduce the bytes that were signed.
func TestSigningPayloadIgnoresExistingSignature(t *testing.T) {
	e := testEntry()
	before, _ := signingPayload(e)

	e.Signature = &Sig{Algorithm: SigAlgorithm, KeyID: "sha256:x", Value: "y"}
	after, _ := signingPayload(e)

	if string(before) != string(after) {
		t.Errorf("payload changed once a signature was attached:\n  %s\n  %s", before, after)
	}
}

func TestLoadPrivateKeyRejectsNonEd25519(t *testing.T) {
	privPath, _ := genSSHKey(t, "rsa")
	_, err := LoadPrivateKey(privPath)
	if err == nil {
		t.Fatal("an RSA key must be rejected; the entry format pins ed25519")
	}
	if !strings.Contains(err.Error(), "not ed25519") {
		t.Errorf("error should say the key type is wrong: %v", err)
	}
}

func TestLoadKeysMissingFile(t *testing.T) {
	if _, err := LoadPrivateKey(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Error("expected an error for a missing private key")
	}
	if _, err := LoadPublicKey(filepath.Join(t.TempDir(), "nope.pub")); err == nil {
		t.Error("expected an error for a missing public key")
	}
}

func TestKeyIDIsStableAndDistinct(t *testing.T) {
	_, pubA := genSSHKey(t, "ed25519")
	_, pubB := genSSHKey(t, "ed25519")
	a, _ := LoadPublicKey(pubA)
	b, _ := LoadPublicKey(pubB)

	first, second := KeyID(a), KeyID(a)
	if first != second {
		t.Errorf("KeyID must be stable for the same key: %s vs %s", first, second)
	}
	if KeyID(a) == KeyID(b) {
		t.Error("different keys must have different ids")
	}
}

func TestLoadPassphraseProtectedKeyExplains(t *testing.T) {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen not available")
	}
	dir := t.TempDir()
	priv := filepath.Join(dir, "id_ed25519")
	cmd := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "hunter2", "-f", priv)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, out)
	}
	_, err := LoadPrivateKey(priv)
	if err == nil {
		t.Fatal("an encrypted key must not load silently")
	}
	if !strings.Contains(err.Error(), "passphrase") {
		t.Errorf("error should name the passphrase as the cause: %v", err)
	}
	_ = os.Remove(priv)
}
