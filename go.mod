module github.com/baken667/envee

go 1.24.0

// golang.org/x/crypto and golang.org/x/sys are pinned deliberately: their
// current releases require Go 1.26, which would raise this module's minimum
// toolchain from 1.24 and drop users still on it. Only x/crypto/ssh is used
// (OpenSSH ed25519 key parsing for signed trust entries); do not `go get -u`
// them without making that compatibility decision explicitly.
require (
	github.com/BurntSushi/toml v1.6.0
	github.com/adrg/xdg v0.5.3
	github.com/spf13/cobra v1.10.2
	golang.org/x/crypto v0.45.0
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/cpuguy83/go-md2man/v2 v2.0.6 // indirect
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/russross/blackfriday/v2 v2.1.0 // indirect
	github.com/spf13/pflag v1.0.9 // indirect
	go.yaml.in/yaml/v3 v3.0.4 // indirect
	golang.org/x/sys v0.38.0 // indirect
)
