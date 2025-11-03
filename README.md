# `quickzilver`

A tiny tool for interacting with zig community mirrors, written in Zig!

Implements the [pseudocode prescriptions from the Zig Software Foundation
site](https://ziglang.org/download/community-mirrors/).

# Use-Cases

- downloading zig for use on your main workstation
- downloading zig for automation, like in CI/CD environments

# Features

- **high availability:** use the [community mirror
  network](https://ziglang.org/download/community-mirrors/) to get zig even if
  [ziglang.org](https://ziglang.org) is down
- **minisign verification:** release signatures are verified using the Zig
  Software Foundation's public keys
- **simplicity and flexibility:** simply shove the file your want to download
  into `STDIN`, and the tarball comes out of `STDOUT`. `quickzilver` doesn't
  even have a CLI interface. Do whatever you'd like downstream with the trusted
  release tarball.

# Installation

`quickzilver` must be built using zig 0.15.1.

```bash
zig build --release=safe
sudo cp zig-out/bin/quickzilver /usr/local/bin
```

# Usage

Pass this configuration struct to `STDIN` in
[zon](https://ziglang.org/documentation/master/std/#std.zon) notation.

```zig
const Config = struct {
    /// One of the file names listed on https://ziglang.org/download/
    filename: []const u8,
};
```

For example;

```bash
cat <<EOF | quickzilver > output.tar.xz
.{
  .filename = "zig-aarch64-macos-0.16.0-dev.747+493ad58ff.tar.xz",
}
EOF
```

With a bit more shell glue, we can use `quickzilver` as a proper zig version
manager for your main machine;

```bash
# Idemponent one-time setup.
mkdir -p ~/.config/quickzilver
if [ ! -f ~/.config/quickzilver/conf.zon ]
then
  cat <<EOF > ~/.config/quickzilver/conf.zon
.{
  .filename = "zig-aarch64-macos-0.15.2.tar.xz",
}
EOF
fi
mkdir -p ~/.local/quickzilver

# Shell setup

export PATH="$PATH:$HOME/.local/quickzilver/bin"

# Overwrite your zig install with the one from
# ~/.config/quickzilver/conf.zon
qz_sync() (
  set -eo pipefail
  cd ~/.local/quickzilver
  ls | xargs rm -rf
  cat ~/.config/quickzilver/conf.zon \
    | quickzilver \
    | unxz \
    | tar -xf - --strip-components 1
)
```

# Caveats

A random community mirror is picked exactly once on each invocation of
`quickzilver`. The same mirror is used throughout, and there is no internal
retry logic. If you're using `quickzilver` in an automation environment,
consider retrying to improve redundancy.

`quickzilver` only reads a ZON config from `STDIN` and then emits the downloaded
tarball to `STDOUT`. It has no CLI interface (`--help` or `--version`). To avoid
printing the zig release binary to your terminal, `quickzilver` exits early if
it detects that `STDOUT` is a TTY.

`quickzilver` will try to fetch and use the [latest community mirror
list](https://ziglang.org/download/community-mirrors.txt)

`quickzilver` is new, written by a Zig novice, not widely used at this time, and
has not received a security review. It probably has bugs; maybe ones that
seriously undermine safety.

# Alternatives

The use-case I had in mind when writing `quickzilver` was for use in
Dockerfiles, CI/CD environments, etc.

[zvm](https://www.zvm.app/) is a fully featured zig version manager.
`quickzilver` has a better story around community mirrors than zvm; we'll
automatically use a randomly selected community mirror each time whereas you
need to [explicitly configure a
mirror](https://www.zvm.app/reference/how-to-use/#use-a-custom-mirror-distribution-server)
when using `zvm`.

[mlugg/setup-zig](https://github.com/marketplace/actions/setup-zig-compiler) can
be used in GitHub actions. Once again, mirror choice must be explicitly
configured.
