package directive

import (
	"context"
	"strings"
	"testing"

	"github.com/baken667/envee/internal/config"
)

// A config must not be able to set envee's own control variables. envee
// exports whatever a config produces into the user's shell, so allowing
// ENVEE_* would let one project's config reconfigure envee for every other
// directory in the session.
func TestApplyRejectsReservedKeys(t *testing.T) {
	cases := []struct {
		name string
		key  string
	}{
		{"bypass_trust", "ENVEE_BYPASS_TRUST"},
		{"profile", "ENVEE_PROFILE"},
		{"arbitrary", "ENVEE_ANYTHING"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &config.Config{
				Schema:     config.SchemaVersion,
				Env:        map[string]any{tc.key: "1"},
				Profiles:   map[string]*config.Profile{},
				Directives: &config.Directives{},
			}
			_, err := Apply(context.Background(), cfg, ApplyOptions{
				ConfigRoot: t.TempDir(),
			}, nil)
			if err == nil {
				t.Fatalf("Apply accepted reserved key %s", tc.key)
			}
			if !strings.Contains(err.Error(), tc.key) {
				t.Errorf("error should name the offending key %q, got: %v", tc.key, err)
			}
		})
	}
}

func TestApplyAllowsNormalKeys(t *testing.T) {
	cfg := &config.Config{
		Schema: config.SchemaVersion,
		Env: map[string]any{
			"DATABASE_URL": "postgres://localhost",
			"ENVEEISH":     "not reserved, no underscore",
		},
		Profiles:   map[string]*config.Profile{},
		Directives: &config.Directives{},
	}
	res, err := Apply(context.Background(), cfg, ApplyOptions{ConfigRoot: t.TempDir()}, nil)
	if err != nil {
		t.Fatalf("Apply rejected a valid config: %v", err)
	}
	if got, _ := res.Env.Get("DATABASE_URL"); got != "postgres://localhost" {
		t.Errorf("DATABASE_URL = %q", got)
	}
}
