# Basic example

The simplest possible `envee.toml` with a dotenv companion file.

## Layout

```
basic/
├── envee.toml     # main config
├── .env           # dotenv file (loaded via _.file)
└── README.md
```

## Try it

```bash
cd examples/basic
envee trust
envee eval bash     # prints the env diff
envee resolve       # prints KEY=VALUE pairs
envee status        # human-readable summary
```

## What you should see

```bash
$ envee eval bash
export SERVICE_NAME='myapp';
export DATABASE_URL='postgres://localhost:5432/mydb';
export PORT='5432';
...
export PATH='...:/Users/.../examples/basic/bin:...';
```
