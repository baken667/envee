package cli

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/baken667/envee/internal/paths"
	"github.com/baken667/envee/internal/trust"
)

// sshKeypair generates a real OpenSSH ed25519 keypair.
func sshKeypair(t *testing.T) (privPath, pubPath string) {
	t.Helper()
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen not available")
	}
	dir := t.TempDir()
	privPath = filepath.Join(dir, "id_ed25519")
	if out, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", privPath).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, out)
	}
	return privPath, privPath + ".pub"
}

func signedEntryFile(t *testing.T, privPath string, mutate func(*trust.Entry)) string {
	t.Helper()
	priv, err := trust.LoadPrivateKey(privPath)
	if err != nil {
		t.Fatal(err)
	}
	e := trust.Entry{
		Version:     1,
		FileHash:    "sha256:deadbeef",
		FilePath:    filepath.Join(t.TempDir(), "envee.toml"),
		TrustedAt:   time.Now().UTC(),
		TrustedBy:   "reviewer",
		ToolVersion: "test",
	}
	if signErr := trust.SignEntry(&e, priv, time.Now()); signErr != nil {
		t.Fatal(signErr)
	}
	if mutate != nil {
		mutate(&e)
	}
	data, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "shared.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// Importing without --public-key must be refused: accepting an entry without
// checking its signature would let anyone approve configs on your behalf.
func TestTrustImportRequiresPublicKey(t *testing.T) {
	privPath, _ := sshKeypair(t)
	shared := signedEntryFile(t, privPath, nil)

	paths.IsolateForTest(t)
	err := runTrustImport(shared, "")
	if err == nil {
		t.Fatal("import without a public key must be refused")
	}
	if !strings.Contains(err.Error(), "public-key") {
		t.Errorf("error should name the missing flag: %v", err)
	}
}

func TestTrustImportAcceptsValidSignature(t *testing.T) {
	privPath, pubPath := sshKeypair(t)
	shared := signedEntryFile(t, privPath, nil)

	paths.IsolateForTest(t)

	if err := runTrustImport(shared, pubPath); err != nil {
		t.Fatalf("a validly signed entry must import: %v", err)
	}

	// And it must actually land in the store, not just report success.
	entry, ok, err := trust.NewStore().Get("sha256:deadbeef")
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("entry was reported imported but is not in the store")
	}
	if entry.Signature == nil {
		t.Error("the stored entry lost its signature")
	}
}

func TestTrustImportRejectsTamperedEntry(t *testing.T) {
	privPath, pubPath := sshKeypair(t)
	// Repoint the approval at a different config after signing.
	shared := signedEntryFile(t, privPath, func(e *trust.Entry) {
		e.FileHash = "sha256:0000000000000000"
	})

	paths.IsolateForTest(t)
	if err := runTrustImport(shared, pubPath); err == nil {
		t.Fatal("a tampered entry must be rejected")
	}

	// Nothing may be stored on a failed import.
	entries, err := trust.NewStore().List()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("a rejected import must store nothing, got %d entries", len(entries))
	}
}

func TestTrustImportRejectsWrongKey(t *testing.T) {
	privPath, _ := sshKeypair(t)
	_, otherPub := sshKeypair(t)
	shared := signedEntryFile(t, privPath, nil)

	paths.IsolateForTest(t)
	if err := runTrustImport(shared, otherPub); err == nil {
		t.Fatal("an entry signed by a different key must be rejected")
	}
}

func TestTrustImportRejectsUnsignedEntry(t *testing.T) {
	_, pubPath := sshKeypair(t)

	e := trust.Entry{Version: 1, FileHash: "sha256:abc", FilePath: "/tmp/envee.toml"}
	data, _ := json.Marshal(e)
	path := filepath.Join(t.TempDir(), "unsigned.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}

	paths.IsolateForTest(t)
	if err := runTrustImport(path, pubPath); err == nil {
		t.Fatal("an unsigned entry must be rejected")
	}
}

func TestTrustImportRejectsMalformedFile(t *testing.T) {
	_, pubPath := sshKeypair(t)
	path := filepath.Join(t.TempDir(), "broken.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	paths.IsolateForTest(t)
	if err := runTrustImport(path, pubPath); err == nil {
		t.Fatal("malformed JSON must be rejected")
	}
}
