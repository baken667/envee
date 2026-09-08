package config

import "os"

func writeFileImpl(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}
