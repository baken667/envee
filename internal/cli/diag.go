package cli

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/paths"
	"github.com/baken667/envee/internal/resolver"
	"github.com/baken667/envee/internal/trust"
	"github.com/baken667/envee/internal/version"
)

// daemonState describes whether enveed is reachable.
type daemonState struct {
	Running bool   `json:"running"`
	Socket  string `json:"socket"`
	Lock    string `json:"lock"`
	Detail  string `json:"detail,omitempty"`
}

// probeDaemon reports whether the daemon is accepting connections.
//
// The socket file existing is not enough: a crashed daemon leaves a stale
// socket behind. The only reliable signal is whether a connection succeeds.
func probeDaemon() daemonState {
	st := daemonState{Socket: paths.Socket(), Lock: paths.LockFile()}

	if _, err := os.Stat(st.Socket); err != nil {
		st.Detail = "no socket at " + st.Socket
		return st
	}

	conn, err := net.DialTimeout("unix", st.Socket, 500*time.Millisecond)
	if err != nil {
		st.Detail = "socket exists but is not accepting connections (stale): " + err.Error()
		return st
	}
	_ = conn.Close()
	st.Running = true
	return st
}

func runDaemonStatus(_ *cobra.Command, jsonOut bool) error {
	st := probeDaemon()
	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(st)
	}
	if st.Running {
		fmt.Printf("enveed is running (socket %s)\n", st.Socket)
		return nil
	}
	fmt.Printf("enveed is not running\n")
	if st.Detail != "" {
		fmt.Printf("  %s\n", st.Detail)
	}
	fmt.Printf("  envee works without it; the daemon only reduces hook latency.\n")
	fmt.Printf("  Start it with: enveed &\n")
	return nil
}

// --- doctor -----------------------------------------------------------------

type diagStatus string

const (
	diagOK   diagStatus = "ok"
	diagWarn diagStatus = "warn"
	diagFail diagStatus = "fail"
)

type diagnostic struct {
	Name   string     `json:"name"`
	Status diagStatus `json:"status"`
	Detail string     `json:"detail"`
	Hint   string     `json:"hint,omitempty"`
}

type doctorReport struct {
	Diagnostics []diagnostic `json:"diagnostics"`
	Failures    int          `json:"failures"`
	Warnings    int          `json:"warnings"`
	OK          bool         `json:"ok"`
}

func runDoctor(cmd *cobra.Command, jsonOut bool) error {
	var d []diagnostic
	add := func(name string, st diagStatus, detail, hint string) {
		d = append(d, diagnostic{Name: name, Status: st, Detail: detail, Hint: hint})
	}

	// Binary and version.
	exe, err := os.Executable()
	if err != nil {
		exe = "unknown"
	}
	add("binary", diagOK, fmt.Sprintf("%s (%s/%s)", exe, runtime.GOOS, runtime.GOARCH), "")
	if version.Version == "0.0.0-dev" {
		add("version", diagWarn, "0.0.0-dev — built without release ldflags",
			"Release builds report a real version. `make build` sets them.")
	} else {
		add("version", diagOK, fmt.Sprintf("%s (commit %s, built %s)", version.Version, version.Commit, version.Date), "")
	}

	// envee must be on $PATH for the shell hook to find it.
	if p, err := exec.LookPath("envee"); err != nil {
		add("PATH", diagWarn, "envee is not on $PATH",
			"The shell hook calls envee by absolute path, so this is not fatal, but `envee` will not work interactively.")
	} else {
		add("PATH", diagOK, p, "")
	}

	// Shell hook installed?
	shellName := os.Getenv("SHELL")
	if shellName == "" {
		add("shell", diagWarn, "$SHELL is not set", "")
	} else {
		add("shell", diagOK, shellName, "")
		if found, file := hookInstalled(shellName); found {
			add("shell hook", diagOK, "installed in "+file, "")
		} else {
			add("shell hook", diagWarn, "no `envee init` line found in your shell rc",
				"Add: eval \"$(envee init "+filepath.Base(shellName)+")\"")
		}
	}

	// Directories.
	for _, dir := range []struct{ name, path string }{
		{"config dir", paths.Config()},
		{"data dir", paths.Data()},
		{"trust store", paths.TrustStore()},
	} {
		switch _, err := os.Stat(dir.path); {
		case err == nil:
			add(dir.name, diagOK, dir.path, "")
		case os.IsNotExist(err):
			add(dir.name, diagOK, dir.path+" (not created yet)", "")
		default:
			add(dir.name, diagFail, dir.path+": "+err.Error(), "Check filesystem permissions.")
		}
	}

	// Trust store readable, and its entry count.
	store := trust.NewStore()
	if entries, err := store.List(); err != nil {
		add("trust entries", diagFail, err.Error(), "The trust store may be corrupt; inspect "+paths.TrustStore())
	} else {
		add("trust entries", diagOK, fmt.Sprintf("%d", len(entries)), "")
	}

	// Plugins.
	found := discoverPlugins(cmd)
	switch {
	case len(found) == 0:
		add("plugins", diagOK, "none discovered", "")
	default:
		var broken []string
		for _, p := range found {
			if p.Metadata == nil {
				broken = append(broken, p.Name)
			}
		}
		detail := fmt.Sprintf("%d discovered", len(found))
		if len(broken) > 0 {
			add("plugins", diagWarn, detail+", metadata handshake failed for: "+strings.Join(broken, ", "),
				"Run `envee plugin info <name>` for the error.")
		} else {
			add("plugins", diagOK, detail, "")
		}
	}

	// Daemon (optional).
	if st := probeDaemon(); st.Running {
		add("daemon", diagOK, "running at "+st.Socket, "")
	} else {
		add("daemon", diagOK, "not running (optional)", "")
	}

	// Config discovery for the current directory.
	if cwd, err := os.Getwd(); err == nil {
		if res, err := resolver.New(cwd); err == nil {
			files, _ := res.Discover()
			if len(files) == 0 {
				add("config", diagOK, "no envee.toml found from "+cwd, "")
			} else {
				var untrusted []string
				if cfg, err := res.LoadAll(); err == nil {
					for _, src := range untrustedSources(cfg) {
						untrusted = append(untrusted, src.Path)
					}
				}
				detail := fmt.Sprintf("%d file(s) would be loaded here", len(files))
				if len(untrusted) > 0 {
					add("config", diagWarn, detail+"; not trusted: "+strings.Join(untrusted, ", "),
						"Run `envee trust` to review and approve them.")
				} else {
					add("config", diagOK, detail+", all trusted", "")
				}
			}
		}
	}

	rep := doctorReport{Diagnostics: d}
	for _, x := range d {
		switch x.Status {
		case diagFail:
			rep.Failures++
		case diagWarn:
			rep.Warnings++
		}
	}
	rep.OK = rep.Failures == 0

	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(rep)
	}

	fmt.Println("envee doctor")
	fmt.Println("============")
	for _, x := range rep.Diagnostics {
		mark := "ok  "
		switch x.Status {
		case diagWarn:
			mark = "warn"
		case diagFail:
			mark = "FAIL"
		}
		fmt.Printf("  [%s] %-14s %s\n", mark, x.Name, x.Detail)
		if x.Hint != "" {
			fmt.Printf("         %-14s %s\n", "", x.Hint)
		}
	}
	fmt.Println()
	if rep.Failures == 0 && rep.Warnings == 0 {
		fmt.Println("Everything looks fine.")
	} else {
		fmt.Printf("%d failure(s), %d warning(s)\n", rep.Failures, rep.Warnings)
	}

	if rep.Failures > 0 {
		return errs.New("E013", "doctor found problems").
			WithContext("failures", fmt.Sprintf("%d", rep.Failures))
	}
	return nil
}

// hookInstalled looks for an `envee init` line in the rc file for the given
// shell. Best effort: an unreadable or unusual rc simply reports "not found".
func hookInstalled(shellPath string) (bool, string) {
	home, err := os.UserHomeDir()
	if err != nil {
		return false, ""
	}
	var candidates []string
	switch filepath.Base(shellPath) {
	case "bash":
		candidates = []string{".bashrc", ".bash_profile", ".profile"}
	case "zsh":
		candidates = []string{".zshrc", ".zprofile"}
	case "fish":
		candidates = []string{".config/fish/config.fish"}
	default:
		candidates = []string{".profile"}
	}
	for _, c := range candidates {
		f := filepath.Join(home, c)
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		if strings.Contains(string(data), "envee init") {
			return true, f
		}
	}
	return false, ""
}
