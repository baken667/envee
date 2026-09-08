package env

import "os"

// osEnviron is a package-level variable so tests can override it.
var osEnviron = os.Environ
